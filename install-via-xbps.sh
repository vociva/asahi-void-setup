#!/bin/bash
set -euo pipefail

echo "=============================================="
echo " Void Linux Partition Setup Helper (Asahi)"
echo "=============================================="
echo
echo "Before continuing, use cfdisk to create two partitions in the"
echo "EMPTY SPACE left by the Asahi installer:"
echo
echo "  1. A 512M partition, type 'EFI System'"
echo "  2. A partition using the rest of the free space, type 'Linux filesystem'"
echo
echo "Do NOT touch, delete, resize, or retype any existing Apple/Asahi"
echo "partitions. Only operate on the empty space."
echo
echo "Run 'cfdisk /dev/nvme0n1' now in another terminal/tty if you haven't"
echo "already, then come back here and press Enter to continue."
read -r -p "Press Enter once partitioning is done... "
echo

DISK="/dev/nvme0n1"

# --- Get partition numbers from user ---
read -r -p "Enter the partition NUMBER for the EFI partition (e.g. 5): " EFI_NUM
read -r -p "Enter the partition NUMBER for the Linux root partition (e.g. 6): " ROOT_NUM

# Validate they're plain numbers
if ! [[ "$EFI_NUM" =~ ^[0-9]+$ ]]; then
    echo "Error: '$EFI_NUM' is not a valid partition number."
    exit 1
fi
if ! [[ "$ROOT_NUM" =~ ^[0-9]+$ ]]; then
    echo "Error: '$ROOT_NUM' is not a valid partition number."
    exit 1
fi
if [[ "$EFI_NUM" == "$ROOT_NUM" ]]; then
    echo "Error: EFI and root partition numbers can't be the same."
    exit 1
fi

EFI_PART="${DISK}p${EFI_NUM}"
ROOT_PART="${DISK}p${ROOT_NUM}"

echo
echo "EFI partition:  $EFI_PART"
echo "Root partition: $ROOT_PART"
echo

# --- Confirm both partitions exist ---
for p in "$EFI_PART" "$ROOT_PART"; do
    if [[ ! -b "$p" ]]; then
        echo "Error: $p does not exist as a block device."
        exit 1
    fi
done

# --- Check partition types via lsblk, refuse anything Apple-flavored ---
if ! command -v lsblk >/dev/null 2>&1; then
    echo "Error: lsblk not found (expected from util-linux, should always be present)."
    exit 1
fi

get_ptype() {
    # Prints the GPT partition type GUID for a given partition device
    lsblk -no PARTTYPE "$1"
}

EFI_TYPE=$(get_ptype "$EFI_PART" | tr '[:upper:]' '[:lower:]')
ROOT_TYPE=$(get_ptype "$ROOT_PART" | tr '[:upper:]' '[:lower:]')

echo "Detected EFI partition type GUID:  $EFI_TYPE"
echo "Detected root partition type GUID: $ROOT_TYPE"
echo

# Known GPT type GUIDs
EFI_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
LINUX_GUID="0fc63daf-8483-4772-8e79-3d69d8477de4"

# Apple GPT type GUIDs we must never touch (APFS, HFS+, Apple boot, Apple RAID, etc.)
APPLE_GUIDS=(
    "7c3457ef-0000-11aa-aa11-00306543ecac"  # Apple APFS
    "48465300-0000-11aa-aa11-00306543ecac"  # Apple HFS/HFS+
    "426f6f74-0000-11aa-aa11-00306543ecac"  # Apple Boot
    "52414944-0000-11aa-aa11-00306543ecac"  # Apple RAID
    "52414944-5f4f-11aa-aa11-00306543ecac"  # Apple RAID offline
    "4c616265-6c00-11aa-aa11-00306543ecac"  # Apple Label
    "5265636f-7665-11aa-aa11-00306543ecac"  # Apple TV Recovery
    "53746f72-6167-11aa-aa11-00306543ecac"  # Apple Core Storage
)

