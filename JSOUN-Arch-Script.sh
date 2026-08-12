#!/usr/bin/env bash
# Interactive Arch Linux workstation installer
# WARNING: This script ERASES the selected disk.
# Designed for the official Arch ISO, UEFI systems, and x86_64 Arch Linux.

set -Eeuo pipefail

# ----------------------------- helpers -----------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log()   { echo -e "${GREEN}[+]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
die()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
title() { echo -e "\n${BOLD}${CYAN}== $* ==${RESET}\n"; }

trap 'echo -e "\n${RED}Installer failed on line $LINENO.${RESET}"' ERR

[[ $EUID -eq 0 ]] || die "Run this installer as root from the Arch ISO."
[[ -d /sys/firmware/efi/efivars ]] || die "This installer requires UEFI boot mode."

ping -c 1 archlinux.org >/dev/null 2>&1 || die "No working internet connection."

timedatectl set-ntp true

# ----------------------------- user settings -----------------------------

title "Arch Linux Workstation Installer"

echo "This installer will create:"
echo "  • 1 GiB EFI System Partition mounted at /efi (FAT32, required for UEFI)"
echo "  • Remaining disk: Btrfs, including /boot"
echo "  • Btrfs subvolumes: @, @home, @log, @pkg, @snapshots"
echo "  • GRUB with Btrfs snapshot boot entries"
echo "  • PipeWire audio"
echo "  • NetworkManager"
echo "  • Dynamic or custom hostname selection"
echo "  • zram swap"
echo "  • Snapper + snap-pac automatic Btrfs snapshots"
echo

# Hostname: enter one manually, or press Enter to generate one from the hardware.
read -rp "Hostname [Enter = auto-generate from hardware]: " HOSTNAME

if [[ -z "$HOSTNAME" ]]; then
    SYS_VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
    PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)

    HOST_BASE="${SYS_VENDOR}-${PRODUCT_NAME}"

    # Convert to a valid lowercase hostname:
    # spaces/symbols -> hyphens, collapse repeats, trim ends.
    HOST_BASE=$(printf '%s' "$HOST_BASE" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')

    # Fall back if DMI data is unavailable or useless.
    [[ -n "$HOST_BASE" ]] || HOST_BASE="archlinux"

    # Add a short random suffix so multiple similar machines do not collide.
    HOST_SUFFIX=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')

    # Keep the final hostname safely below the 63-character DNS label limit.
    HOST_BASE=${HOST_BASE:0:54}
    HOSTNAME="${HOST_BASE}-${HOST_SUFFIX}"

    log "Generated hostname: $HOSTNAME"
fi

# Validate hostname: letters, numbers and hyphens only; cannot begin/end with hyphen.
if [[ ! "$HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
    die "Invalid hostname. Use letters, numbers, and hyphens only (max 63 characters)."
fi

HOSTNAME=$(printf '%s' "$HOSTNAME" | tr '[:upper:]' '[:lower:]')

read -rp "Username: " USERNAME
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid Linux username."

read -rp "Timezone [America/Los_Angeles]: " TIMEZONE
TIMEZONE=${TIMEZONE:-America/Los_Angeles}
[[ -e "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Timezone not found: $TIMEZONE"

read -rp "Locale [en_US.UTF-8]: " LOCALE
LOCALE=${LOCALE:-en_US.UTF-8}

# ----------------------------- desktop selection -----------------------------

title "Desktop Environment"

echo "Choose the desktop/session you want installed:"
echo
echo "  1) Xfce          — X11/Xorg       [recommended for an X11-first system]"
echo "  2) Cinnamon      — X11/Xorg"
echo "  3) MATE          — X11/Xorg"
echo "  4) LXQt          — X11/Xorg"
echo "  5) KDE Plasma    — X11 + Wayland  [both sessions installed]"
echo "  6) GNOME         — Wayland + X11  [Wayland-oriented]"
echo "  7) i3            — X11/Xorg       [tiling window manager]"
echo "  8) No desktop    — console only"
echo
read -rp "Selection [1]: " DE_CHOICE
DE_CHOICE=${DE_CHOICE:-1}

case "$DE_CHOICE" in
    1)
        DE_NAME="Xfce"
        DISPLAY_STACK="X11/Xorg"
        DE_PACKAGES=(xorg-server xorg-xinit xfce4 xfce4-goodies lightdm lightdm-gtk-greeter)
        DISPLAY_MANAGER="lightdm"
        ;;
    2)
        DE_NAME="Cinnamon"
        DISPLAY_STACK="X11/Xorg"
        DE_PACKAGES=(xorg-server xorg-xinit cinnamon lightdm lightdm-slick-greeter)
        DISPLAY_MANAGER="lightdm"
        ;;
    3)
        DE_NAME="MATE"
        DISPLAY_STACK="X11/Xorg"
        DE_PACKAGES=(xorg-server xorg-xinit mate mate-extra lightdm lightdm-gtk-greeter)
        DISPLAY_MANAGER="lightdm"
        ;;
    4)
        DE_NAME="LXQt"
        DISPLAY_STACK="X11/Xorg"
        DE_PACKAGES=(xorg-server xorg-xinit lxqt breeze-icons sddm)
        DISPLAY_MANAGER="sddm"
        ;;
    5)
        DE_NAME="KDE Plasma"
        DISPLAY_STACK="X11 + Wayland"
        DE_PACKAGES=(xorg-server xorg-xwayland plasma-meta kde-applications-meta sddm)
        DISPLAY_MANAGER="sddm"
        ;;
    6)
        DE_NAME="GNOME"
        DISPLAY_STACK="Wayland + X11"
        DE_PACKAGES=(xorg-server xorg-xwayland gnome gnome-extra gdm)
        DISPLAY_MANAGER="gdm"
        ;;
    7)
        DE_NAME="i3"
        DISPLAY_STACK="X11/Xorg"
        DE_PACKAGES=(xorg-server xorg-xinit i3-wm i3status i3lock rofi lightdm lightdm-gtk-greeter picom)
        DISPLAY_MANAGER="lightdm"
        ;;
    8)
        DE_NAME="None"
        DISPLAY_STACK="Console"
        DE_PACKAGES=()
        DISPLAY_MANAGER=""
        ;;
    *)
        die "Invalid desktop selection."
        ;;
