#!/bin/bash
# Dynamic Partition Rebuild - Rebuild super.img with modified partitions

rebuild_super_img() {
  local partitions_dir="$1"
  local output_super="$2"
  local config_file="$3"
  
  log_info "Rebuilding super.img..."
  
  if ! command -v lpmake &> /dev/null; then
    log_error "lpmake not found. Please add to tools/"
    return 1
  fi
  
  log_verbose "Building partition list..."
 
  local total_partition_bytes=0
  local partition_count=0
  local img
  for img in "$partitions_dir"/*.img; do
    if [[ -f "$img" ]]; then
      local size
      size=$(stat -c%s "$img")
      if [[ "$size" -gt 0 ]]; then
        total_partition_bytes=$((total_partition_bytes + size))
        partition_count=$((partition_count + 1))
      fi
    fi
  done
 
  if [[ "$partition_count" -eq 0 ]]; then
    log_error "No partition images found to rebuild super.img"
    return 1
  fi
 
  local overhead_bytes=$((64 * 1024 * 1024))
  local device_size_bytes=$((total_partition_bytes + overhead_bytes))
  local group_name="main"
  
  local lpmake_args=(
    --metadata-size 65536
    --super-name super
    --metadata-slots 3
    --device "super:${device_size_bytes}"
    --group "${group_name}:${total_partition_bytes}"
  )
  
  for img in "$partitions_dir"/*.img; do
    if [[ -f "$img" ]]; then
      local name
      name=$(basename "$img" .img)
      local size
      size=$(stat -c%s "$img")
      
      if [[ "$size" -eq 0 ]]; then
        log_verbose "Skipping zero-size partition: $name"
        continue
      fi
      
      log_verbose "Adding partition: $name (${size} bytes)"
      
      lpmake_args+=(
        --partition "$name":readonly:"$size":"$group_name"
        --image "$name"="$img"
      )
    fi
  done
  
  log_verbose "Running lpmake..."
  run_with_progress "Building super.img (lpmake)" lpmake "${lpmake_args[@]}" --output "$output_super" || {
    return 1
  }
  
  if [[ -f "$output_super" ]]; then
    log_info "super.img rebuilt: $output_super"
  else
    log_error "super.img was not created"
    return 1
  fi
}

compress_super_img() {
  local super_img="$1"
  
  run_with_progress "Compressing super.img with LZ4" lz4 -B4 --content-size -f "$super_img" "${super_img}.lz4" || return 1
  
  log_info "Compressed: ${super_img}.lz4"
}
