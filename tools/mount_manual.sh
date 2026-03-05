#!/bin/bash
# Manual Mount Helper - Mount partitions for manual editing

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly WORK_DIR="${WORK_DIR:-$PROJECT_ROOT/work}"
readonly PARTITIONS_DIR="${PARTITIONS_DIR:-$WORK_DIR/super/partitions}"
MOUNT_BASE="${MOUNT_BASE:-/tmp/rom_builder_mount}"

usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Mount EROFS/EXT4 partitions for manual editing:

Options:
  --mount-all     Mount all partitions in work/super/partitions
  --mount PART    Mount specific partition (system, vendor, product, odm)
  --unmount-all   Unmount all partitions
  --list          List mounted partitions
  --status         Show status of partitions

Environment:
  Requires sudo access for EROFS mounting

Examples:
  $0 --mount system
  $0 --mount-all
  $0 --unmount-all
  $0 --list

EOF
  exit 1
}

check_sudo() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script requires sudo access"
    echo "Run: sudo $0 $*"
    exit 1
  fi
}

mount_partition() {
  local partition_name="$1"
  local img_file="$PARTITIONS_DIR/${partition_name}.img"
  local mount_point="$MOUNT_BASE/$partition_name"
  
  if [[ ! -f "$img_file" ]]; then
    echo "ERROR: Partition image not found: $img_file"
    return 1
  fi
  
  if [[ -d "$mount_point" ]]; then
    echo "ERROR: Already mounted at $mount_point"
    return 1
  fi
  
  mkdir -p "$mount_point"
  
  local fs_type
  fs_type=$(file -b "$img_file" 2>/dev/null || echo "unknown")
  
  echo "Mounting $partition_name ($fs_type)..."
  
  if echo "$fs_type" | grep -qi "EROFS"; then
    if ! mount -t erofs -o loop,ro "$img_file" "$mount_point"; then
      echo "ERROR: Failed to mount EROFS partition"
      rmdir "$mount_point"
      return 1
    fi
  elif echo "$fs_type" | grep -qi "ext2\|ext3\|ext4"; then
    if ! mount -t ext4 -o loop "$img_file" "$mount_point"; then
      echo "ERROR: Failed to mount EXT4 partition"
      rmdir "$mount_point"
      return 1
    fi
  else
    echo "ERROR: Unknown filesystem type: $fs_type"
    rmdir "$mount_point"
    return 1
  fi
  
  echo "Mounted: $mount_point"
  echo ""
  echo "IMPORTANT:"
  echo "  - For EROFS: This is READ-ONLY mount"
  echo "  - To edit: Copy files to a writable location, modify, then repack"
  echo "  - Use: ./repack_erofs.sh --partition $partition_name"
  return 0
}

mount_all_partitions() {
  check_sudo
  mkdir -p "$MOUNT_BASE"
  
  local partitions=(system vendor product odm system_ext vendor_dlkm system_dlkm)
  
  for partition in "${partitions[@]}"; do
    local img_file="$PARTITIONS_DIR/${partition}.img"
    
    if [[ -f "$img_file" ]]; then
      mount_partition "$partition" || true
    fi
  done
  
  echo ""
  echo "All partitions mounted to: $MOUNT_BASE"
}

unmount_partition() {
  local partition_name="$1"
  local mount_point="$MOUNT_BASE/$partition_name"
  
  if mountpoint -q "$mount_point" 2>/dev/null; then
    echo "Unmounting $partition_name..."
    umount "$mount_point" || echo "Warning: Failed to unmount $mount_point"
    rmdir "$mount_point" 2>/dev/null
    echo "Unmounted"
  else
    echo "Not mounted: $partition_name"
  fi
}

unmount_all_partitions() {
  check_sudo
  
  for mount_point in "$MOUNT_BASE"/*; do
    if [[ -d "$mount_point" ]] && mountpoint -q "$mount_point" 2>/dev/null; then
      local partition_name
      partition_name=$(basename "$mount_point")
      unmount_partition "$partition_name"
    fi
  done
}

list_mounted() {
  echo "Mounted partitions:"
  echo ""
  
  if [[ ! -d "$MOUNT_BASE" ]]; then
    echo "No mounts found"
    return 0
  fi
  
  for mount_point in "$MOUNT_BASE"/*; do
    if [[ -d "$mount_point" ]]; then
      local partition_name
      partition_name=$(basename "$mount_point")
      
      local status="unmounted"
      if mountpoint -q "$mount_point" 2>/dev/null; then
        status="MOUNTED"
      fi
      
      local img_size
      local img_file="$PARTITIONS_DIR/${partition_name}.img"
      if [[ -f "$img_file" ]]; then
        img_size=$(du -h "$img_file" | cut -f1)
      else
        img_size="N/A"
      fi
      
      printf "  %-15s %-10s %s\n" "$partition_name" "[$status]" "$img_size"
    fi
  done
}

show_status() {
  echo "Partition Status:"
  echo "================"
  
  local partitions_dir="$PARTITIONS_DIR"
  
  if [[ ! -d "$partitions_dir" ]]; then
    echo "ERROR: Partitions directory not found: $partitions_dir"
    return 1
  fi
  
  echo ""
  printf "%-15s %-10s %s\n" "Partition" "Type" "Size"
  echo "----------------------------------------"
  
  for img in "$partitions_dir"/*.img; do
    if [[ -f "$img" ]]; then
      local name
      name=$(basename "$img" .img)
      local size
      size=$(du -h "$img" | cut -f1)
      local fs_type
      fs_type=$(file -b "$img" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
      
      printf "%-15s %-10s %s\n" "$name" "$fs_type" "$size"
    fi
  done
}

case "${1:-}" in
  --mount-all)
    mount_all_partitions
    ;;
  --mount)
    if [[ -z "${2:-}" ]]; then
      usage
    fi
    check_sudo
    mount_partition "$2"
    ;;
  --unmount-all)
    unmount_all_partitions
    ;;
  --unmount)
    if [[ -z "${2:-}" ]]; then
      usage
    fi
    unmount_partition "$2"
    ;;
  --list)
    list_mounted
    ;;
  --status)
    show_status
    ;;
  *)
    usage
    ;;
esac