esac

echo
log "Desktop: $DE_NAME"
log "Display stack: $DISPLAY_STACK"

# ----------------------------- terminal selection -----------------------------

title "Terminal Emulator"

echo "Choose your terminal emulator:"
echo
echo "GPU tag means the terminal itself uses GPU-accelerated rendering."
echo
echo "  1) Desktop default     [GPU: varies]    [DE native]"
echo "  2) Xfce Terminal       [GPU: No]        [X11/Wayland]  Lightweight GTK/VTE"
echo "  3) Alacritty           [GPU: YES]       [X11/Wayland]  Minimal + fast"
echo "  4) Kitty               [GPU: YES]       [X11/Wayland]  Fast + feature rich"
echo "  5) WezTerm             [GPU: YES]       [X11/Wayland]  Multiplexer + Lua"
echo "  6) Ghostty             [GPU: YES]       [X11/Wayland]  Native GTK + modern"
echo "  7) Contour             [GPU: YES]       [X11/Wayland]  OpenGL 3.3 renderer"
echo "  8) Rio                 [GPU: YES]       [X11/Wayland]  WebGPU renderer"
echo "  9) Zutty               [GPU: YES]       [X11 only]     Very lightweight OpenGL ES"
echo " 10) COSMIC Terminal     [GPU: YES]       [Wayland]      COSMIC/wgpu"
echo " 11) Terminology         [GPU: Optional]  [X11/Wayland]  EFL; OpenGL can be enabled"
echo " 12) cool-retro-term     [GPU: YES*]      [X11/Wayland]  QtQuick CRT-style effects"
echo " 13) Konsole             [GPU: No]        [X11/Wayland]  KDE terminal"
echo " 14) Yakuake             [GPU: No]        [X11/Wayland]  Drop-down Konsole"
echo " 15) QTerminal           [GPU: No]        [X11/Wayland]  Lightweight Qt/LXQt"
echo " 16) GNOME Terminal      [GPU: No]        [X11/Wayland]  GTK/VTE"
echo " 17) GNOME Console       [GPU: No]        [X11/Wayland]  Minimal GNOME terminal"
echo " 18) Ptyxis              [GPU: No]        [X11/Wayland]  GNOME/container focused"
echo " 19) MATE Terminal       [GPU: No]        [X11/Wayland]  GTK/VTE"
echo " 20) LXTerminal          [GPU: No]        [X11/Wayland]  Very lightweight GTK/VTE"
echo " 21) Sakura              [GPU: No]        [X11/Wayland]  Lightweight GTK/VTE"
echo " 22) Terminator          [GPU: No]        [X11/Wayland]  Split-pane GTK/VTE"
echo " 23) Guake               [GPU: No]        [X11/Wayland]  Drop-down GTK/VTE"
echo " 24) Tilda               [GPU: No]        [X11/Wayland]  Lightweight drop-down"
echo " 25) Pantheon Terminal   [GPU: No]        [X11/Wayland]  Elementary terminal"
echo " 26) Deepin Terminal     [GPU: No]        [X11/Wayland]  Deepin terminal"
echo " 27) Deepin Terminal GTK [GPU: No]        [X11/Wayland]  Legacy GTK version"
echo " 28) rxvt-unicode        [GPU: No]        [X11 only]     Lightweight urxvt"
echo " 29) xterm               [GPU: No]        [X11 only]     Classic/minimal"
echo " 30) Maui Station        [GPU: No]        [X11/Wayland]  MauiKit terminal"
echo " 31) QMLKonsole          [GPU: No]        [Wayland/X11]  Plasma Mobile-oriented"
echo " 32) foot                [GPU: No]        [Wayland only] Very lightweight"
echo
read -rp "Selection [1]: " TERMINAL_CHOICE
TERMINAL_CHOICE=${TERMINAL_CHOICE:-1}

