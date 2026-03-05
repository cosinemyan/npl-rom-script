#!/bin/bash
# Odin Packer - Create Odin flashable AP.tar

_copy_odin_extra_file() {
  local src="$1"
  local package_dir="$2"
  local name
  name=$(basename "$src")

  if [[ "$name" == *.img.lz4 ]]; then
    cp "$src" "$package_dir/$name"
    return 0
  fi

  if [[ "$name" == *.img ]]; then
    local output_name="${name}.lz4"
    lz4 -B4 --content-size -f "$src" "$package_dir/$output_name" >/dev/null || return 1
    return 0
  fi

  cp "$src" "$package_dir/$name"
}

_resolve_tar_output_path() {
  local output_dir="$1"
  local fallback_base="$2"
  local archive_name="${3:-}"

  local tar_name=""
  if [[ -n "$archive_name" ]]; then
    tar_name="$(basename "$archive_name")"
    tar_name="${tar_name%.md5}"
    [[ "$tar_name" == *.tar ]] || tar_name="${tar_name}.tar"
  else
    tar_name="$fallback_base.tar"
  fi

  echo "$output_dir/$tar_name"
}

_discover_original_archive_name() {
  local search_dir="$1"
  local pattern="$2"

  if [[ ! -d "$search_dir" ]]; then
    return 0
  fi

  local candidate
  candidate=$(find "$search_dir" -maxdepth 1 -type f -name "$pattern" | head -n 1 || true)
  if [[ -n "$candidate" ]]; then
    basename "$candidate"
  fi
}