for guid in "${APPLE_GUIDS[@]}"; do
    if [[ "$EFI_TYPE" == "$guid" ]]; then
        echo "REFUSING: partition $EFI_NUM has an Apple partition type GUID ($EFI_TYPE)."
        exit 1
    fi
    if [[ "$ROOT_TYPE" == "$guid" ]]; then
        echo "REFUSING: partition $ROOT_NUM has an Apple partition type GUID ($ROOT_TYPE)."
        exit 1
    fi
done

if [[ "$EFI_TYPE" != "$EFI_GUID" ]]; then
    echo "REFUSING: partition $EFI_NUM is not type 'EFI System' ($EFI_GUID)."
    echo "  Got: $EFI_TYPE"
    exit 1
fi
if [[ "$ROOT_TYPE" != "$LINUX_GUID" ]]; then
    echo "REFUSING: partition $ROOT_NUM is not type 'Linux filesystem' ($LINUX_GUID)."
    echo "  Got: $ROOT_TYPE"
    exit 1
fi

echo "Partition types look correct (EFI System, Linux filesystem)."
echo

# --- Final confirmation before destructive formatting ---
echo "About to format:"
echo "  $EFI_PART  -> vfat, label VOID-EFI"
echo "  $ROOT_PART -> ext4, label VOID"
echo
read -r -p "Type 'yes' to proceed with formatting: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted, nothing was formatted."
    exit 1
fi

# --- Wipe stale signatures (e.g. leftover swap) then format ---
echo
echo "Wiping filesystem signatures on $EFI_PART ..."
wipefs -a "$EFI_PART"

echo "Wiping filesystem signatures on $ROOT_PART ..."
wipefs -a "$ROOT_PART"

echo
echo "Formatting $EFI_PART as vfat (label VOID-EFI) ..."
mkfs.vfat -F32 -n "VOID-EFI" "$EFI_PART"

echo "Formatting $ROOT_PART as ext4 (label VOID) ..."
mkfs.ext4 -L "VOID" "$ROOT_PART"

echo
echo "Done."
echo "  $EFI_PART  formatted vfat,  label VOID-EFI"
echo "  $ROOT_PART formatted ext4, label VOID"

# --- Mount everything under /mnt for the chroot/install ---
echo
echo "Mounting $ROOT_PART -> /mnt ..."
mount "$ROOT_PART" /mnt/

echo "Creating /mnt/boot/efi ..."
mkdir -p /mnt/boot/efi/

echo "Mounting $EFI_PART -> /mnt/boot/efi ..."
mount "$EFI_PART" /mnt/boot/efi/

echo
echo "Mounted:"
echo "  $ROOT_PART -> /mnt"
echo "  $EFI_PART  -> /mnt/boot/efi"

# --- Void repo / arch settings ---
REPO=https://repo-default.voidlinux.org/current/aarch64
ARCH=aarch64
XBPS_ARCH=$ARCH

echo
echo "Using Void repo settings:"
echo "  REPO=$REPO"
echo "  ARCH=$ARCH"
echo "  XBPS_ARCH=$XBPS_ARCH"

# --- Copy xbps keys into target before installing ---
echo
echo "Copying xbps keys into /mnt ..."
echo "Running: mkdir -p /mnt/var/db/xbps/keys"
mkdir -p /mnt/var/db/xbps/keys
echo "Running: cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/"
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

# --- Install base system into /mnt ---
echo
echo "Installing base system into /mnt ..."
echo "Running: xbps-install -Sy -r /mnt -R \"$REPO\" base-system asahi-base asahi-audio grub-arm64-efi"
xbps-install -Sy -r /mnt -R "$REPO" base-system asahi-base asahi-audio grub-arm64-efi

# --- Generate fstab ---
echo
echo "Generating fstab ..."
echo "Running: xgenfstab -U /mnt > /mnt/etc/fstab"
xgenfstab -U /mnt > /mnt/etc/fstab

echo
echo "fstab contents:"
cat /mnt/etc/fstab

# --- Generate the in-chroot setup script ---
echo
echo "Writing chroot setup script to /mnt/root/chroot-setup.sh ..."