TERMINAL_PACKAGES=()
TERMINAL_NAME="Desktop default"
TERMINAL_CMD=""
TERMINAL_GPU="varies"
TERMINAL_SESSION="DE native"

case "$TERMINAL_CHOICE" in
    1)
        case "$DE_CHOICE" in
            1) TERMINAL_NAME="Xfce Terminal"; TERMINAL_CMD="xfce4-terminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
            2) TERMINAL_PACKAGES=(gnome-terminal); TERMINAL_NAME="GNOME Terminal"; TERMINAL_CMD="gnome-terminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
            3) TERMINAL_PACKAGES=(mate-terminal); TERMINAL_NAME="MATE Terminal"; TERMINAL_CMD="mate-terminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
            4) TERMINAL_PACKAGES=(qterminal); TERMINAL_NAME="QTerminal"; TERMINAL_CMD="qterminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
            5) TERMINAL_PACKAGES=(konsole); TERMINAL_NAME="Konsole"; TERMINAL_CMD="konsole"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
            6) TERMINAL_PACKAGES=(gnome-console); TERMINAL_NAME="GNOME Console"; TERMINAL_CMD="kgx"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
            7) TERMINAL_PACKAGES=(xfce4-terminal); TERMINAL_NAME="Xfce Terminal"; TERMINAL_CMD="xfce4-terminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
            8) TERMINAL_NAME="Linux virtual console"; TERMINAL_CMD=""; TERMINAL_GPU="No"; TERMINAL_SESSION="Console" ;;
        esac ;;
    2) TERMINAL_PACKAGES=(xfce4-terminal); TERMINAL_NAME="Xfce Terminal"; TERMINAL_CMD="xfce4-terminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
    3) TERMINAL_PACKAGES=(alacritty); TERMINAL_NAME="Alacritty"; TERMINAL_CMD="alacritty"; TERMINAL_GPU="YES"; TERMINAL_SESSION="X11/Wayland" ;;
    4) TERMINAL_PACKAGES=(kitty); TERMINAL_NAME="Kitty"; TERMINAL_CMD="kitty"; TERMINAL_GPU="YES"; TERMINAL_SESSION="X11/Wayland" ;;
    5) TERMINAL_PACKAGES=(wezterm); TERMINAL_NAME="WezTerm"; TERMINAL_CMD="wezterm"; TERMINAL_GPU="YES"; TERMINAL_SESSION="X11/Wayland" ;;
    6) TERMINAL_PACKAGES=(ghostty); TERMINAL_NAME="Ghostty"; TERMINAL_CMD="ghostty"; TERMINAL_GPU="YES"; TERMINAL_SESSION="X11/Wayland" ;;
    7) TERMINAL_PACKAGES=(contour); TERMINAL_NAME="Contour"; TERMINAL_CMD="contour"; TERMINAL_GPU="YES"; TERMINAL_SESSION="X11/Wayland" ;;
    8) TERMINAL_PACKAGES=(rio); TERMINAL_NAME="Rio"; TERMINAL_CMD="rio"; TERMINAL_GPU="YES"; TERMINAL_SESSION="X11/Wayland" ;;
    9) TERMINAL_PACKAGES=(zutty); TERMINAL_NAME="Zutty"; TERMINAL_CMD="zutty"; TERMINAL_GPU="YES"; TERMINAL_SESSION="X11 only" ;;
   10) TERMINAL_PACKAGES=(cosmic-terminal); TERMINAL_NAME="COSMIC Terminal"; TERMINAL_CMD="cosmic-term"; TERMINAL_GPU="YES"; TERMINAL_SESSION="Wayland" ;;
   11) TERMINAL_PACKAGES=(terminology); TERMINAL_NAME="Terminology"; TERMINAL_CMD="terminology"; TERMINAL_GPU="Optional"; TERMINAL_SESSION="X11/Wayland" ;;
   12) TERMINAL_PACKAGES=(cool-retro-term); TERMINAL_NAME="cool-retro-term"; TERMINAL_CMD="cool-retro-term"; TERMINAL_GPU="YES*"; TERMINAL_SESSION="X11/Wayland" ;;
   13) TERMINAL_PACKAGES=(konsole); TERMINAL_NAME="Konsole"; TERMINAL_CMD="konsole"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   14) TERMINAL_PACKAGES=(yakuake); TERMINAL_NAME="Yakuake"; TERMINAL_CMD="yakuake"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   15) TERMINAL_PACKAGES=(qterminal); TERMINAL_NAME="QTerminal"; TERMINAL_CMD="qterminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   16) TERMINAL_PACKAGES=(gnome-terminal); TERMINAL_NAME="GNOME Terminal"; TERMINAL_CMD="gnome-terminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   17) TERMINAL_PACKAGES=(gnome-console); TERMINAL_NAME="GNOME Console"; TERMINAL_CMD="kgx"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   18) TERMINAL_PACKAGES=(ptyxis); TERMINAL_NAME="Ptyxis"; TERMINAL_CMD="ptyxis"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   19) TERMINAL_PACKAGES=(mate-terminal); TERMINAL_NAME="MATE Terminal"; TERMINAL_CMD="mate-terminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   20) TERMINAL_PACKAGES=(lxterminal); TERMINAL_NAME="LXTerminal"; TERMINAL_CMD="lxterminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   21) TERMINAL_PACKAGES=(sakura); TERMINAL_NAME="Sakura"; TERMINAL_CMD="sakura"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   22) TERMINAL_PACKAGES=(terminator); TERMINAL_NAME="Terminator"; TERMINAL_CMD="terminator"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   23) TERMINAL_PACKAGES=(guake); TERMINAL_NAME="Guake"; TERMINAL_CMD="guake"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   24) TERMINAL_PACKAGES=(tilda); TERMINAL_NAME="Tilda"; TERMINAL_CMD="tilda"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   25) TERMINAL_PACKAGES=(pantheon-terminal); TERMINAL_NAME="Pantheon Terminal"; TERMINAL_CMD="io.elementary.terminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   26) TERMINAL_PACKAGES=(deepin-terminal); TERMINAL_NAME="Deepin Terminal"; TERMINAL_CMD="deepin-terminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   27) TERMINAL_PACKAGES=(deepin-terminal-gtk); TERMINAL_NAME="Deepin Terminal GTK"; TERMINAL_CMD="deepin-terminal"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   28) TERMINAL_PACKAGES=(rxvt-unicode); TERMINAL_NAME="rxvt-unicode"; TERMINAL_CMD="urxvt"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11 only" ;;
   29) TERMINAL_PACKAGES=(xterm); TERMINAL_NAME="xterm"; TERMINAL_CMD="xterm"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11 only" ;;
   30) TERMINAL_PACKAGES=(maui-station); TERMINAL_NAME="Maui Station"; TERMINAL_CMD="station"; TERMINAL_GPU="No"; TERMINAL_SESSION="X11/Wayland" ;;
   31) TERMINAL_PACKAGES=(qmlkonsole); TERMINAL_NAME="QMLKonsole"; TERMINAL_CMD="qmlkonsole"; TERMINAL_GPU="No"; TERMINAL_SESSION="Wayland/X11" ;;
   32) TERMINAL_PACKAGES=(foot); TERMINAL_NAME="foot"; TERMINAL_CMD="foot"; TERMINAL_GPU="No"; TERMINAL_SESSION="Wayland only" ;;
    *) die "Invalid terminal selection." ;;
