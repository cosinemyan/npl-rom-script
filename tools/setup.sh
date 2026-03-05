#!/bin/bash
# Tools Setup - Bootstrap external tools for ROM Builder

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="$SCRIPT_DIR/lib"
readonly BIN_DIR="$SCRIPT_DIR/bin"
readonly CACHE_DIR="$SCRIPT_DIR/cache"
readonly MANIFEST_FILE="$SCRIPT_DIR/manifest.yaml"

# Source helper libraries
source "$LIB_DIR/utils.sh"
source "$LIB_DIR/downloader.sh"
source "$LIB_DIR/builder.sh"

# Display banner
show_banner() {
  cat << "EOF"
╔════════════════════════════════════════════════════════════════╗
║           ROM Builder - Tools Bootstrap System                ║
╚════════════════════════════════════════════════════════════════╝
EOF
}

# Display usage
usage() {
  cat << EOF
Usage: $0 [OPTIONS]

Options:
  --help              Show this help message
  --clean             Clean cached files and re-download
  --force             Force rebuild of all tools
  --no-auto-deps      Do not auto-install missing system dependencies
  --check-only        Only check if tools are installed
  --tool NAME         Install specific tool only
  --list              List all tools in manifest

Environment Variables:
  DEBUG=1             Enable debug logging
  OMC_DECODER_JAR_URL Optional direct URL for omc-decoder.jar auto-download

Examples:
  $0                  # Install all tools
  $0 --tool lz4       # Install only lz4
  $0 --clean          # Clean and reinstall
  $0 --check-only     # Check installation status
EOF
  exit 0
}

# Check installation status
check_installation() {
  local tools=()
  mapfile -t tools < <(get_tool_list "$MANIFEST_FILE")
  
  log_info "Checking installation status..."
  echo
  
  local installed_count=0
  local total_count=${#tools[@]}
  
  for tool in "${tools[@]}"; do
    if tool_installed "$BIN_DIR" "$tool"; then
      echo "  ✓ $tool"
      installed_count=$((installed_count + 1))
    else
      echo "  ✗ $tool"
    fi
  done
  
  echo
  log_info "Status: $installed_count/$total_count tools installed"
  
  if [[ $installed_count -eq $total_count ]]; then
    return 0
  else
    return 1
  fi
}

# List all tools
list_tools() {
  local tools=()
  mapfile -t tools < <(get_tool_list "$MANIFEST_FILE")
  
  log_info "Tools defined in manifest:"
  echo
  
  for tool in "${tools[@]}"; do
    local tool_type
    tool_type=$(parse_tool_info "$MANIFEST_FILE" "$tool" "type" 2>/dev/null || echo "unknown")
    local tool_version
    tool_version=$(parse_tool_info "$MANIFEST_FILE" "$tool" "version" 2>/dev/null || echo "latest")
    
    printf "  %-15s  %-15s  %s\n" "$tool" "$tool_type" "$tool_version"
  done
}

# Install single tool
install_tool() {
  local tool_name="$1"
  local force="$2"
  
  log_info "=========================================="
  log_info "Installing tool: $tool_name"
  log_info "=========================================="
  
  # Check if already installed
  if [[ "$force" != "true" ]] && tool_installed "$BIN_DIR" "$tool_name"; then
    log_info "Tool already installed, skipping"
    return 0
  fi
  
  # Get tool configuration
  local tool_type
  tool_type=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "type" 2>/dev/null || true)
  local tool_version
  tool_version=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "version" 2>/dev/null || true)
  local executable_name
  executable_name=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "executable" 2>/dev/null || echo "$tool_name")
  
  if [[ -z "$tool_type" ]]; then
    log_error "Tool not found in manifest: $tool_name"
    return 1
  fi
  
  log_debug "Type: $tool_type"
  log_debug "Version: $tool_version"
  log_debug "Executable: $executable_name"
  
  local source_dir="$CACHE_DIR/$tool_name"
  ensure_dir "$source_dir"
  
  case "$tool_type" in
    github_release)
      install_github_release_tool "$tool_name" "$tool_version" "$source_dir" "$executable_name"
      ;;
    git_clone)
      install_git_clone_tool "$tool_name" "$tool_version" "$source_dir" "$executable_name"
      ;;
    prebuilt_binary)
      install_prebuilt_binary_tool "$tool_name" "$tool_version" "$source_dir" "$executable_name"
      ;;
    cmake_build)
      install_cmake_tool "$tool_name" "$tool_version" "$source_dir" "$executable_name"
      ;;
    python_wrapper)
      install_git_clone_tool "$tool_name" "$tool_version" "$source_dir" "$executable_name"
      ;;
    autotools)
      install_autotools_tool "$tool_name" "$tool_version" "$source_dir" "$executable_name"
      ;;
    system)
      install_system_tool "$tool_name" "$executable_name"
      ;;
    aosp_tool)
      install_git_clone_tool "$tool_name" "$tool_version" "$source_dir" "$executable_name"
      ;;
    *)
      log_error "Unknown tool type: $tool_type"
      return 1
      ;;
  esac

  local install_status=$?
  if [[ $install_status -ne 0 ]]; then
    log_error "Installation failed: $tool_name"
    return $install_status
  fi

  log_success "Installed: $tool_name"
}

