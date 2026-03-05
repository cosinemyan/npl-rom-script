#!/bin/bash
# Downloader - Download tools and resources

set -euo pipefail

# Download from GitHub releases
download_github_release() {
  local repo="$1"
  local version="$2"
  local asset_pattern="$3"
  local output_dir="$4"
  local tool_name="$5"
  
  local api_url="https://api.github.com/repos/$repo/releases/tags/$version"
  
  log_info "Fetching release info from GitHub..."
  
  if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
    log_error "Neither curl nor wget found"
    return 1
  fi
  
  local release_info
  if command -v curl &> /dev/null; then
    release_info=$(curl -s "$api_url")
  else
    release_info=$(wget -qO- "$api_url")
  fi
  
  local download_url
  download_url=$(echo "$release_info" | grep -o '"browser_download_url":"[^"]*' | grep "$asset_pattern" | head -n 1 | cut -d'"' -f4)
  
  if [[ -z "$download_url" ]]; then
    log_error "Could not find matching asset for pattern: $asset_pattern"
    return 1
  fi
  
  log_info "Downloading: $download_url"
  
  local filename
  filename=$(basename "$download_url")
  local output_file="$output_dir/$filename"
  
  if [[ -f "$output_file" ]]; then
    log_info "File already exists, skipping download"
    echo "$output_file"
    return 0
  fi
  
  if command -v curl &> /dev/null; then
    curl -L -o "$output_file" "$download_url"
  else
    wget -O "$output_file" "$download_url"
  fi
  
  echo "$output_file"
}

# Clone git repository
clone_git_repo() {
  local repo_url="$1"
  local version="$2"
  local cache_dir="$3"
  
  local repo_name
  repo_name=$(basename "$repo_url" .git)
  local target_dir="$cache_dir/$repo_name"
  
  if [[ -d "$target_dir" ]]; then
    log_info "Repository already cached: $repo_name"
    if [[ -f "$target_dir/.gitmodules" ]]; then
      log_info "Updating submodules for cached repository..."
      git -C "$target_dir" submodule update --init --recursive >&2 || return 1
    fi
    echo "$target_dir"
    return 0
  fi
  
  log_info "Cloning repository: $repo_url"
  
  if [[ -n "$version" ]] && [[ "$version" != "latest" ]]; then
    if ! git clone --depth 1 --branch "$version" --recurse-submodules "$repo_url" "$target_dir"; then
      log_error "Failed to clone: $repo_url"
      return 1
    fi
  else
    if ! git clone --depth 1 --recurse-submodules "$repo_url" "$target_dir"; then
      log_error "Failed to clone: $repo_url"
      return 1
    fi
  fi

  if [[ -f "$target_dir/.gitmodules" ]]; then
    git -C "$target_dir" submodule update --init --recursive >&2 || return 1
  fi
  
  echo "$target_dir"
}

# Download from direct URL
download_direct() {
  local url="$1"
  local output_dir="$2"
  local filename="${3:-}"
  
  if [[ -z "$filename" ]]; then
    filename=$(basename "$url")
  fi
  
  local output_file="$output_dir/$filename"
  
  if [[ -f "$output_file" ]]; then
    log_info "File already exists: $filename"
    echo "$output_file"
    return 0
  fi
  
  log_info "Downloading: $url"
  
  if command -v curl &> /dev/null; then
    curl -L -o "$output_file" "$url"
  else
    wget -O "$output_file" "$url"
  fi
  
  echo "$output_file"
}

# Download source tarball (CMake-based approach)
download_source_tarball() {
  local tool_name="$1"
  local url="$2"
  local cache_dir="$3"
  
  local filename
  filename=$(basename "$url")
  local tarball_file="$cache_dir/$filename"
  
  # Check if already downloaded
  if [[ -f "$tarball_file" ]]; then
    log_info "Source tarball already exists: $filename"
    echo "$tarball_file"
    return 0
  fi
  
  log_info "Downloading source tarball: $filename"
  log_info "URL: $url"
  
  if command -v curl &> /dev/null; then
    curl -L -o "$tarball_file" "$url"
  else
    wget -O "$tarball_file" "$url"
  fi
  
  # Verify download
  if [[ ! -f "$tarball_file" ]] || [[ ! -s "$tarball_file" ]]; then
    log_error "Download failed or file is empty"
    return 1
  fi
  
  log_info "Download completed: $(du -h "$tarball_file" | awk '{print $1}')"
  
  echo "$tarball_file"
}