esac

# Catch obviously incompatible choices before touching the disk.
if [[ "$DISPLAY_STACK" == "X11/Xorg" && "$TERMINAL_SESSION" == *"Wayland only"* ]]; then
    die "$TERMINAL_NAME is Wayland-only, but $DE_NAME is configured as an X11/Xorg session."
fi

# Verify the selected package still exists in the current official Arch repositories.
if (( ${#TERMINAL_PACKAGES[@]} > 0 )); then
    pacman -Si "${TERMINAL_PACKAGES[@]}" >/dev/null 2>&1 || \
        die "Selected terminal package is not available in the currently synced Arch repositories: ${TERMINAL_PACKAGES[*]}"
fi

log "Terminal: $TERMINAL_NAME"
log "Terminal GPU acceleration: $TERMINAL_GPU"
log "Terminal display support: $TERMINAL_SESSION"

# ----------------------------- GPU selection -----------------------------

title "Graphics Driver"

echo "  1) AMD       (Mesa + Vulkan Radeon)"
echo "  2) Intel     (Mesa + Intel Vulkan)"
echo "  3) NVIDIA    (proprietary current driver)"
echo "  4) Generic   (Mesa only)"
echo
read -rp "Selection [4]: " GPU_CHOICE
GPU_CHOICE=${GPU_CHOICE:-4}

case "$GPU_CHOICE" in
    1) GPU_PACKAGES=(mesa vulkan-radeon libva-mesa-driver mesa-vdpau) ;;
    2) GPU_PACKAGES=(mesa vulkan-intel intel-media-driver) ;;
    3) GPU_PACKAGES=(nvidia nvidia-utils nvidia-settings) ;;
    4) GPU_PACKAGES=(mesa) ;;
    *) die "Invalid GPU selection." ;;
esac

# ----------------------------- disk selection -----------------------------

title "Disk Selection"

mapfile -t AVAILABLE_DISKS < <(
    lsblk -dn -e 7 -o PATH,TYPE | awk '$2=="disk"{print $1}'
)

