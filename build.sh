#!/usr/bin/env bash
# build-archiso.sh
# YAMLでカスタム可能な Arch Linux ISO ビルドスクリプト（UEFI対応）
# 依存: archiso, yq (v4), git（relengコピーが必要な場合）
set -euo pipefail

# 設定ファイルを読み込み
CONFIG_FILE="./ISOCONFIG"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "設定ファイル $CONFIG_FILE が見つかりません" >&2
    exit 1
fi
BOOT="./boot/config"
if [[ -f "$BOOT" ]]; then
    source "$BOOT"
else
    echo "設定ファイル $CONFIG_FILE が見つかりません" >&2
    exit 1
fi
SETTING_FILE="./settings.conf"
if [[ -f "$SETTING_FILE" ]]; then
    source "$SETTING_FILE"
else
    echo "設定ファイル $SETTING_FILE が見つかりません" >&2
    exit 1
fi

USER_FILE="./user/root"
if [[ -f "$USER_FILE" ]]; then
    source "$USER_FILE"
else
    echo "設定ファイル $SETTING_FILE が見つかりません" >&2
    exit 1
fi

# オプション解析
while getopts "e:" opt; do
  case "$opt" in
    e) ENVIRONMENT="$OPTARG" ;;
    
    
    \?) 
      echo "使い方: $0 [-e environment]"
      exit 1
      ;;
  esac
done

# 処理分岐
case "$ENVIRONMENT" in
 
  full)
    echo "=== Full ビルドを開始 ==="
    # Full 用のビルド処理
    ;;
  *)
     echo "=== $ENVIRONMENT ビルドを開始 ==="
      PACKAGES="./edition/$ENVIRONMENT/packages"
      SETUP="./edition/$ENVIRONMENT/setup"
      if [[ -f "$PACKAGES" ]]; then
        source "$PACKAGES"
      else
        echo "設定ファイル $PACKAGES が見つかりません" >&2
      exit 1
      fi
    ;;
esac
ST_FILE=$SETUP
if [[ -f "$ST_FILE" ]]; then
    source "$ST_FILE"
else
    echo "設定ファイル $SETTING_FILE が見つかりません" >&2
    exit 1
fi
# ===== 前準備 =====
echo "[*] 作業ディレクトリを初期化..."

rm -rf work/ out/ mnt_esp/
rm -rf "$WORKDIR" "$OUTPUT"
mkdir -p "$AIROOTFS" "$ISO_ROOT" "$OUTPUT"

# ===== ベースシステム作成 =====
echo "[*] ベースシステムを pacstrap でインストール..."
AIROOTFS_IMG="$WORKDIR/airootfs.img"
AIROOTFS_MOUNT="$WORKDIR/airootfs"


# 8GB の空き容量を確保
truncate -s 8G "$AIROOTFS_IMG"
mkfs.ext4 "$AIROOTFS_IMG"

# マウント
mkdir -p "$AIROOTFS_MOUNT"
mount -o loop "$AIROOTFS_IMG" "$AIROOTFS_MOUNT"
AIROOTFS="$AIROOTFS_MOUNT"
pacstrap  "$AIROOTFS" $PACKAGE

mkdir -p "$AIROOTFS/etc/pacman.d"
cp ./system/pacman/pacman.conf "$AIROOTFS/etc/"
cp /etc/pacman.d/mirrorlist "$AIROOTFS/etc/pacman.d/"
# ===== 設定ファイル追加 =====
arch-chroot "$AIROOTFS" pacman -S $INSTALL --noconfirm
arch-chroot "$AIROOTFS" $CMD
# ===== ユーザー作成 =====
echo "[*] ユーザーを作成しています..."

arch-chroot "$AIROOTFS" useradd -m -G wheel -s /bin/bash $NAME
echo "$NAME:$NAME" | arch-chroot "$AIROOTFS" chpasswd
if [ "$SUDO" = "true" ]; then
  arch-chroot "$AIROOTFS" pacman -S sudo --noconfirm
  echo "%wheel ALL=(ALL:ALL) ALL" >> "$AIROOTFS/etc/sudoers"
fi

if [ "$bios" = "isolinux" ]; then

  mkdir -p "$ISO_ROOT/isolinux"
  cp /usr/lib/syslinux/bios/isolinux.bin "$ISO_ROOT/isolinux/"
  cp /usr/lib/syslinux/bios/ldlinux.c32 "$ISO_ROOT/isolinux/"
  cp /usr/lib/syslinux/bios/menu.c32 "$ISO_ROOT/isolinux/"
  cp /usr/lib/syslinux/bios/libcom32.c32 "$ISO_ROOT/isolinux/"
  cp /usr/lib/syslinux/bios/libutil.c32 "$ISO_ROOT/isolinux/"
fi
cp ./isolinux/isolinux.cfg "$ISO_ROOT/isolinux/isolinux.cfg"

   




mkdir -p "$ISO_ROOT/arch/$ARCH"
mksquashfs "$AIROOTFS" "$ISO_ROOT/arch/$ARCH/airootfs.sfs"  -comp gzip


# ===== ブートローダー構築 (systemd-boot UEFI) =====
echo "[*] EFI ブートローダー準備..."
# 1. EFI用FATイメージ作成
dd if=/dev/zero of="$ISO_ROOT/efiboot.img" bs=1M count=200
mkfs.vfat "$ISO_ROOT/efiboot.img"


# 2. マウントしてファイルコピー
mkdir mnt_esp


# 2. マウントしてファイルコピー
sudo mount "$ISO_ROOT/efiboot.img" mnt_esp

mkdir -p mnt_esp/EFI/BOOT
cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi mnt_esp/EFI/BOOT/BOOTX64.EFI
cp "$AIROOTFS/boot/vmlinuz-linux" mnt_esp/
cp "$AIROOTFS/boot/initramfs-linux.img" mnt_esp/
# loader.conf と arch.conf を配置
mkdir -p mnt_esp/loader/entries
cp ./systemd/loader.conf mnt_esp/loader/
cp ./systemd/arch.conf mnt_esp/loader/entries/



sudo umount -l mnt_esp
rmdir mnt_esp

# カーネルと initramfs を ISOルートにコピー
cp "$AIROOTFS/boot/vmlinuz-linux" "$ISO_ROOT/"
cp "$AIROOTFS/boot/initramfs-linux.img" "$ISO_ROOT/"
# アンマウント
sudo umount -l "$AIROOTFS"

# loop デバイスの解放（必要なら）
losetup -D

# ===== ISO 作成 =====
echo "[*] ISO イメージ生成..."
xorriso -as mkisofs \
  -eltorito-boot isolinux/isolinux.bin \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid $ISO_LABEL \
  -eltorito-alt-boot \
  -e efiboot.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -output "${OUTPUT}/${ISO_NAME}-${ISO_VERSION}-${ARCH}.iso" \
  "$ISO_ROOT"

echo "[*] 完了! 出力: ${OUTPUT}/${ISO_NAME}-${ISO_VERSION}-${ARCH}.iso"
