#!/bin/bash
# Partition Repack - Rebuild partition images after modification

rebuild_partition_image() {
  local mount_point="$1"
  local output_image="$2"
  local size_mb="${3:-}"
  
  log_info "Rebuilding partition from: $mount_point"
  
  sync
  
  local partition_size
  partition_size=$(df -BM --output=size "$mount_point" | tail -1 | tr -d 'M')
  
  if [[ -n "$size_mb" ]] && [[ "$size_mb" -gt "$partition_size" ]]; then
    partition_size="$size_mb"
  fi
  
  log_verbose "Image size: ${partition_size}MB"
  
  if [[ -f "$output_image" ]]; then
    rm -f "$output_image"
  fi
  
  mke2fs -t ext4 -L "$(basename "$mount_point")" "$output_image" "${partition_size}M" || return 1
  
  local temp_mount
  temp_mount=$(mktemp -d)
  
  sudo mount -o loop "$output_image" "$temp_mount"
  sudo cp -a "$mount_point"/* "$temp_mount/"
  sync
  sudo umount "$temp_mount"
  rmdir "$temp_mount"
  
  log_info "Partition rebuilt: $output_image"
}

rebuild_erofs_partition() {
  local mount_point="$1"
  local output_image="$2"
  
  log_info "Rebuilding EROFS partition from: $mount_point"
  
  sync
  
  if ! command -v mkfs.erofs &>/dev/null; then
    log_error "mkfs.erofs not found. Run: ./tools/setup.sh"
    return 1
  fi
  
  if [[ -f "$output_image" ]]; then
    rm -f "$output_image"
  fi
  
  mkfs.erofs -zlz4hc "$output_image" "$mount_point" || {
    log_error "Failed to create EROFS image"
    return 1
  }
  
  log_info "EROFS partition rebuilt: $output_image"
}

optimize_partition() {
  local image="$1"
  
  log_info "Optimizing partition: $image"
  
  sudo e2fsck -f -y "$image" || true
  sudo resize2fs -M "$image" || log_verbose "Resize optimization skipped"
  
  log_info "Optimization completed"
}