# Install CMake tool from git repo (for nmeum/android-tools)
install_cmake_tool_from_git() {
  local tool_name="$1"
  local version="$2"
  local source_dir="$3"
  local executable_name="$4"
  
  local repo
  repo=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "repo" 2>/dev/null || true)
  local subpath
  subpath=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "subpath" 2>/dev/null || true)
  
  log_info "Installing CMake tool from git repo: $tool_name"
  log_debug "Repo: $repo"
  log_debug "Subpath: $subpath"
  
  # Clone git repository
  local cloned_dir
  cloned_dir=$(clone_git_repo "$repo" "$version" "$CACHE_DIR")
  
  # Build from cloned directory
  build_cmake_tool "$tool_name" "$cloned_dir" "$subpath" "$BIN_DIR"
}

# Install tool from GitHub release
install_github_release_tool() {
  local tool_name="$1"
  local version="$2"
  local source_dir="$3"
  local executable_name="$4"
  
  local repo
  repo=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "repo" 2>/dev/null || true)
  local asset_pattern
  asset_pattern=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "asset_pattern" 2>/dev/null || true)
  
  local downloaded_file
  downloaded_file=$(download_github_release "$repo" "$version" "$asset_pattern" "$source_dir" "$tool_name")
  
  local extract_dir="$source_dir/extracted"
  ensure_dir "$extract_dir"
  
  extract_archive "$downloaded_file" "$extract_dir"
  
  local binary
  binary=$(find "$extract_dir" -type f -name "$executable_name" -executable | head -n 1)
  
  if [[ -z "$binary" ]]; then
    log_error "Could not find binary: $executable_name"
    return 1
  fi
  
  install_binary "$binary" "$BIN_DIR" "$executable_name"
}

# Install tool from git clone
install_git_clone_tool() {
  local tool_name="$1"
  local version="$2"
  local source_dir="$3"
  local executable_name="$4"
  
  local repo
  repo=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "repo" 2>/dev/null || true)
  local build_type
  build_type=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "build" 2>/dev/null || true)
  local subpath
  subpath=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "subpath" 2>/dev/null || true)
  local entry
  entry=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "entry" 2>/dev/null || true)
  
  local cloned_dir
  cloned_dir=$(clone_git_repo "$repo" "$version" "$CACHE_DIR")
  
  local build_dir="$cloned_dir"
  if [[ -n "$subpath" ]]; then
    build_dir="$cloned_dir/$subpath"
  fi
  
  if [[ ! -d "$build_dir" ]]; then
    log_error "Build directory not found: $build_dir"
    return 1
  fi
  
  case "$build_type" in
    make)
      make_build "$build_dir" "$executable_name" "$BIN_DIR"
      ;;
    simple_compile)
      simple_compile "$build_dir" "$executable_name" "$BIN_DIR"
      ;;
    python_wrapper)
      python_wrapper "$build_dir" "$executable_name" "$BIN_DIR" "$entry"
      ;;
    aosp_focused)
      build_aosp_tool "$tool_name" "$cloned_dir" "$subpath" "$BIN_DIR"
      ;;
    *)
      log_error "Unknown build type: $build_type"
      return 1
      ;;
  esac
}