# --- Ask for hostname before chrooting ---
read -r -p "Enter the hostname for this machine: " NEW_HOSTNAME
if [[ -z "$NEW_HOSTNAME" ]]; then
    echo "Error: hostname cannot be empty."
    exit 1
fi
echo "Using hostname: $NEW_HOSTNAME"

cat > /mnt/root/chroot-setup.sh << 'CHROOT_SCRIPT'
#!/bin/bash
set -euo pipefail

echo "=============================================="
echo " Running inside chroot"
echo "=============================================="

# --- Set hostname ---
echo
echo "Setting hostname to __HOSTNAME__ ..."
echo "__HOSTNAME__" > /etc/hostname
cat /etc/hostname

# --- Set timezone and keymap in rc.conf ---
echo
echo "Setting timezone to America/Denver in /etc/rc.conf ..."
if grep -q '^TIMEZONE=' /etc/rc.conf; then
    sed -i 's|^TIMEZONE=.*|TIMEZONE="America/Denver"|' /etc/rc.conf
elif grep -q '^#TIMEZONE=' /etc/rc.conf; then
    sed -i 's|^#TIMEZONE=.*|TIMEZONE="America/Denver"|' /etc/rc.conf
else
    echo 'TIMEZONE="America/Denver"' >> /etc/rc.conf
fi

echo "Setting keymap to us in /etc/rc.conf ..."
if grep -q '^KEYMAP=' /etc/rc.conf; then
    sed -i 's|^KEYMAP=.*|KEYMAP="us"|' /etc/rc.conf
elif grep -q '^#KEYMAP=' /etc/rc.conf; then
    sed -i 's|^#KEYMAP=.*|KEYMAP="us"|' /etc/rc.conf
else
    echo 'KEYMAP="us"' >> /etc/rc.conf
fi

echo "Relevant /etc/rc.conf lines:"
grep -E '^(TIMEZONE|KEYMAP)=' /etc/rc.conf

# --- Enable en_US.UTF-8 locale ---
echo
echo "Enabling en_US.UTF-8 UTF-8 in /etc/default/libc-locales ..."
sed -i 's|^#en_US.UTF-8 UTF-8|en_US.UTF-8 UTF-8|' /etc/default/libc-locales
grep '^en_US.UTF-8' /etc/default/libc-locales

echo
echo "Reconfiguring locales ..."
xbps-reconfigure -f glibc-locales

# --- Note on root password ---
echo
echo "NOTE: root password was not set by this script."
echo "Run 'passwd' manually before rebooting, from outside or by"
echo "chrooting back in, since it defaults to blank/voidlinux."

# --- Install GRUB ---
echo
echo "Installing GRUB ..."
echo "Running: grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=\"Void\" --removable"
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id="Void" --removable

# --- Reconfigure all packages ---
echo
echo "Reconfiguring all packages ..."
echo "Running: xbps-reconfigure -fa"
xbps-reconfigure -fa

echo
echo "Chroot setup complete."
CHROOT_SCRIPT

# Inject the hostname into the chroot script (heredoc above is quoted/literal)
sed -i "s/__HOSTNAME__/$NEW_HOSTNAME/g" /mnt/root/chroot-setup.sh

chmod +x /mnt/root/chroot-setup.sh

echo "Wrote /mnt/root/chroot-setup.sh"

# --- Enter chroot and run it ---
echo
echo "Entering chroot and running setup script ..."
echo "Running: xchroot /mnt /root/chroot-setup.sh"
xchroot /mnt /root/chroot-setup.sh

echo
echo "Back out of chroot."

# --- Unmount everything ---
echo
echo "Unmounting /mnt ..."
echo "Running: umount -R /mnt"
umount -R /mnt

echo
echo "=============================================="
echo " Install complete. It is now safe to reboot."
echo "=============================================="
echo "Remember: root password is still blank/default."
echo "Set it with 'passwd' after logging in, or chroot"
echo "back in from the live image if you get locked out."
