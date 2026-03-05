#!/bin/bash
# Utils - Common utility functions

set -euo pipefail

# Logging functions
log_info() {
  echo "[INFO] ${*:-}" >&2
}

log_error() {
  echo "[ERROR] ${*:-}" >&2
}

log_warn() {
  echo "[WARN] ${*:-}" >&2
}

log_debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    echo "[DEBUG] ${*:-}" >&2
  fi
}

log_success() {
  echo "[SUCCESS] ${*:-}" >&2
}

# Check if command exists
command_exists() {
  command -v "$1" &> /dev/null
}

detect_package_manager() {
  if command_exists apt-get; then
    echo "apt"
  elif command_exists dnf; then
    echo "dnf"
  elif command_exists pacman; then
    echo "pacman"
  else
    echo ""
  fi
}

run_privileged() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    log_error "Need root or sudo to install missing system dependencies."
    return 1
  fi
}

install_system_packages() {
  local manager="$1"
  shift
  local pkgs=("$@")

  if [[ ${#pkgs[@]} -eq 0 ]]; then
    return 0
  fi

  case "$manager" in
    apt)
      run_privileged apt-get update
      run_privileged apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      run_privileged dnf install -y "${pkgs[@]}"
      ;;
    pacman)
      run_privileged pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    *)
      log_error "No supported package manager found for auto-install."
      return 1
      ;;
  esac
}

ensure_build_dependencies() {
  local auto_install="${1:-true}"
  local manager
  manager=$(detect_package_manager)

  local missing_cmds=()
  local required_cmds=("git" "gcc" "make" "python3" "cmake" "pkg-config" "7z" "lz4")
  local cmd
  for cmd in "${required_cmds[@]}"; do
    if ! command_exists "$cmd"; then
      missing_cmds+=("$cmd")
    fi
  done

  local need_brotli="false"
  if command_exists pkg-config && ! pkg-config --exists libbrotlicommon; then
    need_brotli="true"
  fi
  local need_protobuf="false"
  if ! command_exists protoc; then
    need_protobuf="true"
  fi
  local need_gtest="false"
  if [[ ! -f "/usr/include/gtest/gtest_prod.h" ]]; then
    need_gtest="true"
  fi

  if [[ ${#missing_cmds[@]} -eq 0 ]] && [[ "$need_brotli" == "false" ]] && [[ "$need_protobuf" == "false" ]] && [[ "$need_gtest" == "false" ]]; then
    return 0
  fi

  if [[ "$auto_install" != "true" ]]; then
    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
      log_error "Missing required dependencies: ${missing_cmds[*]}"
    fi
    if [[ "$need_brotli" == "true" ]]; then
      log_error "Missing required pkg-config library: libbrotlicommon"
    fi
    if [[ "$need_protobuf" == "true" ]]; then
      log_error "Missing required dependency: protoc / Protobuf development files"
    fi
    if [[ "$need_gtest" == "true" ]]; then
      log_error "Missing required dependency: GoogleTest headers (gtest/gtest_prod.h)"
    fi
    return 1
  fi

  if [[ -z "$manager" ]]; then
    log_error "Cannot auto-install dependencies: unsupported package manager."
    return 1
  fi

  local pkgs=()
  case "$manager" in
    apt)
      pkgs=(git gcc g++ make python3 cmake pkg-config lz4 libbrotli-dev libfmt-dev libusb-1.0-0-dev protobuf-compiler libprotobuf-dev libgtest-dev p7zip-full)
      ;;
    dnf)
      pkgs=(git gcc gcc-c++ make python3 cmake pkgconf-pkg-config lz4 brotli-devel fmt-devel libusb1-devel protobuf protobuf-devel gtest-devel p7zip p7zip-plugins)
      ;;
    pacman)
      pkgs=(git gcc make python cmake pkgconf lz4 brotli fmt libusb protobuf gtest p7zip)
      ;;
  esac

  log_info "Auto-installing missing system dependencies via $manager..."
  install_system_packages "$manager" "${pkgs[@]}" || return 1
}

# Check required dependencies
check_dependencies() {
  local auto_install="${1:-true}"
  ensure_build_dependencies "$auto_install" || return 1

  local missing_deps=()
  local deps=("git" "gcc" "make" "python3" "cmake" "pkg-config" "7z" "lz4")

  local dep
  for dep in "${deps[@]}"; do
    if ! command_exists "$dep"; then
      missing_deps+=("$dep")
    fi
  done

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    log_error "Missing required dependencies: ${missing_deps[*]}"
    return 1
  fi

  if ! pkg-config --exists libbrotlicommon; then
    log_error "Missing required pkg-config library: libbrotlicommon"
    return 1
  fi

  if ! command_exists protoc; then
    log_error "Missing required dependency: protoc / Protobuf development files"
    return 1
  fi

  if [[ ! -f "/usr/include/gtest/gtest_prod.h" ]]; then
    log_error "Missing required dependency: GoogleTest headers (gtest/gtest_prod.h)"
    return 1
  fi

  log_info "All dependencies satisfied"
  return 0
}

# Validate manifest.yaml
validate_manifest() {
  local manifest_file="$1"
  
  if [[ ! -f "$manifest_file" ]]; then
    log_error "Manifest file not found: $manifest_file"
    return 1
  fi
  
  if ! command_exists python3; then
    log_error "python3 required for YAML parsing"
    return 1
  fi
  
  log_info "Manifest validated: $manifest_file"
}

# Parse tool info from manifest
parse_tool_info() {
  local manifest_file="$1"
  local tool_name="$2"
  local field="$3"
  
  python3 -c "
import yaml
import sys

try:
    with open('$manifest_file', 'r') as f:
        manifest = yaml.safe_load(f)
    
    if '$tool_name' in manifest.get('tools', {}):
        tool_info = manifest['tools']['$tool_name']
        if '$field' in tool_info:
            print(tool_info['$field'])
        else:
            sys.exit(1)
    else:
        sys.exit(1)
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || return 1
}

# Get list of all tools from manifest
get_tool_list() {
  local manifest_file="$1"
  
  python3 -c "
import yaml

try:
    with open('$manifest_file', 'r') as f:
        manifest = yaml.safe_load(f)
    
    if 'tools' in manifest:
        for tool in manifest['tools'].keys():
            print(tool)
except Exception:
    pass
"
}

# Check if tool is already installed
tool_installed() {
  local bin_dir="$1"
  local tool_name="$2"
  
  [[ -x "$bin_dir/$tool_name" ]]
}

# Get file hash
get_file_hash() {
  local file="$1"
  
  if [[ -f "$file" ]]; then
    sha256sum "$file" | awk '{print $1}'
  fi
}

# Create directory if not exists
ensure_dir() {
  local dir="$1"
  
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
  fi
}

# Verify architecture
verify_architecture() {
  local arch
  arch=$(uname -m)
  
  if [[ "$arch" != "x86_64" ]]; then
    log_warn "Non-x86_64 architecture detected: $arch"
    log_warn "Some pre-built binaries may not work"
  else
    log_debug "Architecture: $arch"
  fi
}

# Show progress
show_progress() {
  local current="$1"
  local total="$2"
  local message="$3"
  
  local percent=$((current * 100 / total))
  printf "\r[%3d%%] %s" "$percent" "$message"
  
  if [[ $current -eq $total ]]; then
    echo
  fi
}