# Install prebuilt binary tool
install_prebuilt_binary_tool() {
  local tool_name="$1"
  local version="$2"
  local source_dir="$3"
  local executable_name="$4"
  
  local repo
  repo=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "repo" 2>/dev/null || true)
  local subpath
  subpath=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "subpath" 2>/dev/null || true)
  
  local cloned_dir
  cloned_dir=$(clone_git_repo "$repo" "$version" "$CACHE_DIR")
  
  local build_dir="$cloned_dir"
  if [[ -n "$subpath" ]]; then
    build_dir="$cloned_dir/$subpath"
  fi
  
  if [[ ! -f "$build_dir" ]]; then
    log_error "Prebuilt binary not found: $build_dir"
    return 1
  fi

  cp "$build_dir" "$BIN_DIR/$executable_name"
  chmod +x "$BIN_DIR/$executable_name"
  
  log_info "Copied prebuilt binary: $executable_name"
}

# Install CMake-based tool (UN1CA's approach)
install_cmake_tool() {
  local tool_name="$1"
  local version="$2"
  local source_dir="$3"
  local executable_name="$4"
  
  local repo
  repo=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "repo" 2>/dev/null || true)
  local subpath
  subpath=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "subpath" 2>/dev/null || true)
  local release_url
  release_url=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "release_url" 2>/dev/null || true)
  
  log_info "Installing CMake-based tool: $tool_name"
  log_debug "Repo: $repo"
  log_debug "Subpath: $subpath"
  log_debug "Release URL: $release_url"
  
  # Download source tarball if release_url provided
  if [[ -n "$release_url" ]]; then
    local tarball_file
    tarball_file=$(download_source_tarball "$tool_name" "$release_url" "$source_dir")
    
    if [[ -f "$tarball_file" ]]; then
      log_info "Extracting source tarball..."
      local extract_dir="$source_dir/extracted"
      rm -rf "$extract_dir" 2>/dev/null
      mkdir -p "$extract_dir"
      
      # Extract based on archive type
      case "$tarball_file" in
        *.tar.xz)
          tar -xf "$tarball_file" -C "$extract_dir"
          ;;
        *.tar.gz|*.tgz)
          tar -xzf "$tarball_file" -C "$extract_dir"
          ;;
        *.tar)
          tar -xf "$tarball_file" -C "$extract_dir"
          ;;
        *)
          log_error "Unknown archive format: $tarball_file"
          return 1
          ;;
      esac
      
      # Extracted directory becomes the new source_dir
      source_dir="$extract_dir"
    fi
  else
    # Clone from git if no release_url provided
    log_info "No release URL, cloning from git repo..."
    local cloned_dir
    cloned_dir=$(clone_git_repo "$repo" "$version" "$CACHE_DIR")
    source_dir="$cloned_dir"
  fi
  
  # Build with CMake
  build_cmake_tool "$tool_name" "$source_dir" "$subpath" "$BIN_DIR"
}

# Install autotools-based tool
install_autotools_tool() {
  local tool_name="$1"
  local version="$2"
  local source_dir="$3"
  local executable_name="$4"
  
  local repo
  repo=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "repo" 2>/dev/null || true)
  local subpath
  subpath=$(parse_tool_info "$MANIFEST_FILE" "$tool_name" "subpath" 2>/dev/null || true)
  
  log_info "Installing autotools-based tool: $tool_name"
  
  local cloned_dir
  cloned_dir=$(clone_git_repo "$repo" "$version" "$CACHE_DIR")
  
  local build_dir="$cloned_dir"
  if [[ -n "$subpath" ]]; then
    build_dir="$cloned_dir/$subpath"
  fi
  
  if [[ ! -d "$build_dir" ]]; then
    log_error "Build directory not found: $build_dir"
    return 1
  fi
  
  autotools_build "$build_dir" "$executable_name" "$BIN_DIR"
}

