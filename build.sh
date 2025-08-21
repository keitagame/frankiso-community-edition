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
SETTING_FILE="./settings.conf"
if [[ -f "$SETTING_FILE" ]]; then
    source "$SETTING_FILE"
else
    echo "設定ファイル $SETTING_FILE が見つかりません" >&2
    exit 1
fi

# デフォルト値
ENVIRONMENT="default"

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
  minimal)
    echo "=== Minimal ビルドを開始 ==="
      PACKAGES="./edition/minimal/packages"
      if [[ -f "$PACKAGES" ]]; then
        source "$PACKAGES"
      else
        echo "設定ファイル $PACKAGES が見つかりません" >&2
      exit 1
      fi
    ;;
  full)
    echo "=== Full ビルドを開始 ==="
    # Full 用のビルド処理
    ;;
  *)
    echo "不明な環境: $ENVIRONMENT"
    exit 1
    ;;
esac

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

# ===== 設定ファイル追加 =====



mkdir -p "$ISO_ROOT/isolinux"
cp /usr/lib/syslinux/bios/isolinux.bin "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/bios/ldlinux.c32 "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/bios/menu.c32 "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/bios/libcom32.c32 "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/bios/libutil.c32 "$ISO_ROOT/isolinux/"

cat <<EOF > "$ISO_ROOT/isolinux/isolinux.cfg"
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT frankos

LABEL frankos
    MENU LABEL Boot FrankOS Live (BIOS)
    LINUX /vmlinuz-linux
    INITRD /initramfs-linux.img
    APPEND archisobasedir=arch archisolabel=$ISO_LABEL
EOF


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
cat <<EOF | sudo tee mnt_esp/loader/loader.conf
default  frank
timeout  3
console-mode max
editor   no
EOF

cat <<EOF | sudo tee mnt_esp/loader/entries/arch.conf
title   FrankOS Live (${ISO_VERSION})
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options archisobasedir=arch archisolabel=$ISO_LABEL
EOF

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