apply_device_odin_extras() {
  local config_file="$1"
  local package_dir="$2"

  if [[ -z "$config_file" ]] || [[ ! -f "$config_file" ]]; then
    return 0
  fi

  local device_dir family_dir
  device_dir="$(dirname "$config_file")"
  family_dir="$(dirname "$device_dir")"

  local -a extra_dirs=()
  if [[ -d "$family_dir/odin" ]]; then
    extra_dirs+=("$family_dir/odin")
  fi
  if [[ -d "$device_dir/odin" ]]; then
    extra_dirs+=("$device_dir/odin")
  fi

  if [[ ${#extra_dirs[@]} -eq 0 ]]; then
    return 0
  fi

  local extra_dir
  local copied_count=0
  for extra_dir in "${extra_dirs[@]}"; do
    log_info "Applying Odin extras from: $extra_dir"
    local extra
    for extra in "$extra_dir"/*; do
      [[ -f "$extra" ]] || continue
      _copy_odin_extra_file "$extra" "$package_dir" || {
        log_error "Failed to include Odin extra: $extra"
        return 1
      }
      (( copied_count++ ))
    done
  done

  log_info "Included $copied_count Odin extra image(s)"
}

_collect_kernel_dirs() {
  local config_file="$1"
  local -a dirs=()

  [[ -n "$config_file" && -f "$config_file" ]] || return 0

  local device_dir family_dir
  device_dir="$(dirname "$config_file")"
  family_dir="$(dirname "$device_dir")"

  [[ -d "$family_dir/kernel" ]] && dirs+=("$family_dir/kernel")
  [[ -d "$device_dir/kernel" ]] && dirs+=("$device_dir/kernel")

  local d
  for d in "${dirs[@]}"; do
    echo "$d"
  done
}

_find_custom_boot_image() {
  local config_file="$1"
  local -a dirs=()
  mapfile -t dirs < <(_collect_kernel_dirs "$config_file")
  [[ ${#dirs[@]} -gt 0 ]] || return 1

  # Device folder (later in list) has precedence over family.
  local idx
  for (( idx=${#dirs[@]}-1; idx>=0; idx-- )); do
    local d="${dirs[$idx]}"
    local candidate
    for candidate in "$d/boot.img.lz4" "$d/boot.img"; do
      if [[ -f "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    done
  done

  return 1
}

_find_custom_kernel_blob() {
  local config_file="$1"
  local -a dirs=()
  mapfile -t dirs < <(_collect_kernel_dirs "$config_file")
  [[ ${#dirs[@]} -gt 0 ]] || return 1

  # Device folder (later in list) has precedence over family.
  local idx
  for (( idx=${#dirs[@]}-1; idx>=0; idx-- )); do
    local d="${dirs[$idx]}"
    local candidate
    for candidate in \
      "$d/kernel" \
      "$d/Image" \
      "$d/Image.gz" \
      "$d/zImage" \
      "$d/Image.gz-dtb" \
      "$d/kernel.bin"
    do
      if [[ -f "$candidate" ]]; then
        echo "$candidate"
        return 0
      fi
    done
  done

  return 1
}

repack_boot_with_custom_kernel() {
  local config_file="$1"
  local firmware_source_dir="$2"
  local package_dir="$3"

  local custom_boot
  custom_boot=$(_find_custom_boot_image "$config_file" || true)
  if [[ -n "$custom_boot" ]]; then
    _copy_odin_extra_file "$custom_boot" "$package_dir" || return 1
    log_info "Custom boot image override applied: $(basename "$custom_boot")"
    return 0
  fi

  local kernel_blob
  kernel_blob=$(_find_custom_kernel_blob "$config_file" || true)
  if [[ -z "$kernel_blob" ]]; then
    return 0
  fi

  local boot_src=""
  if [[ -f "$firmware_source_dir/boot.img.lz4" ]]; then
    boot_src="$firmware_source_dir/boot.img.lz4"
  elif [[ -f "$firmware_source_dir/boot.img" ]]; then
    boot_src="$firmware_source_dir/boot.img"
  fi

  if [[ -z "$boot_src" ]]; then
    log_warn "Custom kernel provided but stock boot image not found under: $firmware_source_dir"
    return 0
  fi

  local unpack_bootimg_py="$PROJECT_ROOT/tools/cache/android-tools/vendor/mkbootimg/unpack_bootimg.py"
  local mkbootimg_py="$PROJECT_ROOT/tools/cache/android-tools/vendor/mkbootimg/mkbootimg.py"
  if [[ ! -f "$unpack_bootimg_py" ]] || [[ ! -f "$mkbootimg_py" ]]; then
    log_error "Custom kernel requested but AOSP mkbootimg scripts are missing"
    return 1
  fi

  local work_dir="$WORK_DIR/output/kernel_repack"
  rm -rf "$work_dir"
  mkdir -p "$work_dir"

  local raw_boot="$work_dir/boot.img"
  if [[ "$boot_src" == *.lz4 ]]; then
    lz4 -d -f "$boot_src" "$raw_boot" >/dev/null || return 1
  else
    cp "$boot_src" "$raw_boot"
  fi

  local split_dir="$work_dir/split"
  rm -rf "$split_dir"
  mkdir -p "$split_dir"
  local args_file="$work_dir/mkbootimg_args.bin"
  python3 "$unpack_bootimg_py" --boot_img "$raw_boot" --out "$split_dir" --format=mkbootimg -0 > "$args_file" 2>"$work_dir/unpack_bootimg.err" || {
    log_warn "unpack_bootimg.py failed on stock boot image; skipping kernel-blob repack"
    log_warn "Provide full boot.img/boot.img.lz4 in device kernel/ folder for reliable override"
    return 0
  }

  local -a mkargs=()
  while IFS= read -r -d '' arg; do
    mkargs+=("$arg")
  done < "$args_file"

  if [[ ${#mkargs[@]} -eq 0 ]]; then
    log_warn "unpack_bootimg.py returned empty mkbootimg args; skipping kernel-blob repack"
    return 0
  fi

  local -a newargs=()
  local found_kernel="false"
  local idx=0
  while [[ "$idx" -lt "${#mkargs[@]}" ]]; do
    local arg="${mkargs[$idx]}"
    case "$arg" in
      --kernel)
        newargs+=("$arg" "$kernel_blob")
        found_kernel="true"
        idx=$((idx + 2))
        ;;
      --output|-o)
        idx=$((idx + 2))
        ;;
      *)
        newargs+=("$arg")
        idx=$((idx + 1))
        ;;
    esac
  done

  if [[ "$found_kernel" != "true" ]]; then
    log_warn "unpack_bootimg.py args do not contain --kernel; skipping kernel-blob repack"
    log_warn "Provide full boot.img/boot.img.lz4 in device kernel/ folder for reliable override"
    return 0
  fi

  local rebuilt_boot="$work_dir/boot-new.img"
  python3 "$mkbootimg_py" "${newargs[@]}" --output "$rebuilt_boot" 2>"$work_dir/mkbootimg.err" || {
    log_warn "mkbootimg.py failed to repack boot with custom kernel; skipping kernel-blob repack"
    log_warn "Provide full boot.img/boot.img.lz4 in device kernel/ folder for reliable override"
    return 0
  }

  if [[ ! -f "$rebuilt_boot" ]] || [[ ! -s "$rebuilt_boot" ]]; then
    log_warn "Repacked boot image missing/empty; skipping kernel-blob repack"
    log_warn "Provide full boot.img/boot.img.lz4 in device kernel/ folder for reliable override"
    return 0
  fi

  lz4 -B4 --content-size -f "$rebuilt_boot" "$package_dir/boot.img.lz4" >/dev/null || return 1
  log_info "Custom kernel applied via boot repack: $(basename "$kernel_blob")"
}

create_odin_tar() {
  local firmware_dir="$1"
  local output_dir="$2"
  local device_name="$3"
  local ap_archive_name="${4:-}"
  
  log_info "Creating Odin flashable package..."
  
  mkdir -p "$output_dir"
  
  local ap_tar
  ap_tar=$(_resolve_tar_output_path "$output_dir" "AP_${device_name}" "$ap_archive_name")
  
  log_info "Creating AP tar: $ap_tar"
  
  cd "$firmware_dir"
  
  if [[ ! -f "super.img.lz4" ]]; then
    log_error "Missing required file for Odin package: super.img.lz4"
    cd - > /dev/null
    return 1
  fi

  local include_files=()
  local f
  while IFS= read -r f; do
    case "$f" in
      userdata*|*.sum|*.md5)
        continue
        ;;
    esac
    include_files+=("$f")
  done < <(find . -maxdepth 1 -type f -printf '%f\n' | sort)

  if [[ ${#include_files[@]} -eq 0 ]]; then
    log_error "No images found for Odin AP tar"
    cd - > /dev/null
    return 1
  fi

  tar -cf "$ap_tar" "${include_files[@]}" || {
    cd - > /dev/null
    return 1
  }
  
  cd - > /dev/null
  
  if [[ ! -f "$ap_tar" ]] || [[ ! -s "$ap_tar" ]]; then
    log_error "Failed to create AP tar"
    return 1
  fi
  
  local ap_tar_dir ap_tar_base odin_md5
  ap_tar_dir="$(dirname "$ap_tar")"
  ap_tar_base="$(basename "$ap_tar")"
  odin_md5="${ap_tar}.md5"
  (
    cd "$ap_tar_dir" || exit 1
    # Odin expects md5sum output line appended to the TAR payload.
    md5sum -t "$ap_tar_base" >> "$ap_tar_base"
  ) || {
    log_error "Failed appending Odin MD5 footer"
    return 1
  }
  mv -f "$ap_tar" "$odin_md5"
  
  log_info "Odin package created: $odin_md5"
  echo "$odin_md5"
}

create_home_csc_odin_package() {
  local home_csc_payload_dir="$1"
  local output_dir="$2"
  local device_name="${3:-custom}"
  local csc_archive_name="${4:-}"

  if [[ ! -d "$home_csc_payload_dir" ]]; then
    log_info "HOME_CSC payload directory not found; skipping HOME_CSC Odin package"
    return 0
  fi

  local package_dir="$output_dir/home_csc_package"
  mkdir -p "$package_dir"

  local copied_any="false"
  local f
  for f in "$home_csc_payload_dir"/*.img.lz4; do
    if [[ -f "$f" ]]; then
      cp "$f" "$package_dir/"
      copied_any="true"
    fi
  done

  if [[ -d "$home_csc_payload_dir/meta-data" ]]; then
    cp -a "$home_csc_payload_dir/meta-data" "$package_dir/"
    copied_any="true"
  fi

  if [[ "$copied_any" != "true" ]]; then
    rm -rf "$package_dir"
    log_info "No HOME_CSC files found for packaging; skipping"
    return 0
  fi

  local csc_tar
  csc_tar=$(_resolve_tar_output_path "$output_dir" "HOME_CSC_${device_name}" "$csc_archive_name")
  (
    cd "$package_dir" || exit 1
    tar -cf "$csc_tar" ./*
  ) || {
    rm -rf "$package_dir"
    log_error "Failed creating HOME_CSC tar"
    return 1
  }

  local csc_tar_dir csc_tar_base csc_md5
  csc_tar_dir="$(dirname "$csc_tar")"
  csc_tar_base="$(basename "$csc_tar")"
  csc_md5="${csc_tar}.md5"
  (
    cd "$csc_tar_dir" || exit 1
    # Odin expects md5sum output line appended to the TAR payload.
    md5sum -t "$csc_tar_base" >> "$csc_tar_base"
  ) || {
    rm -rf "$package_dir"
    log_error "Failed appending HOME_CSC Odin MD5 footer"
    return 1
  }
  mv -f "$csc_tar" "$csc_md5"
  rm -rf "$package_dir"

  log_success "HOME_CSC package: $csc_md5"
}

create_odin_package() {
  local super_img="$1"
  local vbmeta_img="$2"
  local vbmeta_source_dir="$3"
  local output_dir="$4"
  local device_name="${5:-custom}"
  local config_file="${6:-}"
  local patched_vbmeta_dir="${7:-}"
  
  local package_dir="$output_dir/odin_package"
  mkdir -p "$package_dir"
  
  log_info "Copying files to Odin package..."
  
  if [[ "$super_img" == *.lz4 ]]; then
    cp "$super_img" "$package_dir/"
  else
    lz4 -B4 --content-size -f "$super_img" "$package_dir/super.img.lz4" || return 1
  fi

  if [[ -n "$vbmeta_source_dir" ]] && [[ -d "$vbmeta_source_dir" ]]; then
    log_info "Including original AP images (excluding super/userdata): $vbmeta_source_dir"
    local source_img name
    for source_img in "$vbmeta_source_dir"/*.img.lz4 "$vbmeta_source_dir"/*.img; do
      [[ -f "$source_img" ]] || continue
      name=$(basename "$source_img")
      case "$name" in
        super.img|super.img.lz4|userdata*|userdata*.img|userdata*.img.lz4)
          continue
          ;;
      esac
      _copy_odin_extra_file "$source_img" "$package_dir" || return 1
    done
  fi

  if [[ -n "$vbmeta_img" ]] && [[ -f "$vbmeta_img" ]]; then
    _copy_odin_extra_file "$vbmeta_img" "$package_dir" || return 1
  fi

  if [[ -n "$patched_vbmeta_dir" ]] && [[ -d "$patched_vbmeta_dir" ]]; then
    local patched_vbmeta
    for patched_vbmeta in "$patched_vbmeta_dir"/vbmeta*.img "$patched_vbmeta_dir"/vbmeta*.img.lz4; do
      [[ -f "$patched_vbmeta" ]] || continue
      _copy_odin_extra_file "$patched_vbmeta" "$package_dir" || return 1
    done
  fi

  repack_boot_with_custom_kernel "$config_file" "$vbmeta_source_dir" "$package_dir" || return 1

  apply_device_odin_extras "$config_file" "$package_dir" || return 1

  local ap_archive_name
  ap_archive_name="${ORIGINAL_AP_ARCHIVE_NAME:-}"
  if [[ -z "$ap_archive_name" ]]; then
    ap_archive_name=$(_discover_original_archive_name "${WORK_DIR:-}/extracted/ap" "*AP*.tar*")
  fi

  local odin_tar
  odin_tar=$(create_odin_tar "$package_dir" "$output_dir" "$device_name" "$ap_archive_name") || return 1

  local home_csc_payload_dir="${WORK_DIR:-}/extracted/home_csc/payload"
  local csc_archive_name
  csc_archive_name="${ORIGINAL_HOME_CSC_ARCHIVE_NAME:-}"
  if [[ -z "$csc_archive_name" ]]; then
    csc_archive_name=$(_discover_original_archive_name "${WORK_DIR:-}/extracted/home_csc" "*HOME_CSC*.tar*")
  fi
  create_home_csc_odin_package "$home_csc_payload_dir" "$output_dir" "$device_name" "$csc_archive_name" || return 1
  
  rm -rf "$package_dir"
  
  echo "$odin_tar"
}
