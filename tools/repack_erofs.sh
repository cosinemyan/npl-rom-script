#!/bin/bash
# EROFS Repack Helper - Rebuild EROFS images after manual editing

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly WORK_DIR="${WORK_DIR:-$PROJECT_ROOT/work}"
PARTITIONS_DIR="${PARTITIONS_DIR:-$WORK_DIR/super/partitions}"
REPACK_DIR="${REPACK_DIR:-/tmp/rom_builder_edit}"

usage() {
  cat << EOF
Usage: $0 --partition PARTITION

Repack a partition after manual editing:

Options:
  --partition NAME   Partition to repack (system, vendor, product, odm, etc.)
  --list            List partitions ready for repacking
  --backup           Backup original partition before repacking
  --help            Show this help

Workflow:
  1. Mount partition: sudo ./tools/mount_manual.sh --mount <partition>
  2. Copy files to editable location: cp -a /tmp/rom_builder_mount/<partition> $REPACK_DIR/
  3. Edit files in $REPACK_DIR/
  4. Repack: $0 --partition <partition>
  5. Rebuild super: ./cli/main.sh build --resume --device dm1q ...

Examples:
  $0 --partition system
  $0 --list

EOF
  exit 1
}

check_tools() {
  if ! command -v mkfs.erofs &>/dev/null; then
    echo "ERROR: mkfs.erofs not found"
    echo "Run: ./tools/setup.sh --tool mkfs.erofs"
    exit 1
  fi
}

partition_ready_for_repack() {
  local partition="$1"
  
  if [[ ! -d "$REPACK_DIR/$partition" ]]; then
    return 1
  fi
  
  if [[ -z "$(ls -A "$REPACK_DIR/$partition" 2>/dev/null)" ]]; then
    return 1
  fi
  
  return 0
}

repack_partition() {
  local partition="$1"
  local backup="${2:-false}"
  
  check_tools
  
  local img_file="$PARTITIONS_DIR/${partition}.img"
  local edit_dir="$REPACK_DIR/$partition"
  
  if [[ ! -f "$img_file" ]]; then
    echo "ERROR: Original partition image not found: $img_file"
    return 1
  fi
  
  if ! partition_ready_for_repack "$partition"; then
    echo "ERROR: No edited files found for partition: $partition"
    echo "Expected directory: $edit_dir"
    return 1
  fi
  
  if [[ "$backup" == "true" ]]; then
    local backup_file="${img_file}.backup"
    cp "$img_file" "$backup_file"
    echo "Backup created: $backup_file"
  fi
  
  local original_size
  original_size=$(stat -c%s "$img_file")
  
  echo ""
  echo "Repacking EROFS partition: $partition"
  echo "  Original size: $original_size bytes"
  echo "  Source: $edit_dir"
  echo ""
  
  local output_img="${img_file}.new"
  
  echo "Creating EROFS image with LZ4 compression..."
  
  if ! mkfs.erofs -zlz4hc "$output_img" "$edit_dir"; then
    echo "ERROR: Failed to create EROFS image"
    return 1
  fi
  
  local new_size
  new_size=$(stat -c%s "$output_img")
  
  echo "Created: $output_img"
  echo "  New size: $new_size bytes"
  echo "  Size change: $((new_size - original_size)) bytes"
  echo ""
  
  echo "To use the new image, run:"
  echo "  mv $output_img $img_file"
  echo ""
  echo "Then rebuild super.img with:"
  echo "  ./cli/main.sh build --resume --device dm1q --input /path/to/firmware --output odin"
  
  return 0
}

list_ready_partitions() {
  echo "Partitions ready for repacking:"
  echo ""
  
  if [[ ! -d "$REPACK_DIR" ]]; then
    echo "No edit directory found: $REPACK_DIR"
    echo "Create it with: mkdir -p $REPACK_DIR"
    return 0
  fi
  
  local found=false
  for partition_dir in "$REPACK_DIR"/*; do
    if [[ -d "$partition_dir" ]]; then
      local partition
      partition=$(basename "$partition_dir")
      local original_img="$PARTITIONS_DIR/${partition}.img"
      
      local status="NO SOURCE"
      if [[ -f "$original_img" ]]; then
        status="READY"
      fi
      
      local file_count
      file_count=$(find "$partition_dir" -type f 2>/dev/null | wc -l)
      local dir_count
      dir_count=$(find "$partition_dir" -type d 2>/dev/null | wc -l)
      local total_size
      total_size=$(du -sh "$partition_dir" 2>/dev/null | cut -f1)
      
      if [[ "$file_count" -gt 0 ]]; then
        found=true
        printf "  %-15s %-10s %5d files, %4d dirs, %s\n" \
          "$partition" "[$status]" "$file_count" "$dir_count" "$total_size"
      fi
    fi
  done
  
  if [[ "$found" == "false" ]]; then
    echo "No partitions with edited files found."
    echo ""
    echo "To edit a partition:"
    echo "  1. Mount: sudo ./tools/mount_manual.sh --mount <partition>"
    echo "  2. Copy: cp -a /tmp/rom_builder_mount/<partition>/* $REPACK_DIR/<partition>/"
    echo "  3. Edit files in $REPACK_DIR/<partition>/"
  fi
}

setup_edit_dir() {
  mkdir -p "$REPACK_DIR"
  echo "Created edit directory: $REPACK_DIR"
  echo ""
  echo "Workflow for manual editing:"
  echo "  1. sudo ./tools/mount_manual.sh --mount <partition>"
  echo "  2. Copy: cp -a /tmp/rom_builder_mount/<partition>/* $REPACK_DIR/<partition>/"
  echo "  3. Edit: $REPACK_DIR/<partition>/"
  echo "  4. Repack: $0 --partition <partition>"
}

case "${1:-}" in
  --partition)
    if [[ -z "${2:-}" ]]; then
      usage
    fi
    repack_partition "$2" "${3:-false}"
    ;;
  --backup)
    if [[ -z "${2:-}" ]]; then
      usage
    fi
    repack_partition "$2" "true"
    ;;
  --list)
    list_ready_partitions
    ;;
  --setup)
    setup_edit_dir
    ;;
  --help)
    usage
    ;;
  *)
    usage
    ;;
esac
