#!/bin/bash
# Firmware Verification - Validate firmware integrity

verify_firmware_structure() {
  local firmware_dir="$1"
  
  log_info "Verifying firmware structure..."
  
  local has_super="false"
  if find "$firmware_dir" -type f \( -name "super.img" -o -name "super.img.lz4" \) | grep -q .; then
    has_super="true"
  fi

  if [[ "$has_super" != "true" ]]; then
    log_error "Missing required files:"
    printf "  - %s\n" "super.img or super.img.lz4" >&2
    return 1
  fi
  
  log_info "Firmware structure verified"
  return 0
}

get_firmware_info() {
  local firmware_dir="$1"
  local info_file="$firmware_dir/../firmware_info.txt"
  
  cat > "$info_file" << EOF
Firmware Information
===================
Path: $firmware_dir
Date: $(date)
EOF
  
  if [[ -d "$firmware_dir/META-INF" ]]; then
    echo "Build info found in META-INF" >> "$info_file"
  fi
  
  log_info "Firmware info saved to: $info_file"
}
