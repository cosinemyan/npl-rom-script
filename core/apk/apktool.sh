#!/bin/bash
# Apktool Wrapper - Decode, patch, rebuild and sign Android APKs
# Adapted from UN1CA's scripts/apktool.sh for rom-builder

APKTOOL_DIR="$WORK_DIR/apktool"
APKTOOL_FRAMEWORK_DIR="$TOOLS_DIR/cache/apktool/framework"

# --- Framework management ---

apktool_install_framework() {
  local framework_apk="$1"

  if [[ ! -f "$framework_apk" ]]; then
    log_error "Framework APK not found: $framework_apk"
    return 1
  fi

  if ! command -v apktool &>/dev/null; then
    log_error "apktool not found in PATH"
    return 1
  fi

  local framework_tag
  framework_tag=$(get_prop_from_file "${WORK_DIR}/mount/system/system/build.prop" "ro.build.version.incremental" 2>/dev/null || true)
  if [[ -z "$framework_tag" ]]; then
    framework_tag=$(get_prop_from_file "${WORK_DIR}/extracted/firmware/system/system/build.prop" "ro.build.version.incremental" 2>/dev/null || true)
  fi
  if [[ -z "$framework_tag" ]]; then
    framework_tag="default"
  fi

  mkdir -p "$APKTOOL_FRAMEWORK_DIR"

  if [[ -f "$APKTOOL_FRAMEWORK_DIR/1-$framework_tag.apk" ]]; then
    log_verbose "Framework already installed for tag: $framework_tag"
    return 0
  fi

  log_info "Installing framework-res.apk (tag: $framework_tag)"
  apktool if -p "$APKTOOL_FRAMEWORK_DIR" -t "$framework_tag" "$framework_apk" || {
    log_error "Failed to install framework"
    return 1
  }
}

# --- APK decode ---

apktool_decode() {
  local partition="$1"
  local apk_path="$2"

  # Strip leading slash
  while [[ "${apk_path:0:1}" == "/" ]]; do
    apk_path="${apk_path:1}"
  done

  local apk_name
  apk_name=$(basename "$apk_path")

  local output_dir="$APKTOOL_DIR/$partition/${apk_path%/*}/$apk_name"

  # Idempotent: skip if already decoded
  if [[ -d "$output_dir" ]] && [[ -f "$output_dir/apktool.yml" ]]; then
    log_verbose "Already decoded: $apk_name"
    echo "$output_dir"
    return 0
  fi

  local input_file
  input_file=$(resolve_partition_file "$partition" "$apk_path")
  if [[ -z "$input_file" ]] || [[ ! -f "$input_file" ]]; then
    log_error "APK not found: /$partition/$apk_path"
    return 1
  fi

  # Ensure framework is installed
  local framework_apk
  framework_apk=$(resolve_partition_file "system" "system/framework/framework-res.apk" 2>/dev/null || true)
  if [[ -n "$framework_apk" ]] && [[ -f "$framework_apk" ]]; then
    apktool_install_framework "$framework_apk" || true
  fi

  local framework_tag
  framework_tag=$(get_prop_from_file "${WORK_DIR}/mount/system/system/build.prop" "ro.build.version.incremental" 2>/dev/null || true)
  if [[ -z "$framework_tag" ]]; then
    framework_tag="default"
  fi

  local thread_count
  thread_count=$(awk -v max="$(nproc)" '/MemTotal/ {
    tc = int(($2 + 1048575) / 2097152);
    print (tc < 1 ? 1 : (tc > max ? max : tc));
  }' /proc/meminfo)

  log_info "Decoding: $apk_name"
  run_with_progress "Decoding $apk_name" \
    apktool d --no-debug-info -j "$thread_count" -o "$output_dir" \
      -p "$APKTOOL_FRAMEWORK_DIR" -t "$framework_tag" "$input_file" || {
    log_error "Failed to decode: $apk_name"
    return 1
  }

  echo "$output_dir"
}

# --- APK build ---

