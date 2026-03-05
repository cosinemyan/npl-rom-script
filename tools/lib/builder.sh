#!/bin/bash
# Builder - Build tools from source

set -euo pipefail

# Simple compile for single C files
simple_compile() {
  local source_dir="$1"
  local tool_name="$2"
  local output_dir="$3"
  
  log_info "Compiling $tool_name..."
  
  local source_file="$source_dir/$tool_name.c"
  
  if [[ ! -f "$source_file" ]]; then
    source_file=$(find "$source_dir" -name "*.c" | head -n 1)
  fi
  
  if [[ -z "$source_file" ]]; then
    log_error "No source file found for $tool_name"
    return 1
  fi
  
  local output_file="$output_dir/$tool_name"
  
  gcc -o "$output_file" "$source_file" -I/usr/include 2>/dev/null || \
  clang -o "$output_file" "$source_file" 2>/dev/null || \
  cc -o "$output_file" "$source_file" 2>/dev/null
  
  if [[ ! -f "$output_file" ]]; then
    log_error "Failed to compile $tool_name"
    return 1
  fi
  
  chmod +x "$output_file"
  log_info "Compiled: $output_file"
}

# Build with make
make_build() {
  local source_dir="$1"
  local tool_name="$2"
  local output_dir="$3"
  
  log_info "Building $tool_name with make..."
  
  local original_dir
  original_dir=$(pwd)
  
  cd "$source_dir"
  
  if make clean &>/dev/null; then
    log_debug "Cleaned previous build"
  fi
  
  if ! make; then
    log_error "Make failed for $tool_name"
    cd "$original_dir"
    return 1
  fi
  
  cd "$original_dir"
  
  local built_binary
  built_binary=$(find "$source_dir" -type f -name "$tool_name" -executable | head -n 1)
  
  if [[ -z "$built_binary" ]]; then
    log_error "Could not find built binary: $tool_name"
    return 1
  fi
  
  cp "$built_binary" "$output_dir/$tool_name"
  chmod +x "$output_dir/$tool_name"
  
  log_info "Built: $output_dir/$tool_name"
}

# Build Python tool as wrapper
python_wrapper() {
  local source_dir="$1"
  local tool_name="$2"
  local output_dir="$3"
  local entry_point="${4:-$tool_name.py}"
  
  log_info "Creating Python wrapper for $tool_name..."
  
  local source_file="$source_dir/$entry_point"
  
  if [[ ! -f "$source_file" ]]; then
    source_file=$(find "$source_dir" -name "$tool_name.py" -o -name "$tool_name" | head -n 1)
  fi
  
  if [[ -z "$source_file" ]]; then
    log_error "Could not find Python script: $entry_point"
    return 1
  fi
  
  local output_file="$output_dir/$tool_name"
  
  cat > "$output_file" << EOF
#!/usr/bin/env python3
import sys
import os

script_dir = os.path.dirname(os.path.abspath(__file__))
source_file = os.path.join("$source_dir", "$(basename "$source_file")")

if not os.path.exists(source_file):
    print(f"Error: Source file not found: {source_file}", file=sys.stderr)
    sys.exit(1)

exec(open(source_file).read())
EOF
  
  chmod +x "$output_file"
  log_info "Created wrapper: $output_file"
}

# Extract archive
extract_archive() {
  local archive_file="$1"
  local extract_dir="$2"
  
  log_info "Extracting: $(basename "$archive_file")"
  
  case "$archive_file" in
    *.tar.gz|*.tgz)
      tar -xzf "$archive_file" -C "$extract_dir"
      ;;
    *.tar.bz2|*.tbz2)
      tar -xjf "$archive_file" -C "$extract_dir"
      ;;
    *.tar.xz|*.txz)
      tar -xJf "$archive_file" -C "$extract_dir"
      ;;
    *.tar)
      tar -xf "$archive_file" -C "$extract_dir"
      ;;
    *.zip)
      unzip -q "$archive_file" -d "$extract_dir"
      ;;
    *)
      log_error "Unknown archive format: $archive_file"
      return 1
      ;;
  esac
}

# Copy binary to bin directory
install_binary() {
  local source_path="$1"
  local output_dir="$2"
  local tool_name="$3"
  
  log_info "Installing binary: $tool_name"
  
  cp "$source_path" "$output_dir/$tool_name"
  chmod +x "$output_dir/$tool_name"
  
  log_info "Installed: $output_dir/$tool_name"
}

