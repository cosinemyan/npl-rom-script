#!/bin/bash
# Firmware Extractor - Extract Samsung firmware archives

EXTRACT_DIR=""
ORIGINAL_AP_ARCHIVE_NAME=""
ORIGINAL_HOME_CSC_ARCHIVE_NAME=""

readonly HOME_CSC_FEATURES=(
  "CscFeature_SystemUI_ConfigOverrideDataIcon|LTE"
  "CscFeature_Wifi_SupportAdvancedMenu|TRUE"
  "CscFeature_SmartManager_ConfigDashboard|dual_dashboard"
  "CscFeature_SmartManager_DisableAntiMalware|TRUE"
  "CscFeature_Calendar_SetColorOfDays|XXXXXBR"
  "CscFeature_Camera_ShutterSoundMenu|TRUE"
  "CscFeature_Camera_EnableCameraDuringCall|TRUE"
  "CscFeature_Camera_EnableSmsNotiPopup|TRUE"
  "CscFeature_Common_ConfigSvcProviderForUnknownNumber|whitepages,whitepages,whitepages"
  "CscFeature_Setting_SupportRealTimeNetworkSpeed|TRUE"
  "CscFeature_VoiceCall_ConfigRecording|RecordingAllowed,RecordingAllowedByMenu"
  "CscFeature_SystemUI_SupportRecentAppProtection|TRUE"
  "CscFeature_Knox_SupportKnoxGuard|FALSE"
  "CscFeature_RIL_SupportEsim|TRUE"
  "CscFeature_SmartManager_ConfigSubFeatures|applock"
  "CscFeature_Web_SetHomepageURL|https://www.google.com/"
  "CscFeature_Common_EnhanceImageQuality|TRUE"
  "CscFeature_Message_SupportAntiPhishing|TRUE"
)

home_csc_feature_keys_regex() {
  local key
  local keys=()
  for entry in "${HOME_CSC_FEATURES[@]}"; do
    IFS='|' read -r key _ <<< "$entry"
    keys+=("$key")
  done
  printf '%s' "$(printf '%s\n' "${keys[@]}" | paste -sd'|' -)"
}

build_home_csc_feature_block() {
  local key value
  for entry in "${HOME_CSC_FEATURES[@]}"; do
    IFS='|' read -r key value <<< "$entry"
    printf '    <%s>%s</%s>\n' "$key" "$value" "$key"
  done
}

patch_home_cscfeature_file() {
  local csc_file="$1"
  local key_regex
  key_regex=$(home_csc_feature_keys_regex)
  local feature_block
  feature_block=$(build_home_csc_feature_block)

  sed -i "/${key_regex}/d" "$csc_file" || true

  local tmp
  tmp=$(mktemp)
  awk -v block="$feature_block" '
    { print }
    !inserted && /<FeatureSet>/ {
      print block
      inserted=1
    }
  ' "$csc_file" > "$tmp" && mv "$tmp" "$csc_file"
}

find_home_csc_decoder_jar() {
  local candidates=()
  [[ -n "${OMC_DECODER_JAR:-}" ]] && candidates+=("$OMC_DECODER_JAR")
  [[ -n "${PROJECT_ROOT:-}" ]] && candidates+=("$PROJECT_ROOT/disarm_tools/omc-decoder.jar")
  [[ -n "${TOOLS_DIR:-}" ]] && candidates+=("$TOOLS_DIR/bin/omc-decoder.jar")
  [[ -n "${TOOLS_DIR:-}" ]] && candidates+=("$TOOLS_DIR/omc-decoder.jar")

  local jar
  for jar in "${candidates[@]}"; do
    if [[ -f "$jar" ]]; then
      echo "$jar"
      return 0
    fi
  done

  return 1
}

