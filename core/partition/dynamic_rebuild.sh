#!/bin/bash
# Dynamic Partition Rebuild - Rebuild super.img with modified partitions

_dynamic_rebuild_parse_int() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  echo "$value"
}

_dynamic_rebuild_get_config_value() {
  local config_file="$1"
  local key="$2"

  [[ -n "$config_file" ]] || return 1
  [[ -f "$config_file" ]] || return 1

  parse_yaml_value "$config_file" "$key"
}

_dynamic_rebuild_original_super_size() {
  local original_super_img="$1"
  [[ -n "$original_super_img" ]] || return 1
  [[ -f "$original_super_img" ]] || return 1

  local size=0

  if is_sparse_image "$original_super_img"; then
    if ! command -v simg2img &>/dev/null; then
      log_warn "simg2img not available; cannot derive logical size from sparse super image"
      return 1
    fi

    local raw_super="$WORK_DIR/output/original-super-geometry.img"
    rm -f "$raw_super"
    simg2img "$original_super_img" "$raw_super" >/dev/null || return 1
    size=$(stat -c%s "$raw_super" 2>/dev/null || echo 0)
    rm -f "$raw_super"
  else
    size=$(stat -c%s "$original_super_img" 2>/dev/null || echo 0)
  fi

  [[ "$size" -gt 0 ]] || return 1
  echo "$size"
}

_dynamic_rebuild_group_name() {
  local config_file="$1"
  local group_name=""

  group_name=$(_dynamic_rebuild_get_config_value "$config_file" "super_group_name" || true)
  if [[ -n "$group_name" ]]; then
    echo "$group_name"
    return 0
  fi

  local fstab soc
  fstab=$(_dynamic_rebuild_get_config_value "$config_file" "fstab" || true)
  soc=$(_dynamic_rebuild_get_config_value "$config_file" "soc" || true)
  if [[ "$fstab" == *qcom* ]] || [[ "$soc" == sm* ]] || [[ "$soc" == sdm* ]] || [[ "$soc" == msm* ]]; then
    echo "qti_dynamic_partitions"
  else
    echo "main"
  fi
}

_dynamic_rebuild_device_size() {
  local config_file="$1"
  local original_super_img="$2"
  local total_partition_bytes="$3"

  local original_size
  original_size=$(_dynamic_rebuild_original_super_size "$original_super_img" || true)
  local config_size
  config_size=$(_dynamic_rebuild_get_config_value "$config_file" "super_partition_size" || true)

  local parsed_original=""
  local parsed_config=""
  parsed_original=$(_dynamic_rebuild_parse_int "$original_size" 2>/dev/null || true)
  parsed_config=$(_dynamic_rebuild_parse_int "$config_size" 2>/dev/null || true)

  if [[ -n "$parsed_original" ]] && [[ -n "$parsed_config" ]]; then
    if [[ "$parsed_config" -ne "$parsed_original" ]]; then
      if [[ "$parsed_config" -gt "$parsed_original" ]]; then
        log_warn "Configured super partition size ($parsed_config) differs from sparse source geometry ($parsed_original); using configured size"
      else
        log_warn "Configured super partition size ($parsed_config) differs from source firmware ($parsed_original); using larger source geometry"
      fi
    fi

    if [[ "$parsed_config" -ge "$parsed_original" ]]; then
      echo "$parsed_config"
    else
      echo "$parsed_original"
    fi
    return 0
  fi

  if [[ -n "$parsed_original" ]]; then
    echo "$parsed_original"
    return 0
  fi

  if [[ -n "$parsed_config" ]]; then
    echo "$parsed_config"
    return 0
  fi

  local fallback_size=$((total_partition_bytes + 64 * 1024 * 1024))
  log_warn "Falling back to guessed super partition size: $fallback_size"
  echo "$fallback_size"
}

_dynamic_rebuild_group_size() {
  local config_file="$1"
  local device_size_bytes="$2"
  local total_partition_bytes="$3"

  local config_size
  config_size=$(_dynamic_rebuild_get_config_value "$config_file" "super_group_size" || true)
  if config_size=$(_dynamic_rebuild_parse_int "$config_size" 2>/dev/null); then
    echo "$config_size"
    return 0
  fi

  local reserved_bytes=$((4 * 1024 * 1024))
  local derived_size="$total_partition_bytes"
  if [[ "$device_size_bytes" -gt "$reserved_bytes" ]]; then
    derived_size=$((device_size_bytes - reserved_bytes))
  fi
  if [[ "$derived_size" -lt "$total_partition_bytes" ]]; then
    derived_size="$total_partition_bytes"
  fi

  echo "$derived_size"
}

_dynamic_rebuild_metadata_slots() {
  local config_file="$1"
  local slots
  slots=$(_dynamic_rebuild_get_config_value "$config_file" "super_metadata_slots" || true)
  if slots=$(_dynamic_rebuild_parse_int "$slots" 2>/dev/null); then
    echo "$slots"
    return 0
  fi

  echo "2"
}

rebuild_super_img() {
  local partitions_dir="$1"
  local output_super="$2"
  local config_file="$3"
  local original_super_img="${4:-}"
  
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
 
  local device_size_bytes
  device_size_bytes=$(_dynamic_rebuild_device_size "$config_file" "$original_super_img" "$total_partition_bytes") || return 1

  local group_name
  group_name=$(_dynamic_rebuild_group_name "$config_file") || return 1

  local group_size_bytes
  group_size_bytes=$(_dynamic_rebuild_group_size "$config_file" "$device_size_bytes" "$total_partition_bytes") || return 1

  local metadata_slots
  metadata_slots=$(_dynamic_rebuild_metadata_slots "$config_file") || return 1

  if [[ "$device_size_bytes" -lt "$total_partition_bytes" ]]; then
    log_error "Configured super partition size ($device_size_bytes) is smaller than partition payloads ($total_partition_bytes)"
    return 1
  fi

  if [[ "$group_size_bytes" -lt "$total_partition_bytes" ]]; then
    log_error "Configured super group size ($group_size_bytes) is smaller than partition payloads ($total_partition_bytes)"
    return 1
  fi

  if [[ "$group_size_bytes" -gt "$device_size_bytes" ]]; then
    log_error "Configured super group size ($group_size_bytes) exceeds super partition size ($device_size_bytes)"
    return 1
  fi

  log_info "Using super geometry: device_size=$device_size_bytes group=$group_name group_size=$group_size_bytes metadata_slots=$metadata_slots"
  
  local lpmake_args=(
    --sparse
    --metadata-size 65536
    --super-name super
    --metadata-slots "$metadata_slots"
    --device-size "$device_size_bytes"
    --group "${group_name}:${group_size_bytes}"
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
