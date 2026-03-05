#!/bin/bash
# Firmware Downloader - Optional firmware download utility

DOWNLOAD_DIR=""

init_downloader() {
  DOWNLOAD_DIR="$WORK_DIR/downloads"
  mkdir -p "$DOWNLOAD_DIR"
}

is_remote_input() {
  local input="$1"
  [[ "$input" =~ ^https?:// ]] || [[ "$input" == "auto" ]]
}

build_auto_firmware_url() {
  local template="${FIRMWARE_URL_TEMPLATE:-}"
  local device="$1"
  local region="$2"

  if [[ -z "$template" ]]; then
    log_error "FIRMWARE_URL_TEMPLATE is required when using --input auto"
    log_error "Example: export FIRMWARE_URL_TEMPLATE='https://host/fw/{device}/{region}/firmware.zip'"
    return 1
  fi

  local url="${template//\{device\}/$device}"
  url="${url//\{region\}/$region}"
  echo "$url"
}

prepare_firmware_input() {
  local input="$1"
  local device="$2"
  local region="${3:-}"

  if [[ -f "$input" ]]; then
    echo "$input"
    return 0
  fi

  if ! is_remote_input "$input"; then
    log_error "Input file not found: $input"
    return 1
  fi

  if [[ -z "$region" ]]; then
    log_error "--region is required when downloading firmware"
    return 1
  fi

  init_downloader

  local url="$input"
  if [[ "$input" == "auto" ]]; then
    url=$(build_auto_firmware_url "$device" "$region") || return 1
  fi

  local base_name
  base_name=$(basename "${url%%\?*}")
  if [[ -z "$base_name" ]] || [[ "$base_name" == "/" ]]; then
    base_name="firmware_${device}_${region}.zip"
  fi

  local output_file="$DOWNLOAD_DIR/${device}_${region}_${base_name}"
  download_firmware "$url" "$output_file" || return 1

  local expected_checksum="${FIRMWARE_SHA256:-}"
  verify_checksum "$output_file" "$expected_checksum" || return 1

  echo "$output_file"
}

download_firmware() {
  local url="$1"
  local output="$2"
  
  log_info "Downloading firmware from: $url"
  
  if ! command -v wget &> /dev/null && ! command -v curl &> /dev/null; then
    log_error "Neither wget nor curl found. Please install one."
    return 1
  fi
  
  if command -v wget &> /dev/null; then
    wget -O "$output" "$url" || return 1
  else
    curl -L -o "$output" "$url" || return 1
  fi
  
  log_info "Download completed: $output"
}

verify_checksum() {
  local file="$1"
  local expected_checksum="$2"
  
  if [[ -z "$expected_checksum" ]]; then
    log_verbose "No checksum provided, skipping verification"
    return 0
  fi
  
  log_info "Verifying checksum..."
  
  local actual_checksum
  actual_checksum=$(sha256sum "$file" | awk '{print $1}')
  
  if [[ "$actual_checksum" != "$expected_checksum" ]]; then
    log_error "Checksum mismatch!"
    log_error "Expected: $expected_checksum"
    log_error "Actual:   $actual_checksum"
    return 1
  fi
  
  log_info "Checksum verified"
  return 0
}