(( ${#AVAILABLE_DISKS[@]} > 0 )) || die "No installable disks were detected."

echo "Detected physical disks:"
echo
for i in "${!AVAILABLE_DISKS[@]}"; do
    disk="${AVAILABLE_DISKS[$i]}"
    info=$(lsblk -dn -o SIZE,MODEL,TRAN "$disk" | sed 's/[[:space:]]\+/ /g')
    printf "  %d) %-18s %s\n" "$((i+1))" "$disk" "$info"
done
echo
echo "  0) Enter a disk path manually"
echo

read -rp "Select target disk: " DISK_SELECTION
[[ "$DISK_SELECTION" =~ ^[0-9]+$ ]] || die "Enter a numeric disk selection."

if (( DISK_SELECTION == 0 )); then
    read -rp "Enter target disk path (example /dev/nvme0n1): " DISK
else
    index=$((DISK_SELECTION - 1))
    (( index >= 0 && index < ${#AVAILABLE_DISKS[@]} )) || die "Invalid disk selection."
    DISK="${AVAILABLE_DISKS[$index]}"
fi

[[ -b "$DISK" ]] || die "Not a block device: $DISK"

# Refuse obviously removable install media only if it is mounted as /run/archiso/bootmnt.
ARCHISO_SOURCE=$(findmnt -n -o SOURCE /run/archiso/bootmnt 2>/dev/null || true)
if [[ -n "$ARCHISO_SOURCE" ]]; then
    ARCHISO_PARENT=$(lsblk -no PKNAME "$ARCHISO_SOURCE" 2>/dev/null | head -n1 || true)
    if [[ -n "$ARCHISO_PARENT" && "/dev/$ARCHISO_PARENT" == "$DISK" ]]; then
        die "Refusing to erase the disk containing the running Arch installation media."
    fi
fi

echo
warn "EVERYTHING ON $DISK WILL BE PERMANENTLY ERASED."
lsblk "$DISK"
echo
read -rp "Type the exact disk path '$DISK' to confirm: " CONFIRM_DISK
[[ "$CONFIRM_DISK" == "$DISK" ]] || die "Disk confirmation did not match."

read -rp "Type ERASE to perform the destructive install: " CONFIRM_ERASE
[[ "$CONFIRM_ERASE" == "ERASE" ]] || die "Installation cancelled."

# ----------------------------- CPU microcode -----------------------------

CPU_VENDOR=$(awk -F: '/vendor_id/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)

case "$CPU_VENDOR" in
    GenuineIntel) MICROCODE="intel-ucode" ;;
    AuthenticAMD) MICROCODE="amd-ucode" ;;
    *) MICROCODE="" ;;
esac

# ----------------------------- partition -----------------------------

title "Partitioning"

umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

wipefs -af "$DISK"
sgdisk --zap-all "$DISK"

# EFI System Partition: 1 GiB
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI System" "$DISK"

# Btrfs root: remainder
sgdisk -n 2:0:0 -t 2:8300 -c 2:"Arch Btrfs" "$DISK"

partprobe "$DISK"
udevadm settle

if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

[[ -b "$EFI_PART" && -b "$ROOT_PART" ]] || die "Partition device nodes did not appear."

log "Formatting EFI partition as FAT32..."
mkfs.fat -F32 -n EFI "$EFI_PART"

log "Formatting Linux partition as Btrfs..."
mkfs.btrfs -f -L ARCH "$ROOT_PART"

# ----------------------------- Btrfs -----------------------------

title "Creating Btrfs Subvolumes"

mount "$ROOT_PART" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots

umount /mnt

BTRFS_OPTS="noatime,compress=zstd:3,ssd,space_cache=v2,discard=async"

mount -o "$BTRFS_OPTS,subvol=@" "$ROOT_PART" /mnt

mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot,efi}

mount -o "$BTRFS_OPTS,subvol=@home" "$ROOT_PART" /mnt/home
mount -o "$BTRFS_OPTS,subvol=@log" "$ROOT_PART" /mnt/var/log
mount -o "$BTRFS_OPTS,subvol=@pkg" "$ROOT_PART" /mnt/var/cache/pacman/pkg
mount -o "$BTRFS_OPTS,subvol=@snapshots" "$ROOT_PART" /mnt/.snapshots

mount "$EFI_PART" /mnt/efi

# ----------------------------- packages -----------------------------

title "Installing Base System"

BASE_PACKAGES=(
    base
    linux
    linux-firmware
    btrfs-progs
    grub
    efibootmgr
    snapper
    snap-pac
    btrfs-assistant
    dosfstools
    gptfdisk
    networkmanager
    network-manager-applet
    nm-connection-editor
    wireguard-tools
    sudo
    man-db
    man-pages
    texinfo
    bash-completion
    base-devel
    git
    nano
    vim
    neovim
    openssh
    rsync
    curl
    wget
    reflector
    zram-generator

    # audio / desktop integration
    pipewire
    pipewire-audio
    pipewire-pulse
    pipewire-alsa
    pipewire-jack
    wireplumber
    pavucontrol
    alsa-utils
    bluez
    bluez-utils

    # browser / media
    vivaldi
    vivaldi-ffmpeg-codecs
    chromium
    firefox
    thunderbird
    spotify-launcher
    mgba-qt
    mpv
    vlc
    ffmpeg

    # everyday tools
    keepassxc
    obsidian
    flameshot
    file-roller
    7zip
    unzip
    zip
    gparted
    flatpak
    gvfs
    gvfs-smb
    tumbler
    ffmpegthumbnailer

    # terminal / shell
    zsh
    starship
    fzf
    ripgrep
    fd
    bat
    eza
    zoxide
    tmux

    # development
    gcc
    clang
    cmake
    make
    gdb
    python
    python-pip
    nodejs
    npm
    rustup
    jdk-openjdk
    code
    github-cli

    # networking / IT
    bind
    traceroute
    nmap
    tcpdump
    wireshark-qt
    iperf3
    net-tools
    inetutils
    samba
    cifs-utils

    # system / disk
    btop
    htop
    nvtop
    smartmontools
    lm_sensors
    fastfetch
    exfatprogs
    ntfs-3g
    xfsprogs
    usbutils
    pciutils

    # containers / virtualization
    docker
    docker-compose
    podman
    qemu-full
    libvirt
    virt-manager
    dnsmasq
    edk2-ovmf
)

PACSTRAP_PACKAGES=("${BASE_PACKAGES[@]}" "${GPU_PACKAGES[@]}" "${DE_PACKAGES[@]}" "${TERMINAL_PACKAGES[@]}")

if [[ -n "$MICROCODE" ]]; then
    PACSTRAP_PACKAGES+=("$MICROCODE")
fi

pacstrap -K /mnt "${PACSTRAP_PACKAGES[@]}"

# ----------------------------- fstab -----------------------------

title "Generating fstab"

genfstab -U /mnt > /mnt/etc/fstab

# zram: use up to 8 GiB, typically half RAM via min()
cat > /mnt/etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

# ----------------------------- system config -----------------------------

title "Configuring Installed System"

cat > /mnt/root/install-vars.env <<EOF
HOSTNAME='$HOSTNAME'
USERNAME='$USERNAME'
TIMEZONE='$TIMEZONE'
LOCALE='$LOCALE'
DISPLAY_MANAGER='$DISPLAY_MANAGER'
MICROCODE='$MICROCODE'
ROOT_PART='$ROOT_PART'
EOF

arch-chroot /mnt /bin/bash <<'CHROOT'
set -Eeuo pipefail
source /root/install-vars.env

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

# Locale
sed -i "s/^#${LOCALE//./\\.}/${LOCALE}/" /etc/locale.gen || true
if ! grep -q "^${LOCALE//./\\.}" /etc/locale.gen; then
    echo "$LOCALE UTF-8" >> /etc/locale.gen
fi
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# User
useradd -m -G wheel,audio,video,storage,optical,libvirt -s /bin/bash "$USERNAME"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Services
SYSTEMD_OFFLINE=1 systemctl enable NetworkManager
SYSTEMD_OFFLINE=1 systemctl enable bluetooth
SYSTEMD_OFFLINE=1 systemctl enable sshd
SYSTEMD_OFFLINE=1 systemctl enable libvirtd
SYSTEMD_OFFLINE=1 systemctl enable docker
SYSTEMD_OFFLINE=1 systemctl enable fstrim.timer

if [[ -n "$DISPLAY_MANAGER" ]]; then
    SYSTEMD_OFFLINE=1 systemctl enable "$DISPLAY_MANAGER"
fi

# GRUB bootloader (UEFI). EFI is mounted at /efi; /boot remains in Btrfs.
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB

if grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=8/' /etc/default/grub
else
    echo 'GRUB_TIMEOUT=8' >> /etc/default/grub
fi

if grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub; then
    sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
else
    echo 'GRUB_TIMEOUT_STYLE=menu' >> /etc/default/grub
fi

grub-mkconfig -o /boot/grub/grub.cfg

# Make Vivaldi the default browser for the new user via environment.
install -d -m 0755 "/home/$USERNAME/.config"
cat > "/home/$USERNAME/.config/mimeapps.list" <<'EOF'
[Default Applications]
x-scheme-handler/http=vivaldi-stable.desktop
x-scheme-handler/https=vivaldi-stable.desktop
text/html=vivaldi-stable.desktop
application/xhtml+xml=vivaldi-stable.desktop
EOF

chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"

# Btrfs maintenance
SYSTEMD_OFFLINE=1 systemctl enable fstrim.timer

rm -f /root/install-vars.env
CHROOT

# ----------------------------- Snapper -----------------------------

title "Configuring Snapper Btrfs Snapshots"

arch-chroot /mnt /bin/bash <<SNAPPER_CHROOT
set -Eeuo pipefail

mkdir -p /etc/snapper/configs
mkdir -p /.snapshots

cat > /etc/snapper/configs/root <<EOF
SUBVOLUME="/"
FSTYPE="btrfs"
QGROUP=""
ALLOW_USERS="$USERNAME"
ALLOW_GROUPS="wheel"
SYNC_ACL="yes"
BACKGROUND_COMPARISON="yes"

NUMBER_CLEANUP="yes"
NUMBER_MIN_AGE="1800"
NUMBER_LIMIT="10"
NUMBER_LIMIT_IMPORTANT="10"

TIMELINE_CREATE="yes"
TIMELINE_CLEANUP="yes"
TIMELINE_MIN_AGE="1800"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_WEEKLY="0"
TIMELINE_LIMIT_MONTHLY="3"
TIMELINE_LIMIT_QUARTERLY="0"
TIMELINE_LIMIT_YEARLY="0"

EMPTY_PRE_POST_CLEANUP="yes"
EMPTY_PRE_POST_MIN_AGE="1800"
EOF

SYSTEMD_OFFLINE=1 systemctl enable snapper-timeline.timer
SYSTEMD_OFFLINE=1 systemctl enable snapper-cleanup.timer

chmod 750 /.snapshots
chown root:wheel /.snapshots

# Do not invoke Snapper during installation.
# The live ISO/chroot does not have the installed system's normal D-Bus/systemd
# environment. snap-pac and the Snapper timers will create snapshots normally
# after the first boot.
SNAPPER_CHROOT

cat > /mnt/usr/local/sbin/arch-rollback <<'ROLLBACK'
#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

echo "Available snapshots:"
snapper -c root list
echo
read -rp "Snapshot number to restore: " SNAP
[[ "$SNAP" =~ ^[0-9]+$ ]] || { echo "Invalid snapshot."; exit 1; }

echo
read -rp "Type ROLLBACK to continue: " CONFIRM
[[ "$CONFIRM" == "ROLLBACK" ]] || { echo "Cancelled."; exit 1; }

snapper -c root rollback "$SNAP"
grub-mkconfig -o /boot/grub/grub.cfg

echo "Rollback prepared. Reboot and choose the normal Arch Linux GRUB entry."
ROLLBACK
chmod 0755 /mnt/usr/local/sbin/arch-rollback

cat > /mnt/usr/local/sbin/arch-snapshot-baseline <<'BASELINE'
#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || {
    echo "Run as root: sudo arch-snapshot-baseline" >&2
    exit 1
}

snapper -c root create \
    --description "Fresh Arch installation baseline" \
    --cleanup-algorithm number

echo "Baseline snapshot created."
echo "You can verify it with: sudo snapper -c root list"
BASELINE

chmod 0755 /mnt/usr/local/sbin/arch-snapshot-baseline

# ----------------------------- i3 / Rofi configuration -----------------------------

if [[ "$DE_CHOICE" == "7" ]]; then
    title "Configuring i3 Application Launcher"

    mkdir -p "/mnt/home/$USERNAME/.config/i3"
    mkdir -p "/mnt/home/$USERNAME/.config/rofi"

    if [[ -f /mnt/etc/i3/config ]]; then
        cp /mnt/etc/i3/config "/mnt/home/$USERNAME/.config/i3/config"
    else
        cat > "/mnt/home/$USERNAME/.config/i3/config" <<'I3BASE'
set $mod Mod4
font pango:monospace 8
bindsym $mod+Return exec i3-sensible-terminal
bindsym $mod+Shift+q kill
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exec "i3-nagbar -t warning -m 'Exit i3?' -B 'Yes' 'i3-msg exit'"
bar {
    status_command i3status
}
I3BASE
    fi

    if grep -q '^set \$mod ' "/mnt/home/$USERNAME/.config/i3/config"; then
        sed -i 's/^set \$mod .*/set $mod Mod4/' "/mnt/home/$USERNAME/.config/i3/config"
    else
        sed -i '1i set $mod Mod4' "/mnt/home/$USERNAME/.config/i3/config"
    fi

    sed -i '/^[[:space:]]*bindsym[[:space:]]\+\$mod+d[[:space:]]/d' \
        "/mnt/home/$USERNAME/.config/i3/config"

    # Make Super+Enter launch the terminal selected in this installer.
    sed -i '/^[[:space:]]*bindsym[[:space:]]\+\$mod+Return[[:space:]]/d' \
        "/mnt/home/$USERNAME/.config/i3/config"

    if [[ -n "$TERMINAL_CMD" ]]; then
        printf '\n# Installer-selected terminal\nbindsym $mod+Return exec --no-startup-id %s\n' \
            "$TERMINAL_CMD" >> "/mnt/home/$USERNAME/.config/i3/config"
    fi

    cat >> "/mnt/home/$USERNAME/.config/i3/config" <<'I3ROFI'

# Floating application search (Manjaro-style)
bindsym $mod+d exec --no-startup-id rofi -show drun
I3ROFI

    cat > "/mnt/home/$USERNAME/.config/rofi/config.rasi" <<'ROFI'
configuration {
    modi: "drun,run";
    show-icons: true;
    drun-display-format: "{name}";
    display-drun: "Apps";
}

window {
    location: center;
    anchor: center;
    width: 42%;
}

mainbox {
    children: [ "inputbar", "listview" ];
    spacing: 8px;
    padding: 12px;
}

inputbar {
    children: [ "prompt", "entry" ];
    spacing: 8px;
}

prompt {
    enabled: true;
    str: "Search";
}

listview {
    lines: 8;
    columns: 1;
    fixed-height: false;
    scrollbar: false;
}
ROFI

    arch-chroot /mnt chown -R "$USERNAME:$USERNAME" \
        "/home/$USERNAME/.config/i3" "/home/$USERNAME/.config/rofi"

    log "i3 launcher configured: Super+D -> centered Rofi application search."
fi

# ----------------------------- passwords -----------------------------

title "Set Passwords"

echo "Set the ROOT password:"
arch-chroot /mnt passwd root

echo
echo "Set the password for $USERNAME:"
arch-chroot /mnt passwd "$USERNAME"

# ----------------------------- Rust toolchain bootstrap -----------------------------

title "Initializing Rust Toolchain"

# rustup provides cargo/rustc shims, but they cannot work until a default
# toolchain is selected. paru is written in Rust, so initialize stable first.
arch-chroot /mnt runuser -u "$USERNAME" -- bash -lc '
set -e
rustup default stable
rustc --version
cargo --version
'

# ----------------------------- AUR helper + Plex -----------------------------

title "Installing AUR Helper and AUR Applications"

# Build paru as the regular user using a temporary writable build directory.
mkdir -p "/mnt/home/$USERNAME/.cache/aur-build"
arch-chroot /mnt chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.cache"

arch-chroot /mnt runuser -u "$USERNAME" -- bash -lc '
set -e
cd "$HOME/.cache/aur-build"
rm -rf paru
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si --noconfirm
'

log "Installing Plex clients, melonDS, and GRUB Btrfs integration from the AUR..."
if ! arch-chroot /mnt runuser -u "$USERNAME" -- bash -lc 'paru -S --needed --noconfirm plex-htpc plexamp-bin melonds grub-btrfs-git'; then
    warn "One or more AUR packages failed to build."
    warn "The base system is still installed. After reboot, retry:"
    warn "  paru -S plex-htpc plexamp-bin melonds grub-btrfs-git"
fi

if arch-chroot /mnt test -x /usr/bin/grub-btrfsd; then
    arch-chroot /mnt /bin/bash <<'GRUB_BTRFS'
set -Eeuo pipefail
grub-mkconfig -o /boot/grub/grub.cfg
if systemctl list-unit-files | grep -q '^grub-btrfsd.service'; then
    SYSTEMD_OFFLINE=1 systemctl enable grub-btrfsd.service
fi
GRUB_BTRFS
else
    warn "grub-btrfs was not installed; normal GRUB booting will still work."
fi

# ----------------------------- default shell / rust -----------------------------

title "Developer Setup"

# Add useful shell initialization without forcing zsh as login shell.
cat >> "/mnt/home/$USERNAME/.bashrc" <<'EOF'

# User workstation helpers
eval "$(starship init bash)"
eval "$(zoxide init bash)"
EOF

arch-chroot /mnt chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bashrc"

# Docker group membership
arch-chroot /mnt usermod -aG docker "$USERNAME"

# ----------------------------- summary -----------------------------

title "Installation Complete"

echo -e "${GREEN}Arch Linux has been installed successfully.${RESET}"
echo
echo "Disk:          $DISK"
echo "Filesystem:    Btrfs Linux partition (/boot included in snapshots)"
echo "EFI:           1 GiB FAT32 mounted at /efi"
echo "Hostname:      $HOSTNAME"
echo "User:          $USERNAME"
echo "Desktop:       $DE_NAME"
echo "Display stack: $DISPLAY_STACK"
echo "Terminal:      $TERMINAL_NAME (GPU: $TERMINAL_GPU; $TERMINAL_SESSION)"
echo "Shell:         Zsh"
if [[ "$DE_CHOICE" == "7" ]]; then
    echo "i3 launcher:   Super+D -> Rofi floating app search"
fi
echo "Browser:       Vivaldi"
echo "Snapshots:     Snapper + snap-pac"
echo "Bootloader:    GRUB + grub-btrfs"
echo
echo "Everyday / productivity:"
echo "  • Vivaldi"
echo "  • Obsidian"
echo "  • WireGuard client via NetworkManager + wireguard-tools"
echo
echo "Installed media apps:"
echo "  • Spotify"
echo "  • Plex HTPC"
echo "  • Plexamp"
echo "  • MPV"
echo "  • VLC"
echo
echo "Emulation:"
echo "  • mGBA (GB / GBC / GBA)"
echo "  • melonDS (Nintendo DS)"
echo
echo "Installed development/IT stack:"
echo "  • Code - OSS, Neovim, Git/GitHub CLI"
echo "  • GCC, Clang, GDB, CMake"
echo "  • Python, Node.js/npm, Rust, Java"
echo "  • Docker, Podman"
echo "  • QEMU/KVM, libvirt, virt-manager"
echo "  • Wireshark, Nmap, tcpdump, iperf3, SSH, SMB tools"
echo
echo "Recovery:"
echo "  • Snapper + snap-pac snapshots begin after first boot"
echo "  • GRUB snapshot boot entries via grub-btrfs"
echo "  • Rollback helper: sudo arch-rollback"
echo
echo "After first boot:"
echo "  • Run: sudo arch-snapshot-baseline"
echo "    This creates the initial known-good Snapper snapshot with normal D-Bus/systemd running."
echo
echo "Before rebooting:"
echo "  umount -R /mnt"
echo "  reboot"
echo
warn "Remove the Arch installation media when the machine reboots."