decode_home_csc_dirs() {
  local payload_dir="$1"
  if ! command -v java >/dev/null 2>&1; then
    log_warn "java not found; skipping HOME_CSC decode"
    return 0
  fi

  local decoder_jar
  decoder_jar=$(find_home_csc_decoder_jar || true)
  if [[ -z "$decoder_jar" ]]; then
    log_warn "omc-decoder.jar not found; skipping HOME_CSC decode"
    log_warn "Set OMC_DECODER_JAR=/path/to/omc-decoder.jar or place it at:"
    log_warn "  $PROJECT_ROOT/disarm_tools/omc-decoder.jar"
    log_warn "  $TOOLS_DIR/bin/omc-decoder.jar"
    return 0
  fi

  local decoded_any="false"
  local decode_root
  while IFS= read -r decode_root; do
    [[ -d "$decode_root" ]] || continue
    decoded_any="true"
    log_info "Decoding HOME_CSC OMC carrier files using: $decoder_jar ($decode_root)"
    run_with_progress "Decoding HOME_CSC OMC configs" \
      java -jar "$decoder_jar" -i "$decode_root" -o "$decode_root" || return 1
  done < <(find "$payload_dir" -type d -path "*/optics/configs/carriers" 2>/dev/null || true)

  if [[ "$decoded_any" == "false" ]]; then
    log_info "No HOME_CSC optics/configs/carriers directories found for decode"
  fi
}

extract_home_csc_images_to_dirs() {
  local payload_dir="$1"
  local unpack_root="$payload_dir/unpacked"
  mkdir -p "$unpack_root"

  local img_file
  while IFS= read -r img_file; do
    [[ -f "$img_file" ]] || continue

    local name
    name=$(basename "$img_file" .img)
    local out_dir="$unpack_root/$name"
    local temp_mount
    temp_mount=$(mktemp -d "/tmp/home_csc_${name}_XXXXXX")
    mkdir -p "$out_dir"

    local fs_desc
    fs_desc=$(file -b "$img_file" 2>/dev/null || true)
    local mount_img="$img_file"

    if echo "$fs_desc" | grep -qi "Android sparse image"; then
      if ! command -v simg2img >/dev/null 2>&1; then
        log_warn "simg2img missing; cannot unpack sparse HOME_CSC image: $img_file"
        rmdir "$temp_mount" 2>/dev/null || true
        continue
      fi
      local raw_img="${img_file%.img}-raw.img"
      run_with_progress "Converting sparse HOME_CSC image ($name)" simg2img "$img_file" "$raw_img" || {
        log_warn "Failed converting sparse HOME_CSC image: $img_file"
        rmdir "$temp_mount" 2>/dev/null || true
        continue
      }
      mount_img="$raw_img"
      fs_desc=$(file -b "$mount_img" 2>/dev/null || true)
    fi

    if echo "$fs_desc" | grep -qi "EROFS filesystem"; then
      if ! sudo mount -t erofs -o loop,ro "$mount_img" "$temp_mount" 2>/dev/null; then
        if command -v mount.erofs >/dev/null 2>&1; then
          sudo mount.erofs "$mount_img" "$temp_mount" || {
            log_warn "Failed mounting HOME_CSC EROFS image: $img_file"
            rmdir "$temp_mount" 2>/dev/null || true
            continue
          }
        else
          log_warn "mount.erofs missing; cannot extract HOME_CSC image: $img_file"
          rmdir "$temp_mount" 2>/dev/null || true
          continue
        fi
      fi
    elif echo "$fs_desc" | grep -Eqi "ext2|ext3|ext4"; then
      if ! sudo mount -t ext4 -o loop,ro "$mount_img" "$temp_mount" 2>/dev/null; then
        log_warn "Failed mounting HOME_CSC ext image: $img_file"
        rmdir "$temp_mount" 2>/dev/null || true
        continue
      fi
    else
      log_verbose "Unsupported HOME_CSC image filesystem for $img_file ($fs_desc), skipping"
      rmdir "$temp_mount" 2>/dev/null || true
      continue
    fi

    if command -v rsync >/dev/null 2>&1; then
      sudo rsync -a "$temp_mount"/ "$out_dir"/
    else
      sudo cp -a "$temp_mount"/. "$out_dir"/
    fi

    sudo umount "$temp_mount" || true
    rmdir "$temp_mount" || true
    sudo chown -R "$(id -u):$(id -g)" "$out_dir" || true
    log_info "Extracted HOME_CSC image to: $out_dir"
  done < <(find "$payload_dir" -maxdepth 1 -type f -name "*.img" 2>/dev/null || true)
}