# Build with CMake (UN1CA's approach)
build_cmake_tool() {
  local tool_name="$1"
  local source_dir="$2"
  local subpath="$3"
  local output_dir="$4"
  
  local tool_dir="$source_dir/$subpath"
  
  if [[ ! -d "$tool_dir" ]]; then
    log_error "Tool directory not found: $tool_dir"
    return 1
  fi
  
  log_info "Building $tool_name with CMake (UN1CA approach)..."
  log_info "Tool directory: $tool_dir"
  
  # Check for CMakeLists.txt or CMakeLists.in
  local cmake_file=""
  if [[ -f "$tool_dir/CMakeLists.txt" ]]; then
    cmake_file="CMakeLists.txt"
  elif [[ -f "$tool_dir/CMakeLists.txt.in" ]]; then
    cmake_file="CMakeLists.txt.in"
  elif [[ -f "$tool_dir/CMakeLists.txt" ]]; then
    cmake_file="CMakeLists.txt"
  fi
  
  if [[ -z "$cmake_file" ]]; then
    log_error "No CMakeLists.txt found in: $tool_dir"
    return 1
  fi
  
  log_debug "Found CMake file: $cmake_file"
  
  # Check for CMake
  if ! command -v cmake &> /dev/null; then
    log_error "cmake not found. Please install: apt install cmake"
    return 1
  fi
  
  # Create build directory
  local build_dir="$source_dir/build"
  rm -rf "$build_dir" 2>/dev/null
  mkdir -p "$build_dir"
  
  # Run CMake configuration
  log_info "Running CMake configuration..."
  cd "$build_dir"

  local cmake_args=(..)
  # nmeum/android-tools expects bundled fmt when system fmtConfig.cmake is absent.
  if [[ -f "$source_dir/CMakeLists.txt" ]] && grep -q "ANDROID_TOOLS_USE_BUNDLED_FMT" "$source_dir/CMakeLists.txt"; then
    cmake_args=(
      -DANDROID_TOOLS_USE_BUNDLED_FMT=ON
      -DANDROID_TOOLS_USE_BUNDLED_LIBUSB=ON
      -DANDROID_TOOLS_LIBUSB_ENABLE_UDEV=OFF
      ..
    )
  fi

  if ! cmake "${cmake_args[@]}"; then
    log_error "CMake configuration failed for $tool_name"
    cd "$source_dir"
    return 1
  fi
  
  # Build
  log_info "Building $tool_name with make..."
  # Build only the requested target to avoid unrelated target failures.
  if ! make -j"$(nproc)" "$tool_name"; then
    log_error "Build failed for $tool_name"
    cd "$source_dir"
    return 1
  fi
  
  cd "$source_dir"
  
  # Find the built binary
  local built_binary
  built_binary=$(find "$build_dir" -type f -name "$tool_name" -executable 2>/dev/null | head -n 1)
  
  if [[ -z "$built_binary" ]]; then
    # Also check in root directory
    built_binary=$(find "$source_dir" -maxdepth 2 -type f -name "$tool_name" -executable 2>/dev/null | grep -v "$build_dir" | head -n 1)
  fi
  
  if [[ -z "$built_binary" ]]; then
    log_error "Could not find built binary: $tool_name"
    return 1
  fi
  
  cp "$built_binary" "$output_dir/$tool_name"
  chmod +x "$output_dir/$tool_name"
  
  log_info "Built successfully: $output_dir/$tool_name"
  return 0
}

# Build with autotools (configure + make)
autotools_build() {
  local source_dir="$1"
  local tool_name="$2"
  local output_dir="$3"
  
  log_info "Building $tool_name with autotools..."
  
  local original_dir
  original_dir=$(pwd)
  
  cd "$source_dir"
  
  if [[ -x "autogen.sh" ]]; then
    log_info "Running autogen.sh..."
    ./autogen.sh || {
      log_error "autogen.sh failed for $tool_name"
      cd "$original_dir"
      return 1
    }
  fi
  
  if [[ ! -f "configure" ]]; then
    log_error "No configure script found in: $source_dir"
    cd "$original_dir"
    return 1
  fi
  
  log_info "Running configure..."
  if ! ./configure --prefix="$source_dir/install" --enable-shared=no; then
    log_error "Configure failed for $tool_name"
    cd "$original_dir"
    return 1
  fi
  
  log_info "Building with make..."
  if ! make -j"$(nproc)"; then
    log_error "Make failed for $tool_name"
    cd "$original_dir"
    return 1
  fi
  
  cd "$original_dir"
  
  local built_binary
  built_binary=$(find "$source_dir" -type f -name "$tool_name" -executable | head -n 1)
  
  if [[ -z "$built_binary" ]]; then
    log_error "Could not find built binary: $tool_name"
    return 1
  fi
  
  cp "$built_binary" "$output_dir/$tool_name"
  chmod +x "$output_dir/$tool_name"
  
  log_info "Built successfully: $output_dir/$tool_name"
}

# Install system tool
install_system_tool() {
  local tool_name="$1"
  local executable_name="$2"
  
  if command_exists "$executable_name"; then
    local system_path
    system_path=$(command -v "$executable_name")
    
    log_info "Using system tool: $system_path"
    ln -sf "$system_path" "$BIN_DIR/$executable_name"
  else
    log_error "System tool not found: $executable_name"
    log_error "Please install: sudo apt install $executable_name"
    return 1
  fi
}
