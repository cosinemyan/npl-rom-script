#!/bin/bash
# VBMETA Patching - Handle AVB vbmeta modifications

disable_avb() {
  local vbmeta_img="$1"
  local output="$2"
  
  log_info "Disabling AVB verification in vbmeta"
  
  if ! command -v avbtool &> /dev/null; then
    log_error "avbtool not found. Please add to tools/"
    return 1
  fi
  
  local input_size
  input_size=$(stat -c%s "$vbmeta_img" 2>/dev/null || echo 0)
  if [[ "$input_size" -le 0 ]]; then
    input_size=4096
  fi

  # vbmeta and vbmeta_system are standalone vbmeta images on Samsung firmware;
  # they usually do not have AVB footers, so erase_footer is not applicable.
  avbtool make_vbmeta_image \
    --flags 2 \
    --set_hashtree_disabled_flag \
    --padding_size "$input_size" \
    --output "$output" || return 1
  
  log_info "AVB disabled: $output"
}

patch_vbmeta_for_partitions() {
  local vbmeta_img="$1"
  local partitions_dir="$2"
  local output_vbmeta="$3"
  
  log_info "Patching vbmeta for partitions..."
  
  local avbtool_args=()
  
  for img in "$partitions_dir"/*.img; do
    if [[ -f "$img" ]]; then
      local name
      name=$(basename "$img" .img)
      
      log_verbose "Adding vbmeta chain for: $name"
      
      avbtool_args+=(
        --chain_partition "$name":"$partitions_dir/avb/$name.avbpubkey":"$img"
      )
    fi
  done
  
  if [[ ${#avbtool_args[@]} -eq 0 ]]; then
    log_info "No partitions to chain, using empty vbmeta"
    avbtool make_vbmeta_image --output "$output_vbmeta"
    return 0
  fi
  
  avbtool make_vbmeta_image "${avbtool_args[@]}" --output "$output_vbmeta" || return 1
  
  log_info "vbmeta patched: $output_vbmeta"
}