sync_home_csc_unpacked_to_raw_image() {
  local payload_dir="$1"
  local name="$2"
  local src_dir="$payload_dir/unpacked/$name"
  local raw_img="$payload_dir/${name}-raw.img"

  if [[ ! -d "$src_dir" ]] || [[ ! -f "$raw_img" ]]; then
    return 0
  fi

  local temp_mount
  temp_mount=$(mktemp -d "/tmp/home_csc_rw_${name}_XXXXXX")

  if ! sudo mount -o loop,rw "$raw_img" "$temp_mount" 2>/dev/null; then
    sudo mount -o loop,rw,noload "$raw_img" "$temp_mount" 2>/dev/null || {
      log_warn "Failed mounting HOME_CSC raw image rw: $raw_img"
      rmdir "$temp_mount" 2>/dev/null || true
      return 1
    }
  fi

  if command -v rsync &>/dev/null; then
    run_with_progress "Syncing patched HOME_CSC data back to image ($name)" \
      sudo rsync -a --delete "$src_dir"/ "$temp_mount"/ || {
        sudo umount "$temp_mount" || true
        rmdir "$temp_mount" 2>/dev/null || true
        return 1
      }
  else
    log_verbose "rsync not available, using cp -a for HOME_CSC sync"
    run_with_progress "Copying patched HOME_CSC data back to image ($name)" \
      sudo cp -a "$src_dir"/. "$temp_mount"/ || {
        sudo umount "$temp_mount" || true
        rmdir "$temp_mount" 2>/dev/null || true
        return 1
      }
  fi

  sync
  sudo umount "$temp_mount" || true
  rmdir "$temp_mount" 2>/dev/null || true
}

prepare_home_csc_images_for_flash() {
  local payload_dir="$1"

  local prepared_any="false"
  local name
  for name in optics prism cache; do
    local raw_img="$payload_dir/${name}-raw.img"
    [[ -f "$raw_img" ]] || continue

    if [[ -d "$payload_dir/unpacked/$name" ]]; then
      sync_home_csc_unpacked_to_raw_image "$payload_dir" "$name" || true
    fi

    run_with_progress "Compressing HOME_CSC image (${name})" \
      lz4 -B4 --content-size -f "$raw_img" "$payload_dir/${name}.img.lz4" || {
        log_warn "Failed compressing HOME_CSC image: $raw_img"
        continue
      }
    prepared_any="true"
  done

  if [[ "$prepared_any" == "true" ]]; then
    log_info "HOME_CSC images prepared for Odin packaging"
  fi
}

patch_home_csc_features() {
  local payload_dir="$1"
  local csc_file
  local patched_count=0

  while IFS= read -r csc_file; do
    [[ -f "$csc_file" ]] || continue
    patch_home_cscfeature_file "$csc_file"
    patched_count=$((patched_count + 1))
    log_info "Patched HOME_CSC feature file: $csc_file"
  done < <(find "$payload_dir" -type f -name "cscfeature.xml" 2>/dev/null || true)

  if [[ "$patched_count" -eq 0 ]]; then
    log_warn "No cscfeature.xml found in HOME_CSC payload"
  else
    log_info "HOME_CSC feature patch complete. Files patched: $patched_count"
  fi
}

has_ap_archives() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f \( -name "AP*.tar*" -o -name "*AP*.tar*" \) | grep -q .
}

has_home_csc_archives() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f \( -name "HOME_CSC*.tar*" -o -name "*HOME_CSC*.tar*" \) | grep -q .
}

init_extractor() {
  EXTRACT_DIR="$WORK_DIR/extracted"
  mkdir -p "$EXTRACT_DIR"
}

