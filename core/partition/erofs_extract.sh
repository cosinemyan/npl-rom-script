#!/bin/bash
# EROFS Extract - Extract EROFS images to writable directories

extract_erofs_to_dir() {
  local image_file="$1"
  local output_dir="$2"
  local partition_name="$3"

  log_info "Extracting EROFS partition: $partition_name"

  local temp_mount
  temp_mount=$(mktemp -d "/tmp/erofs_mount_${partition_name}_XXXXXX")

  # Mount read-only using kernel or mount.erofs
  local mount_erofs_bin
  mount_erofs_bin="$(command -v mount.erofs 2>/dev/null || true)"
  if ! sudo mount -t erofs -o loop,ro "$image_file" "$temp_mount" 2>/dev/null; then
    if [[ -n "$mount_erofs_bin" ]]; then
      sudo "$mount_erofs_bin" "$image_file" "$temp_mount" || { log_error "Failed to mount EROFS for $partition_name"; return 1; }
    else
      log_error "Kernel support for EROFS missing and mount.erofs not found."
      return 1
    fi
  fi

  mkdir -p "$output_dir"
  run_with_progress "Syncing EROFS contents to writable directory ($partition_name)" sudo rsync -aHAX --info=none "$temp_mount/" "$output_dir/"

  sudo umount "$temp_mount"
  rmdir "$temp_mount"

  # Change ownership to current user for patching
  sudo chown -R "$(id -u):$(id -g)" "$output_dir"

  log_info "EROFS extracted to: $output_dir"
}

repack_erofs_from_dir() {
  local source_dir="$1"
  local output_image="$2"
  local partition_name="$3"

  log_info "Repacking EROFS partition: $partition_name"

  local mkfs_erofs_bin
  mkfs_erofs_bin="$(command -v mkfs.erofs 2>/dev/null || true)"

  if [[ -z "$mkfs_erofs_bin" ]]; then
    log_error "mkfs.erofs not found in PATH"
    return 1
  fi

  # mkfs.erofs usually needs sudo for proper permission preservation if files are owned by root
  # But since we chowned them for patching, we might need to handle perms via fs-config or just run as sudo.
  # CRB uses level 9 lz4hc
  # mkfs.erofs -zlz4hc,level=9 output_image source_dir
  run_with_progress "Building EROFS image ($partition_name)" sudo "$mkfs_erofs_bin" -zlz4hc,level=9 "$output_image" "$source_dir"
}