apktool_build() {
  local partition="$1"
  local apk_path="$2"

  while [[ "${apk_path:0:1}" == "/" ]]; do
    apk_path="${apk_path:1}"
  done

  local apk_name
  apk_name=$(basename "$apk_path")
  local decoded_dir="$APKTOOL_DIR/$partition/${apk_path%/*}/$apk_name"

  if [[ ! -d "$decoded_dir" ]]; then
    log_error "Decoded APK not found: $decoded_dir"
    return 1
  fi

  local thread_count
  thread_count=$(awk -v max="$(nproc)" '/MemTotal/ {
    tc = int(($2 + 1048575) / 2097152);
    print (tc < 1 ? 1 : (tc > max ? max : tc));
  }' /proc/meminfo)

  log_info "Rebuilding: $apk_name"

  # Copy original META-INF for signing
  local build_apk_dir="$decoded_dir/build/apk"
  mkdir -p "$build_apk_dir"
  if [[ -d "$decoded_dir/original/META-INF" ]]; then
    cp -a "$decoded_dir/original/META-INF" "$build_apk_dir/META-INF"
  fi

  run_with_progress "Building $apk_name" \
    apktool b -j "$thread_count" -p "$APKTOOL_FRAMEWORK_DIR" "$decoded_dir" || {
    log_error "Failed to build: $apk_name"
    return 1
  }

  local rebuilt_apk="$decoded_dir/dist/$apk_name"
  if [[ ! -f "$rebuilt_apk" ]]; then
    log_error "Rebuilt APK not found: $rebuilt_apk"
    return 1
  fi

  # Sign the APK with platform key
  local platform_key="$PROJECT_ROOT/security/platform/platform"
  local signapk_cmd=""
  if command -v signapk &>/dev/null; then
    signapk_cmd="signapk"
  elif [[ -f "$PROJECT_ROOT/security/signapk/signapk" ]]; then
    signapk_cmd="$PROJECT_ROOT/security/signapk/signapk"
  fi

  if [[ -n "$signapk_cmd" ]] && [[ -f "${platform_key}.x509.pem" ]] && [[ -f "${platform_key}.pk8" ]]; then
    log_info "Signing: $apk_name"
    local signed_apk="$decoded_dir/dist/${apk_name}.signed"
    "$signapk_cmd" "${platform_key}.x509.pem" "${platform_key}.pk8" "$rebuilt_apk" "$signed_apk" || {
      log_warn "Signing failed, using unsigned APK"
      signed_apk="$rebuilt_apk"
    }
    if [[ "$signed_apk" != "$rebuilt_apk" ]]; then
      mv -f "$signed_apk" "$rebuilt_apk"
    fi
  else
    log_warn "signapk or platform keys not found; skipping APK signing"
    if ! command -v signapk &>/dev/null && [[ ! -f "$PROJECT_ROOT/security/signapk/signapk" ]]; then
      log_warn "Build signapk with: ./security/signapk/build.sh (requires JDK 17+)"
    fi
  fi

  # Replace original APK
  local target_file
  target_file=$(resolve_partition_file "$partition" "$apk_path")
  if [[ -n "$target_file" ]] && [[ -f "$target_file" ]]; then
    mv -f "$rebuilt_apk" "$target_file"
    log_info "Replaced: $target_file"
  else
    log_warn "Could not locate original APK to replace: /$partition/$apk_path"
    echo "$rebuilt_apk"
    return 0
  fi

  # Cleanup build artifacts
  rm -rf "$decoded_dir/build" "$decoded_dir/dist"

  # Remove odex/vdex/art profiles if present
  local apk_dir
  apk_dir=$(dirname "$target_file")
  if [[ -d "$apk_dir/oat" ]]; then
    rm -rf "$apk_dir/oat"
    log_verbose "Removed oat directory for: $apk_name"
  fi
  local base_name="${apk_name%.*}"
  rm -f "$apk_dir/$base_name.prof" "$apk_dir/$base_name.bprof" 2>/dev/null || true

  # Mark decoded directory as needing rebuild (already done)
  log_info "Rebuilt and signed: $apk_name"
}

# --- Helpers ---

resolve_partition_file() {
  local partition="$1"
  local rel_path="$2"

  # Check mount point first (for ext4/loop-mounted partitions)
  local mount_file="$WORK_DIR/mount/$partition/$rel_path"
  if [[ -f "$mount_file" ]]; then
    echo "$mount_file"
    return 0
  fi

  # Check extracted partition images (for EROFS-extracted dirs)
  mount_file="$MOUNT_DIR/$partition/$rel_path"
  if [[ -f "$mount_file" ]]; then
    echo "$mount_file"
    return 0
  fi

  # Check extracted firmware
  mount_file="$WORK_DIR/extracted/firmware/$partition/$rel_path"
  if [[ -f "$mount_file" ]]; then
    echo "$mount_file"
    return 0
  fi

  echo ""
}

get_prop_from_file() {
  local prop_file="$1"
  local key="$2"

  if [[ ! -f "$prop_file" ]]; then
    return 1
  fi

  grep -m1 "^${key}=" "$prop_file" 2>/dev/null | cut -d'=' -f2-
}
