#!/bin/bash
# Partition Mount - Mount partitions for modification

MOUNT_DIR=""
EROFSPARTITIONS=()

init_mount() {
  MOUNT_DIR="$WORK_DIR/mount"
  mkdir -p "$MOUNT_DIR"
}

mount_partition() {
  local image="$1"
  local mount_point="$2"
  local partition_name="${3:-$(basename "$image" .img)}"
  
  if [[ -z "$mount_point" ]]; then
    mount_point="$MOUNT_DIR/$partition_name"
  fi
  
  if command -v file &>/dev/null; then
    local fs_desc
    fs_desc=$(file -b "$image" 2>/dev/null || true)
    if echo "$fs_desc" | grep -qi "EROFS filesystem"; then
      log_info "EROFS filesystem detected for: $partition_name"

      # Extract EROFS to a writable directory so patches can modify files.
      # extract_erofs_to_dir: RO mount → rsync → chown (defined in erofs_extract.sh)
      if extract_erofs_to_dir "$image" "$mount_point" "$partition_name"; then
        EROFSPARTITIONS+=("$partition_name")
        echo "$mount_point"
        return 0
      fi

      log_warn "Could not extract EROFS partition: $partition_name"
      log_warn "Ensure sudo is available and EROFS kernel module is loaded (sudo modprobe erofs)"
      log_warn "Skipping $partition_name - will use original image without modifications"

      EROFSPARTITIONS+=("$partition_name")
      echo ""
      return 0
    fi
  fi
  
  mkdir -p "$mount_point"
  
  log_info "Mounting $partition_name to $mount_point"
  
  if ! sudo mount -o loop,rw "$image" "$mount_point"; then
    # Some Android ext4 images require noload to allow RW loop mount.
    sudo mount -o loop,rw,noload "$image" "$mount_point" || return 1
  fi
  
  if ! sudo touch "$mount_point/.rw_test" 2>/dev/null; then
    log_error "Mounted read-only: $mount_point"
    sudo umount "$mount_point" || true
    return 1
  fi
  sudo rm -f "$mount_point/.rw_test" || true
  
  log_info "Mounted: $mount_point"
  echo "$mount_point"
}

mount_all_partitions() {
  local partitions_dir="$1"
  local partition_names=("${@:2}")
  
  log_info "Mounting partitions: ${partition_names[*]}"
  
  local mount_points=()
  
  for partition in "${partition_names[@]}"; do
    local image="$partitions_dir/$partition.img"
    
    if [[ ! -f "$image" ]]; then
      log_verbose "Partition not found: $partition"
      continue
    fi
    
    local mount_point
    mount_point=$(mount_partition "$image" "" "$partition")
    mount_points+=("$mount_point")
  done
  
  printf "%s\n" "${mount_points[@]}"
}

umount_partition() {
  local mount_point="$1"
  
  if [[ -z "$mount_point" ]]; then
    log_verbose "Empty mount point (EROFS partition), skipping unmount"
    return 0
  fi
  
  if mountpoint -q "$mount_point" 2>/dev/null; then
    log_info "Unmounting: $mount_point"
    sync
    sudo umount "$mount_point" || log_error "Failed to unmount: $mount_point"
    rmdir "$mount_point" || true
  else
    log_info "Extracted directory detected: $mount_point"
    log_info "No unmount needed, will be repacked"
  fi
}

umount_all_partitions() {
  log_info "Unmounting all partitions..."
  
  for mount_point in "$MOUNT_DIR"/*; do
    if [[ -d "$mount_point" ]]; then
      umount_partition "$mount_point"
    fi
  done
}

get_mount_point() {
  local partition="$1"
  echo "$MOUNT_DIR/$partition"
}
