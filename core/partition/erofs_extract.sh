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
  if command -v rsync &>/dev/null; then
    run_with_progress "Syncing EROFS contents to writable directory ($partition_name)" sudo rsync -aHAX --info=none "$temp_mount/" "$output_dir/"
  else
    run_with_progress "Copying EROFS contents to writable directory ($partition_name)" sudo cp -a "$temp_mount/." "$output_dir/"
  fi

  # Generate fs_config and file_context for EROFS repack (UN1CA-style)
  local configs_dir="$WORK_DIR/configs"
  mkdir -p "$configs_dir"
  log_info "Generating fs_config/file_context for $partition_name"

  sudo find "$temp_mount" | sudo xargs -I "{}" -P "$(nproc)" stat -c "%n %u %g %a capabilities=0x0" "{}" \
    > "$configs_dir/fs_config-$partition_name" 2>/dev/null || true
  sudo find "$temp_mount" | sudo xargs -I "{}" -P "$(nproc)" sh -c \
    'echo "$1 $(getfattr -n security.selinux --only-values -h --absolute-names "$1" 2>/dev/null || echo "u:object_r:${2}_file:s0")"' \
    "sh" "{}" "$partition_name" \
    > "$configs_dir/file_context-$partition_name" 2>/dev/null || true

  sort -o "$configs_dir/fs_config-$partition_name" "$configs_dir/fs_config-$partition_name" 2>/dev/null || true
  sort -o "$configs_dir/file_context-$partition_name" "$configs_dir/file_context-$partition_name" 2>/dev/null || true

  # Fix paths: replace temp_mount prefix with proper mount point paths
  if [[ "$partition_name" == "system" ]] && [[ -d "$output_dir/system" ]]; then
    sudo sed -i -e "s|$temp_mount |/ |g" -e "s|$temp_mount||g" "$configs_dir/file_context-$partition_name" 2>/dev/null || true
    sudo sed -i -e "s|$temp_mount | |g" -e "s|$temp_mount/||g" "$configs_dir/fs_config-$partition_name" 2>/dev/null || true
  else
    sudo sed -i "s|$temp_mount|/$partition_name|g" "$configs_dir/file_context-$partition_name" 2>/dev/null || true
    sudo sed -i -e "s|$temp_mount | |g" -e "s|$temp_mount|$partition_name|g" "$configs_dir/fs_config-$partition_name" 2>/dev/null || true
  fi

  # Escape regex special chars in file_context for erofs mkfs
  sudo sed -i -e "s|\.|\\\.|g" -e "s|\+|\\\+|g" -e "s|\[|\\\[|g" \
    -e "s|\]|\\\]|g" -e "s|\*|\\\*|g" "$configs_dir/file_context-$partition_name" 2>/dev/null || true

  sudo chown "$(id -u):$(id -g)" "$configs_dir/fs_config-$partition_name" "$configs_dir/file_context-$partition_name" 2>/dev/null || true

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

  # Build args matching UN1CA's mkfs.erofs parameters for Samsung compatibility
  local erofs_args=(-z "lz4hc,9" -b 4096)

  local mount_point="$partition_name"
  [[ "$partition_name" == "system" ]] && mount_point="/"
  erofs_args+=(--mount-point "$mount_point")

  local configs_dir="$WORK_DIR/configs"
  if [[ -f "$configs_dir/fs_config-$partition_name" ]]; then
    erofs_args+=(--fs-config-file "$configs_dir/fs_config-$partition_name")
  else
    log_warn "No fs_config found for $partition_name, SELinux labels may be missing"
  fi

  if [[ -f "$configs_dir/file_context-$partition_name" ]]; then
    erofs_args+=(--file-contexts "$configs_dir/file_context-$partition_name")
  else
    log_warn "No file_context found for $partition_name, SELinux labels may be missing"
  fi

  # Samsung fixed timestamp for erofs images
  erofs_args+=(-T 1640995200)

  erofs_args+=("$output_image" "$source_dir")

  log_verbose "mkfs.erofs args: ${erofs_args[*]}"
  run_with_progress "Building EROFS image ($partition_name)" sudo "$mkfs_erofs_bin" "${erofs_args[@]}"
}
