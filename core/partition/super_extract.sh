#!/bin/bash
# Super Image Extractor - Extract and parse dynamic partition super.img

SUPER_DIR=""

init_super_extract() {
  SUPER_DIR="$WORK_DIR/super"
  mkdir -p "$SUPER_DIR"
}

is_sparse_image() {
  local image="$1"
  if command -v file &>/dev/null; then
    file "$image" | grep -qi "Android sparse image"
  else
    return 1
  fi
}

extract_super_partitions() {
  local super_img="$1"
  
  log_info "Extracting super.img partitions..."
  
  if [[ "$super_img" == *.lz4 ]]; then
    super_img=$(extract_lz4_image "$super_img")
  fi
  
  if ! command -v lpunpack &> /dev/null; then
    log_error "lpunpack not available. Cannot extract dynamic partitions from super.img."
    return 1
  fi

  if is_sparse_image "$super_img"; then
    log_info "Detected sparse super image. Converting to raw image for lpunpack..."
    if ! command -v simg2img &>/dev/null; then
      log_error "simg2img not found. Install tools via ./tools/setup.sh"
      return 1
    fi
    local unsparsed="$SUPER_DIR/super-unsparsed.img"
    simg2img "$super_img" "$unsparsed" || return 1
    super_img="$unsparsed"
  fi
  
  local output_dir="$SUPER_DIR/partitions"
  mkdir -p "$output_dir"
  
  log_verbose "Extracting to: $output_dir"
  
  rm -f "$output_dir"/*.img

  if ! lpunpack "$super_img" "$output_dir" >/dev/null; then
    log_error "lpunpack failed to extract super.img"
    return 1
  fi

  if ! find "$output_dir" -maxdepth 1 -type f -name "*.img" | grep -q .; then
    log_error "No partition images were extracted from super.img"
    return 1
  fi
  
  log_info "Partitions extracted"
  echo "$output_dir"
}

convert_simg_to_img() {
  local simg_file="$1"
  local img_file="${simg_file%.img}-raw.img"
  
  log_verbose "Checking if sparse image: $simg_file"
  
  if ! command -v simg2img &> /dev/null; then
    log_error "simg2img not found. Please add to tools/"
    return 1
  fi
  
  simg2img "$simg_file" "$img_file" || return 1
  
  log_verbose "Converted: $img_file"
  echo "$img_file"
}

get_partition_list() {
  local partitions_dir="$1"
  
  find "$partitions_dir" -type f -name "*.img" | sort
}

resize_partition_image() {
  local image="$1"
  local new_size_mb="$2"
  
  log_info "Resizing $image to ${new_size_mb}MB"
  
  e2fsck -f -y "$image" || true
  resize2fs "$image" "${new_size_mb}M" || return 1
  
  log_info "Resize completed"
}