# Clean cached files
clean_cache() {
  log_info "Cleaning cached files..."
  
  if [[ -d "$CACHE_DIR" ]]; then
    rm -rf "$CACHE_DIR"/*
    log_info "Cache cleaned"
  fi
  
  if [[ -d "$BIN_DIR" ]]; then
    rm -rf "$BIN_DIR"/*
    log_info "Binaries removed"
  fi
}

# Optional helper: download OMC decoder jar used for HOME_CSC decode flow.
# This is non-fatal and only runs when OMC_DECODER_JAR_URL is provided.
install_optional_omc_decoder() {
  local omc_target="$BIN_DIR/omc-decoder.jar"

  if [[ -f "$omc_target" ]]; then
    log_info "omc-decoder.jar already present: $omc_target"
    return 0
  fi

  local omc_url="${OMC_DECODER_JAR_URL:-}"
  if [[ -z "$omc_url" ]]; then
    log_warn "OMC decoder URL not provided; skipping omc-decoder.jar download"
    log_warn "Set OMC_DECODER_JAR_URL to auto-download during setup"
    return 0
  fi

  local omc_cache="$CACHE_DIR/omc-decoder"
  ensure_dir "$omc_cache"

  log_info "Downloading optional omc-decoder.jar..."
  local downloaded
  downloaded=$(download_direct "$omc_url" "$omc_cache" "omc-decoder.jar") || {
    log_warn "Failed to download omc-decoder.jar from OMC_DECODER_JAR_URL"
    return 0
  }

  cp "$downloaded" "$omc_target" || {
    log_warn "Failed to copy omc-decoder.jar to $omc_target"
    return 0
  }
  chmod 0644 "$omc_target" || true
  log_success "Installed optional tool: omc-decoder.jar"
}

# Main installation process
main() {
  local clean="false"
  local force="false"
  local auto_deps="true"
  local check_only="false"
  local specific_tool=""
  
  while [[ $# -gt 0 ]]; do
    case $1 in
      --help)
        usage
        ;;
      --clean)
        clean="true"
        shift
        ;;
      --force)
        force="true"
        shift
        ;;
      --no-auto-deps)
        auto_deps="false"
        shift
        ;;
      --check-only)
        check_only="true"
        shift
        ;;
      --tool)
        specific_tool="$2"
        shift 2
        ;;
      --list)
        list_tools
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done
  
  show_banner
  
  if [[ "$check_only" == "true" ]]; then
    check_installation
    exit $?
  fi
  
  if [[ "$clean" == "true" ]]; then
    clean_cache
  fi
  
  log_info "Validating manifest..."
  validate_manifest "$MANIFEST_FILE"
  
  log_info "Checking dependencies..."
  check_dependencies "$auto_deps"
  
  log_info "Verifying architecture..."
  verify_architecture
  
  ensure_dir "$BIN_DIR"
  ensure_dir "$CACHE_DIR"
  
  echo
  
  if [[ -n "$specific_tool" ]]; then
    install_tool "$specific_tool" "$force"
    exit $?
  fi
  
  local tools=()
  mapfile -t tools < <(get_tool_list "$MANIFEST_FILE")
  
  local total=${#tools[@]}
  local failed_tools=()
  
  for i in "${!tools[@]}"; do
    local tool="${tools[$i]}"
    
    show_progress "$((i+1))" "$total" "Installing $tool..."
    
    if ! install_tool "$tool" "$force"; then
      failed_tools+=("$tool")
      echo
    fi
  done

  install_optional_omc_decoder
  
  echo
  log_info "=========================================="
  log_info "Installation Complete"
  log_info "=========================================="
  
  if [[ ${#failed_tools[@]} -gt 0 ]]; then
    log_error "Failed tools: ${failed_tools[*]}"
    log_error "Please check errors above"
    exit 1
  fi
  
  log_success "All tools installed successfully!"
  log_info "Tools directory: $BIN_DIR"
  
  echo
  check_installation
}

main "$@"