extract_home_csc_payload() {
  local input="$1"
  local csc_dir="$EXTRACT_DIR/home_csc"
  local payload_dir="$csc_dir/payload"

  rm -rf "$csc_dir"
  mkdir -p "$payload_dir"

  case "$input" in
    *.zip)
      run_with_progress "Extracting HOME_CSC archive from ZIP" \
        unzip -q "$input" "HOME_CSC*.tar*" -d "$csc_dir" || true
      if ! has_home_csc_archives "$csc_dir"; then
        run_with_progress "Extracting HOME_CSC archive from ZIP (fallback)" \
          unzip -q "$input" "*HOME_CSC*.tar*" -d "$csc_dir" || true
      fi
      ;;
    *.7z)
      if command -v 7z &>/dev/null; then
        run_with_progress "Extracting HOME_CSC archive from 7z" \
          7z x -y "$input" -o"$csc_dir" "HOME_CSC*.tar*" >/dev/null || true
        if ! has_home_csc_archives "$csc_dir"; then
          run_with_progress "Extracting HOME_CSC archive from 7z (fallback)" \
            7z x -y "$input" -o"$csc_dir" "*HOME_CSC*.tar*" >/dev/null || true
        fi
      fi
      ;;
    *)
      ;;
  esac

  local csc_archive
  csc_archive=$(find "$csc_dir" -maxdepth 1 -type f \( -name "HOME_CSC*.tar*" -o -name "*HOME_CSC*.tar*" \) | head -n 1 || true)
  if [[ -z "$csc_archive" ]]; then
    log_info "No HOME_CSC archive found in input package"
    return 0
  fi
  ORIGINAL_HOME_CSC_ARCHIVE_NAME="$(basename "$csc_archive")"

  log_info "Found HOME_CSC archive: $(basename "$csc_archive")"
  run_with_progress "Extracting HOME_CSC payload" tar -xf "$csc_archive" -C "$payload_dir" || return 1

  local lz4_img
  while IFS= read -r lz4_img; do
    extract_lz4_image "$lz4_img" >/dev/null || true
  done < <(find "$payload_dir" -maxdepth 1 -type f -name "*.img.lz4" 2>/dev/null || true)

  extract_home_csc_images_to_dirs "$payload_dir"
  decode_home_csc_dirs "$payload_dir" || true
  patch_home_csc_features "$payload_dir"
  prepare_home_csc_images_for_flash "$payload_dir"
  log_info "HOME_CSC payload extracted: $payload_dir"
}

extract_original_bl_csc_archives() {
  local input="$1"
  local slots_dir="$EXTRACT_DIR/original_slots"

  rm -rf "$slots_dir"
  mkdir -p "$slots_dir"

  case "$input" in
    *.zip)
      run_with_progress "Extracting original BL/CP/CSC archives from ZIP" \
        unzip -q "$input" "*BL*.tar*" "*CP*.tar*" "*CSC*.tar*" -d "$slots_dir" || true
      if ! find "$slots_dir" -maxdepth 1 -type f | grep -q .; then
        run_with_progress "Extracting original BL/CP/CSC archives from ZIP (fallback)" \
          unzip -q "$input" "*BL*.tar*" "*CP*.tar*" "*CSC*.tar*" -d "$slots_dir" || true
      fi
      ;;
    *.7z)
      if command -v 7z &>/dev/null; then
        run_with_progress "Extracting original BL/CP/CSC archives from 7z" \
          7z x -y "$input" -o"$slots_dir" "*BL*.tar*" "*CP*.tar*" "*CSC*.tar*" >/dev/null || true
        if ! find "$slots_dir" -maxdepth 1 -type f | grep -q .; then
          run_with_progress "Extracting original BL/CP/CSC archives from 7z (fallback)" \
            7z x -y "$input" -o"$slots_dir" "*BL*.tar*" "*CP*.tar*" "*CSC*.tar*" >/dev/null || true
        fi
      fi
      ;;
    *)
      log_info "Input format does not provide bundled BL/CSC archives: $input"
      return 0
      ;;
  esac

  # Keep only BL/CP + non-HOME CSC files.
  find "$slots_dir" -maxdepth 1 -type f -name "*HOME_CSC*.tar*" -delete 2>/dev/null || true

  local count=0
  count=$(find "$slots_dir" -maxdepth 1 -type f | wc -l | tr -d ' ')
  if [[ "$count" -gt 0 ]]; then
    log_info "Original BL/CP/CSC archives extracted: $count file(s)"
  else
    log_warn "No original BL/CP/CSC archives found in input package"
  fi
}

extract_ap_tar() {
  local input="$1"
  local ap_dir

  log_info "Extracting AP archive: $input"

  case "$input" in
    *.zip)
      ap_dir="$EXTRACT_DIR/ap"
      mkdir -p "$ap_dir"
      run_with_progress "Extracting AP files from ZIP" unzip -q "$input" "AP*.tar*" "AP*.md5" -d "$ap_dir" || true
      if ! has_ap_archives "$ap_dir"; then
        run_with_progress "Extracting AP files from ZIP (fallback)" unzip -q "$input" "*AP*.tar*" "*AP*.md5" -d "$ap_dir" || return 1
      fi
      ;;
    *.7z)
      ap_dir="$EXTRACT_DIR/ap"
      mkdir -p "$ap_dir"

      if ! command -v 7z &> /dev/null; then
        log_error "7z input detected but '7z' is not installed"
        return 1
      fi

      run_with_progress "Extracting AP files from 7z" 7z x -y "$input" -o"$ap_dir" "AP*.tar*" "AP*.md5" >/dev/null || true
      if ! has_ap_archives "$ap_dir"; then
        run_with_progress "Extracting AP files from 7z (fallback)" 7z x -y "$input" -o"$ap_dir" "*AP*.tar*" "*AP*.md5" >/dev/null || return 1
      fi
      ;;
    *.tar.md5)
      ap_dir="$EXTRACT_DIR/ap"
      mkdir -p "$ap_dir"
      run_with_progress "Extracting AP tar.md5" tar -xf "$input" -C "$ap_dir" || return 1
      ;;
    *)
      log_error "Unsupported input format: $input"
      return 1
      ;;
  esac

  echo "$ap_dir"
}

extract_lz4_image() {
  local lz4_file="$1"
  local output_file="${lz4_file%.lz4}"

  run_with_progress "Decompressing LZ4 image: $(basename "$lz4_file")" lz4 -d -f "$lz4_file" "$output_file" || {
    run_with_progress "Decompressing LZ4 (fallback)" lz4cat "$lz4_file" > "$output_file"
  }

  echo "$output_file"
}

extract_firmware_structure() {
  local ap_dir="$1"
  local firmware_dir="$EXTRACT_DIR/firmware"
  mkdir -p "$firmware_dir"

  local ap_candidates=()
  for tar_file in "$ap_dir"/AP*.tar "$ap_dir"/AP*.tar.md5; do
    [[ -f "$tar_file" ]] && ap_candidates+=("$tar_file")
  done

  if [[ ${#ap_candidates[@]} -eq 0 ]]; then
    for tar_file in "$ap_dir"/*AP*.tar "$ap_dir"/*AP*.tar.md5; do
      [[ -f "$tar_file" ]] && ap_candidates+=("$tar_file")
    done
  fi

  if [[ ${#ap_candidates[@]} -eq 0 ]]; then
    log_error "No AP archive found in: $ap_dir"
    return 1
  fi

  # Select largest if multiple
  local selected="${ap_candidates[0]}"
  if [[ ${#ap_candidates[@]} -gt 1 ]]; then
    local largest_size=0
    for f in "${ap_candidates[@]}"; do
      local s
      s=$(stat -c%s "$f" 2>/dev/null || echo 0)
      if [[ "$s" -gt "$largest_size" ]]; then
        largest_size="$s"
        selected="$f"
      fi
    done
  fi
  ORIGINAL_AP_ARCHIVE_NAME="$(basename "$selected")"

  run_with_progress "Extracting firmware payload from AP archive" tar -xf "$selected" -C "$firmware_dir" || return 1

  echo "$firmware_dir"
}

find_super_image() {
  local firmware_dir="$1"
  local super_image
  super_image=$(find "$firmware_dir" -name "super.img" -o -name "super.img.lz4" | head -n 1)
  [[ -z "$super_image" ]] && return 1
  echo "$super_image"
}
