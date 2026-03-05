#!/bin/bash
# ROM Builder CLI - Main entry point

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly CORE_DIR="$PROJECT_ROOT/core"
readonly DEVICES_DIR="$PROJECT_ROOT/devices"
readonly PATCHES_DIR="$PROJECT_ROOT/patches"
readonly TOOLS_DIR="$PROJECT_ROOT/tools"
readonly BIN_DIR="$TOOLS_DIR/bin"
readonly BASE_WORK_DIR="$PROJECT_ROOT/work"
readonly DEVICE_ROOT_NAME="$(basename "$DEVICES_DIR")"
WORK_DIR="$BASE_WORK_DIR"

# Setup PATH to use bootstrapped tools first
export PATH="$BIN_DIR:$PATH"

source "$CORE_DIR/logger.sh"
source "$CORE_DIR/yaml_parser.sh"

source "$CORE_DIR/firmware/downloader.sh"
source "$CORE_DIR/firmware/extractor.sh"
source "$CORE_DIR/firmware/verify.sh"
source "$CORE_DIR/partition/super_extract.sh"
source "$CORE_DIR/partition/mount.sh"
source "$CORE_DIR/partition/repack.sh"
source "$CORE_DIR/partition/erofs_extract.sh"
source "$CORE_DIR/partition/dynamic_rebuild.sh"
source "$CORE_DIR/avb/fstab_patch.sh"
source "$CORE_DIR/avb/vbmeta_patch.sh"
source "$CORE_DIR/packer/odin.sh"
source "$CORE_DIR/packer/twrp.sh"
source "$CORE_DIR/patch_engine.sh"

BUILD_DEVICE_FAMILY=""
BUILD_DEVICE_VARIANT=""
BUILD_OUTPUT_NAME=""

usage() {
  cat << EOF
ROM Builder - Samsung OneUI ROM Modification Framework

Usage:
  $0 build [OPTIONS]
  $0 clean [--device DEVICE | --all]
  $0 umount [--device DEVICE | --all]

Options:
  --device DEVICE       Device model (dm1q, dm2q, dm3q)
  --region REGION       Firmware region (INS, XEU, etc.)
  --profile PROFILE     Patch profile (lite, aggressive, all)
  --input SOURCE        Input firmware file, URL, or 'auto'
  --output FORMAT       Output format (odin, twrp) [default: odin]
  --verbose             Enable verbose logging
  --clean               Clean work directory before build
  --resume              Resume from existing work/ artifacts when available
  --setup-tools         Run tools setup before building
  --keep-mounts         Keep partitions mounted after patching for manual inspection
                        (unmount manually with: sudo umount work/mount/*)
  --help                Show this help

Examples:
  $0 build --device dm1q --region INS --profile aggressive --input firmware.zip --output odin
  $0 build --device dm2q --profile lite --input AP.tar.md5 --verbose
  $0 build --device dm1q --region INS --input auto --output odin
  $0 build --setup-tools --device dm3q --input firmware.zip
  $0 build --resume --device dm1q --input firmware.zip --output odin
  $0 build --device dm1q --input firmware.zip --keep-mounts  # inspect patches, then build continues
  $0 clean --device dm1q
  $0 clean --all
  $0 umount --all
EOF
  exit 1
}

check_tools() {
  log_info "Checking required tools..."
  
  local required_tools=("lz4" "tar" "unzip")
  local missing_tools=()
  
  for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
      missing_tools+=("$tool")
    fi
  done
  
  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing_tools[*]}"
    log_error "Run: ./tools/setup.sh"
    return 1
  fi
  
  log_info "All required tools available"
  
  local optional_tools=("simg2img" "lpunpack" "lpmake" "avbtool" "e2fsdroid")
  local missing_optional=()
  
  for tool in "${optional_tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
      missing_optional+=("$tool")
    fi
  done
  
  if [[ ${#missing_optional[@]} -gt 0 ]]; then
    log_warn "Optional tools not found: ${missing_optional[*]}"
    log_warn "Some features may not work"
    log_warn "Run: ./tools/setup.sh to install them"
  fi
}

setup_tools_if_needed() {
  if [[ ! -d "$BIN_DIR" ]] || [[ -z "$(ls -A $BIN_DIR 2>/dev/null)" ]]; then
    log_info "No tools found. Running setup..."
    
    if [[ -f "$TOOLS_DIR/setup.sh" ]]; then
      "$TOOLS_DIR/setup.sh" || {
        log_error "Tools setup failed"
        return 1
      }
    else
      log_error "Setup script not found: $TOOLS_DIR/setup.sh"
      return 1
    fi
  fi
}

validate_prerequisites() {
  log_info "Validating prerequisites..."
  
  if ! command -v python3 &> /dev/null; then
    log_error "python3 is required"
    return 1
  fi
  
  setup_tools_if_needed || return 1
  check_tools || return 1
  
  log_info "Prerequisites validated"
}

parse_device_config() {
  local device="$1"
  local config_file="$DEVICES_DIR/$device/config.yaml"

  if [[ ! -f "$config_file" ]]; then
    mapfile -t nested_matches < <(find "$DEVICES_DIR" -mindepth 2 -maxdepth 3 -type f -path "*/$device/config.yaml" 2>/dev/null | sort)
    if [[ ${#nested_matches[@]} -eq 1 ]]; then
      config_file="${nested_matches[0]}"
      log_info "Resolved nested device '$device' to: $config_file"
    elif [[ ${#nested_matches[@]} -gt 1 ]]; then
      log_error "Ambiguous nested device '$device'. Matches:"
      printf '%s\n' "${nested_matches[@]}" >&2
      return 1
    else
      log_error "Device config not found: $config_file"
      return 1
    fi
  fi
  
  log_info "Loading device config for: $device"
  
  local model soc fstab
  model=$(parse_yaml_value "$config_file" "model")
  soc=$(parse_yaml_value "$config_file" "soc")
  fstab=$(parse_yaml_value "$config_file" "fstab")
  
  log_info "Model: $model | SoC: $soc | FSTAB: $fstab"
  
  echo "$config_file"
}

resolve_device_metadata() {
  local requested_device="$1"
  local config_file="$2"

  local config_dir parent_dir family variant output_name
  config_dir="$(dirname "$config_file")"
  parent_dir="$(basename "$(dirname "$config_dir")")"
  variant="$(basename "$config_dir")"

  family=$(parse_yaml_value "$config_file" "family" || true)
  if [[ -z "$family" ]] && [[ "$parent_dir" != "$DEVICE_ROOT_NAME" ]]; then
    family="$parent_dir"
  fi

  local config_variant
  config_variant=$(parse_yaml_value "$config_file" "variant" || true)
  if [[ -n "$config_variant" ]]; then
    variant="$config_variant"
  fi

  output_name=$(parse_yaml_value "$config_file" "output_name" || true)
  if [[ -z "$output_name" ]]; then
    output_name="$variant"
  fi
  output_name="${output_name//\//_}"

  BUILD_DEVICE_FAMILY="$family"
  BUILD_DEVICE_VARIANT="$variant"
  BUILD_OUTPUT_NAME="$output_name"

  log_info "Resolved device metadata: family=${BUILD_DEVICE_FAMILY:-none} | variant=$BUILD_DEVICE_VARIANT | output_name=$BUILD_OUTPUT_NAME"
  if [[ "$requested_device" != "$variant" ]]; then
    log_info "Requested device '$requested_device' maps to variant '$variant'"
  fi
}

normalize_device_alias() {
  local input_device="$1"
  case "$input_device" in
    s23) echo "dm1q" ;;
    s23plus) echo "dm2q" ;;
    s23ultra) echo "dm3q" ;;
    *) echo "$input_device" ;;
  esac
}

extract_firmware() {
  local input="$1"
  
  log_info "=== Step 1: Extracting Firmware ==="
  
  init_extractor
  extract_original_bl_csc_archives "$input" || true
  extract_home_csc_payload "$input" || true
  
  local ap_dir
  ap_dir=$(extract_ap_tar "$input") || return 1
  
  local firmware_dir
  firmware_dir=$(extract_firmware_structure "$ap_dir") || return 1
  
  verify_firmware_structure "$firmware_dir" || return 1
  
  local super_img
  super_img=$(find_super_image "$firmware_dir") || return 1
  
  echo "$firmware_dir|$super_img"
}

extract_fw_version() {
  local ap_name="${ORIGINAL_AP_ARCHIVE_NAME:-}"
  if [[ -z "$ap_name" ]] && [[ -d "$WORK_DIR/extracted/ap" ]]; then
    local candidate
    candidate=$(find "$WORK_DIR/extracted/ap" -maxdepth 1 -type f \( -name "AP*.tar*" -o -name "*AP*.tar*" \) | head -n 1 || true)
    [[ -n "$candidate" ]] && ap_name="$(basename "$candidate")"
  fi

  if [[ -n "$ap_name" ]]; then
    local base
    base="${ap_name%.md5}"
    base="${base%.tar}"
    base="${base#*AP_}"
    local fw="${base%%_*}"
    if [[ -n "$fw" ]]; then
      echo "$fw"
      return 0
    fi
  fi

  echo "UNKNOWNFW"
}

create_shareable_7z_bundle() {
  local device_name="$1"
  local final_dir="$WORK_DIR/final"
  local slots_dir="$WORK_DIR/extracted/original_slots"

  if ! command -v 7z &>/dev/null; then
    log_warn "7z not available; skipping shareable firmware bundle"
    return 0
  fi

  local ap_pkg home_csc_pkg
  ap_pkg=$(find "$final_dir" -maxdepth 1 -type f -name "*AP*.tar.md5" | head -n 1 || true)
  home_csc_pkg=$(find "$final_dir" -maxdepth 1 -type f -name "*HOME_CSC*.tar.md5" | head -n 1 || true)

  if [[ -z "$ap_pkg" ]] || [[ -z "$home_csc_pkg" ]]; then
    log_warn "Missing AP/HOME_CSC package(s); skipping shareable firmware bundle"
    return 0
  fi

  local -a slot_files=()
  if [[ -d "$slots_dir" ]]; then
    mapfile -t slot_files < <(find "$slots_dir" -maxdepth 1 -type f \( -name "*BL*.tar*" -o -name "*CP*.tar*" -o -name "*CSC*.tar*" \) ! -name "*HOME_CSC*.tar*" | sort)
  fi

  if [[ ${#slot_files[@]} -eq 0 ]]; then
    log_warn "Original BL/CP/CSC archives not found; skipping shareable firmware bundle"
    return 0
  fi

  local fw_version bundle_name bundle_stage bundle_path
  fw_version=$(extract_fw_version)
  bundle_name="NPL_ROM_${device_name}_${fw_version}"
  bundle_stage="$final_dir/${bundle_name}_stage"
  bundle_path="$final_dir/${bundle_name}.7z"

  rm -rf "$bundle_stage"
  mkdir -p "$bundle_stage"
  rm -f "$bundle_path"

  cp "$ap_pkg" "$bundle_stage/"
  cp "$home_csc_pkg" "$bundle_stage/"

  local f
  for f in "${slot_files[@]}"; do
    cp "$f" "$bundle_stage/"
  done

  run_with_progress "Building shareable firmware 7z bundle" \
    7z a -t7z -mx=9 "$bundle_path" "$bundle_stage"/* >/dev/null || {
      log_warn "Failed to create shareable firmware bundle"
      rm -rf "$bundle_stage"
      return 0
    }

  rm -rf "$bundle_stage"
  log_success "Shareable bundle: $bundle_path"
}

extract_super_partitions_step() {
  local super_img="$1"
  
  log_info "=== Step 2: Extracting Super Partitions ==="
  
  init_super_extract
  
  if [[ "$super_img" == *.lz4 ]]; then
    super_img=$(extract_lz4_image "$super_img") || return 1
  fi
  
  local partitions_dir
  partitions_dir=$(extract_super_partitions "$super_img") || return 1
  
  echo "$partitions_dir"
}

mount_and_apply_patches() {
  local partitions_dir="$1"
  local config_file="$2"
  local profile="${3:-lite}"
  local device="$4"
  local keep_mounts="${5:-false}"
  local hooks_file
  hooks_file="$(dirname "$config_file")/hooks.sh"

  log_info "=== Step 3: Mounting Partitions ==="

  init_mount

  if [[ -f "$hooks_file" ]]; then
    source "$hooks_file"
  fi

  local partitions
  mapfile -t partitions < <(get_device_partitions "$config_file")

  log_info "Mounting partitions: ${partitions[*]}"

  local mount_points=()
  for partition in "${partitions[@]}"; do
    local img="$partitions_dir/$partition.img"

    if [[ ! -f "$img" ]]; then
      log_warn "Partition not found: $partition"
      continue
    fi

    if command -v simg2img &> /dev/null; then
      if is_sparse_image "$img"; then
        img=$(convert_simg_to_img "$img" || return 1)
      fi
    else
      log_verbose "simg2img not available, using image directly"
    fi

    local mount_point
    mount_point=$(mount_partition "$img" "" "$partition") || true

    if [[ -n "$mount_point" ]]; then
      mount_points+=("$mount_point")
    else
      log_verbose "Partition $partition returned empty mount point (likely EROFS), skipping"
    fi
  done

  if [[ ${#mount_points[@]} -eq 0 ]]; then
    log_warn "No partitions were mounted. Skipping patch application."
    log_warn "This may happen if all partitions use EROFS and libfuse-dev is not installed."
    log_warn "The build will continue using original partition images."
  else
    log_info "=== Step 4: Applying Patches ==="

    local patch_log="$WORK_DIR/patch_changes.log"
    local patch_action_log="$WORK_DIR/patch_actions.log"
    : > "$patch_log"
    : > "$patch_action_log"
    export PATCH_ACTION_LOG="$patch_action_log"
    log_info "Patch change log: $patch_log"
    log_info "Patch action log: $patch_action_log"

    for mount_point in "${mount_points[@]}"; do
      log_info "Patching: $mount_point"

      # Snapshot mtimes before patching so we can report what changed
      local snap_before snap_after
      snap_before=$(find "$mount_point" -type f -not -path '*/proc/*' -not -path '*/sys/*' \
        -printf '%p\t%T@\t%s\n' 2>/dev/null || true)

      if declare -F device_pre_patch >/dev/null; then
        device_pre_patch "$mount_point"
      fi
      apply_patch_profile "$profile" "$mount_point" "$device" "$config_file"
      if [[ "$(basename "$mount_point")" == "vendor" ]]; then
        patch_fstab "$mount_point" "$config_file" || true
      fi
      patch_init_rc "$mount_point" "vaultkeeper" "disable" || true
      if declare -F device_post_patch >/dev/null; then
        device_post_patch "$mount_point"
      fi
      if declare -F device_custom_patches >/dev/null; then
        device_custom_patches "$mount_point"
      fi
      # Diff snapshot: report new and modified files
      snap_after=$(find "$mount_point" -type f -not -path '*/proc/*' -not -path '*/sys/*' \
        -printf '%p\t%T@\t%s\n' 2>/dev/null || true)

      local modified_lines deleted_lines
      modified_lines=$(awk -F'\t' '
        NR==FNR {b_mtime[$1]=$2; b_size[$1]=$3; next}
        {a_mtime[$1]=$2; a_size[$1]=$3}
        END {
          for (p in a_size) {
            if (!(p in b_size)) {
              print "  NEW:       " p " (size " a_size[p] ")"
            } else if (a_size[p] != b_size[p] || a_mtime[p] != b_mtime[p]) {
              print "  MODIFIED:  " p " (size " b_size[p] " -> " a_size[p] ")"
            }
          }
        }
      ' <(echo "$snap_before") <(echo "$snap_after") | sort)
      deleted_lines=$(awk -F'\t' '
        NR==FNR {b_size[$1]=$3; next}
        {a_seen[$1]=1}
        END {
          for (p in b_size) {
            if (!(p in a_seen)) {
              print "  DELETED:   " p " (old size " b_size[p] ")"
            }
          }
        }
      ' <(echo "$snap_before") <(echo "$snap_after") | sort)

      local modified_count new_count deleted_count log_limit
      modified_count=$(echo "$modified_lines" | grep -c '^  MODIFIED:' || true)
      new_count=$(echo "$modified_lines" | grep -c '^  NEW:' || true)
      deleted_count=$(echo "$deleted_lines" | grep -c '^  DELETED:' || true)
      log_limit="${PATCH_LOG_LIMIT:-250}"
      local action_log_limit
      action_log_limit="${PATCH_ACTION_LOG_LIMIT:-0}"

      echo "=== Changes in: $mount_point ==" >> "$patch_log"
      echo "  SUMMARY: modified=$modified_count deleted=$deleted_count" >> "$patch_log"
      if [[ "$modified_count" -gt 0 ]]; then
        echo "$modified_lines" | head -n "$log_limit" >> "$patch_log"
        if [[ "$modified_count" -gt "$log_limit" ]]; then
          echo "  ... truncated $((modified_count - log_limit)) modified entries" >> "$patch_log"
        fi
      fi
      if [[ "$deleted_count" -gt 0 ]]; then
        echo "$deleted_lines" | head -n "$log_limit" >> "$patch_log"
        if [[ "$deleted_count" -gt "$log_limit" ]]; then
          echo "  ... truncated $((deleted_count - log_limit)) deleted entries" >> "$patch_log"
        fi
      fi
      echo "" >> "$patch_log"

      # Mirror full filesystem-level change tracking into patch_actions.log so
      # script-driven edits (not only patch-engine operations) are visible.
      {
        printf '[%s] FS_SUMMARY mount=%s new=%s modified=%s deleted=%s\n' \
          "$(date '+%Y-%m-%d %H:%M:%S')" "$mount_point" "$new_count" "$modified_count" "$deleted_count"

        local mod_entries
        mod_entries=$(echo "$modified_lines" | grep '^  MODIFIED:' || true)

        if [[ -n "$mod_entries" ]]; then
          if [[ "$action_log_limit" -gt 0 ]]; then
            mod_entries=$(echo "$mod_entries" | head -n "$action_log_limit")
          fi
          while IFS= read -r ln; do
            [[ -n "$ln" ]] || continue
            printf '[%s] FS_MODIFIED mount=%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mount_point" "${ln#  }"
          done <<< "$mod_entries"
        fi

      } >> "$patch_action_log"
    done

    log_info "Patch change summary written to: $patch_log"
  fi

  log_info "=== Step 5.5: EROFS Partition Handling ===" 

  if [[ ${#EROFSPARTITIONS[@]} -gt 0 ]]; then
    log_info "EROFS partitions detected: ${EROFSPARTITIONS[*]}"
    if [[ ${#mount_points[@]} -gt 0 ]]; then
      log_info "EROFS partitions extracted to writable dirs and patched."
      log_info "They will be repacked with mkfs.erofs before super.img rebuild."
    else
      log_warn "EROFS partitions could not be extracted (sudo/EROFS module unavailable)"
      log_warn "Using original EROFS images without modifications"
    fi
  fi

  if [[ "$keep_mounts" == "true" ]]; then
    log_info "=== Step 5: Keeping Work Dirs (--keep-mounts active) ==="
    log_info ""
    log_info "  Review changed files:  cat $WORK_DIR/patch_changes.log"
    log_info "  Inspect partitions:    ls $MOUNT_DIR/"
    if [[ ${#mount_points[@]} -gt 0 ]]; then
      log_warn "  Kernel-mounted partitions (run to unmount when done):"
      for mp in "${mount_points[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null; then
          log_warn "    sudo umount $mp"
        else
          log_info "    $mp  (extracted dir — no unmount needed)"
        fi
      done
    fi
    log_info "Continuing build without pause (--keep-mounts keeps extracted dirs for inspection)."
  else
    log_info "=== Step 5: Unmounting Partitions ==="
    umount_all_partitions
  fi

  log_info "Patching completed"
}

repack_erofs_partitions() {
  local mount_dir="$1"
  local partitions_dir="$2"

  if [[ ${#EROFSPARTITIONS[@]} -eq 0 ]]; then
    return 0
  fi

  log_info "=== Step 5.9: Repacking EROFS Partitions ==="

  if ! command -v mkfs.erofs &>/dev/null; then
    log_warn "mkfs.erofs not found — skipping EROFS repack, using original images"
    return 0
  fi

  for partition_name in "${EROFSPARTITIONS[@]}"; do
    local src_dir="$mount_dir/$partition_name"
    local out_img="$partitions_dir/${partition_name}.img"

    if [[ ! -d "$src_dir" ]]; then
      log_warn "EROFS extracted dir not found: $src_dir — skipping repack"
      continue
    fi

    repack_erofs_from_dir "$src_dir" "$out_img" "$partition_name" || {
      log_warn "Failed to repack $partition_name — using original image"
    }
  done

  log_info "EROFS repack complete"
}


rebuild_partitions_and_super() {
  local partitions_dir="$1"
  local config_file="$2"
  local original_super_img="$3"
  
  log_info "=== Step 6: Rebuilding Partitions ==="
  
  if command -v e2fsck &> /dev/null && command -v resize2fs &> /dev/null; then
    local img
    for img in "$partitions_dir"/*.img; do
      [[ -f "$img" ]] || continue

      local fs_desc
      fs_desc=$(file -b "$img" 2>/dev/null || true)
      if echo "$fs_desc" | grep -Eqi "ext2|ext3|ext4"; then
        local part_name
        part_name=$(basename "$img" .img)
        log_info "Optimizing ext4 partition image: $part_name"
        optimize_partition "$img" || true
      else
        log_verbose "Skipping non-ext partition image: $(basename "$img") ($fs_desc)"
      fi
    done
  else
    log_warn "e2fsck/resize2fs not found; skipping ext4 minimization pass"
  fi
  
  log_info "=== Step 7: Rebuilding super.img ==="
  
  local output_super="$WORK_DIR/output/super.img"
  mkdir -p "$(dirname "$output_super")"
  
  if command -v lpmake &> /dev/null; then
    rebuild_super_img "$partitions_dir" "$output_super" "$config_file" || return 1
  else
    log_warn "lpmake not available, skipping super.img rebuild"
    log_warn "Output will use original super.img"
    output_super="$original_super_img"
  fi
  
  echo "$output_super"
}

create_output_package() {
  local super_img="$1"
  local output_format="$2"
  local device="$3"
  local vbmeta_img="${4:-}"
  local vbmeta_source_dir="${5:-}"
  local config_file="${6:-}"
  local patched_vbmeta_dir="${7:-}"
  
  log_info "=== Step 9: Creating Output Package ==="
  
  local output_dir="$WORK_DIR/final"
  mkdir -p "$output_dir"
  
  case "$output_format" in
    odin)
      local package
      package=$(create_odin_package "$super_img" "$vbmeta_img" "$vbmeta_source_dir" "$output_dir" "$device" "$config_file" "$patched_vbmeta_dir") || return 1
      [[ -n "$package" ]] || return 1
      [[ -f "$package" ]] || return 1
      log_success "Odin package: $package"
      ;;
    twrp)
      local package
      package=$(create_twrp_zip "$(dirname "$super_img")" "$output_dir" "$device") || return 1
      [[ -n "$package" ]] || return 1
      [[ -f "$package" ]] || return 1
      log_success "TWRP package: $package"
      ;;
    *)
      log_error "Unknown output format: $output_format"
      return 1
      ;;
  esac
}

prepare_vbmeta_artifacts() {
  local firmware_dir="$1"
  local partitions_dir="$2"
  local output_dir="$WORK_DIR/output"

  mkdir -p "$output_dir"

  local input_vbmeta input_vbmeta_system
  input_vbmeta=$(find "$firmware_dir" -maxdepth 2 -type f \( -name "vbmeta.img" -o -name "vbmeta.img.lz4" \) | head -n 1 || true)
  input_vbmeta_system=$(find "$firmware_dir" -maxdepth 2 -type f \( -name "vbmeta_system.img" -o -name "vbmeta_system.img.lz4" \) | head -n 1 || true)
  local output_vbmeta="$output_dir/vbmeta.img"
  local output_vbmeta_system="$output_dir/vbmeta_system.img"
  local input_vbmeta_raw=""
  local input_vbmeta_system_raw=""

  if [[ -n "$input_vbmeta" ]] && [[ -f "$input_vbmeta" ]]; then
    if [[ "$input_vbmeta" == *.lz4 ]]; then
      input_vbmeta_raw="$output_dir/vbmeta.input.img"
      lz4 -d -f "$input_vbmeta" "$input_vbmeta_raw" >/dev/null || {
        log_warn "Failed to decompress vbmeta.img.lz4; AVB patch skipped for vbmeta"
        input_vbmeta_raw=""
      }
    else
      input_vbmeta_raw="$input_vbmeta"
    fi
  fi

  if [[ -n "$input_vbmeta_system" ]] && [[ -f "$input_vbmeta_system" ]]; then
    if [[ "$input_vbmeta_system" == *.lz4 ]]; then
      input_vbmeta_system_raw="$output_dir/vbmeta_system.input.img"
      lz4 -d -f "$input_vbmeta_system" "$input_vbmeta_system_raw" >/dev/null || {
        log_warn "Failed to decompress vbmeta_system.img.lz4; AVB patch skipped for vbmeta_system"
        input_vbmeta_system_raw=""
      }
    else
      input_vbmeta_system_raw="$input_vbmeta_system"
    fi
  fi

  if [[ -n "$input_vbmeta_raw" ]] && [[ -f "$input_vbmeta_raw" ]] && command -v avbtool &>/dev/null; then
    log_info "=== Step 8: Patching vbmeta ==="
    disable_avb "$input_vbmeta_raw" "$output_vbmeta" || {
      log_warn "Failed to patch vbmeta. Using original vbmeta if available."
      output_vbmeta="$input_vbmeta"
    }
  elif [[ -n "$input_vbmeta_raw" ]] && [[ -f "$input_vbmeta_raw" ]]; then
    log_warn "avbtool not available. Using original vbmeta.img"
    output_vbmeta="$input_vbmeta"
  else
    log_warn "No vbmeta.img found in firmware payload"
    output_vbmeta=""
  fi

  if [[ -n "$output_vbmeta" ]] && [[ "$output_vbmeta" != *.lz4 ]]; then
    patch_vbmeta_for_partitions "$output_vbmeta" "$partitions_dir" "$output_dir/vbmeta_patched.img" || true
  fi

  if [[ -n "$input_vbmeta_system_raw" ]] && [[ -f "$input_vbmeta_system_raw" ]] && command -v avbtool &>/dev/null; then
    log_info "=== Step 8: Patching vbmeta_system ==="
    disable_avb "$input_vbmeta_system_raw" "$output_vbmeta_system" || {
      log_warn "Failed to patch vbmeta_system. Keeping original vbmeta_system.img."
    }
  elif [[ -n "$input_vbmeta_system_raw" ]] && [[ -f "$input_vbmeta_system_raw" ]]; then
    log_warn "avbtool not available. Keeping original vbmeta_system.img."
  else
    log_warn "No vbmeta_system.img found in firmware payload"
  fi

  echo "$output_vbmeta"
}

clean_work_dir() {
  log_info "Cleaning work directory..."
  mkdir -p "$WORK_DIR"

  if ! find "$WORK_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null; then
    if command -v sudo >/dev/null 2>&1; then
      log_warn "Regular cleanup failed (likely root-owned files). Retrying with sudo..."
      sudo find "$WORK_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
      sudo chown -R "$(id -u):$(id -g)" "$WORK_DIR" || true
    else
      log_error "Failed to clean work directory and sudo is unavailable"
      return 1
    fi
  fi

  log_info "Work directory cleaned"
}

clean_work_dir_path() {
  local target_dir="$1"
  if [[ -z "$target_dir" ]]; then
    return 1
  fi

  log_info "Cleaning target: $target_dir"
  WORK_DIR="$target_dir"
  clean_work_dir
}

umount_mount_tree() {
  local target_dir="$1"
  local mount_dir="$target_dir/mount"

  if [[ ! -d "$mount_dir" ]]; then
    return 0
  fi

  local m
  for m in "$mount_dir"/*; do
    [[ -d "$m" ]] || continue
    if mountpoint -q "$m" 2>/dev/null; then
      log_info "Unmounting: $m"
      sudo umount "$m" || log_warn "Failed to unmount: $m"
    fi
  done
}

handle_clean_command() {
  local target_device=""
  local all="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        target_device="$2"
        shift 2
        ;;
      --all)
        all="true"
        shift
        ;;
      --help)
        usage
        ;;
      *)
        log_error "Unknown option for clean: $1"
        usage
        ;;
    esac
  done

  if [[ "$all" == "true" ]]; then
    local d
    for d in "$BASE_WORK_DIR"/*; do
      [[ -d "$d" ]] || continue
      umount_mount_tree "$d" || true
      clean_work_dir_path "$d" || exit 1
    done
    # Remove empty legacy/work subdirectories after cleaning.
    find "$BASE_WORK_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    return 0
  fi

  if [[ -z "$target_device" ]]; then
    log_warn "No device specified for clean; defaulting to --all"
    handle_clean_command --all
    return 0
  fi

  target_device=$(normalize_device_alias "$target_device")
  local target_dir="$BASE_WORK_DIR/$target_device"
  mkdir -p "$target_dir"
  umount_mount_tree "$target_dir" || true
  clean_work_dir_path "$target_dir" || exit 1
}

handle_umount_command() {
  local target_device=""
  local all="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device)
        target_device="$2"
        shift 2
        ;;
      --all)
        all="true"
        shift
        ;;
      --help)
        usage
        ;;
      *)
        log_error "Unknown option for umount: $1"
        usage
        ;;
    esac
  done

  # Also unmount manual mount helper mount base if present.
  if [[ -d "/tmp/rom_builder_mount" ]]; then
    local mm
    for mm in /tmp/rom_builder_mount/*; do
      [[ -d "$mm" ]] || continue
      if mountpoint -q "$mm" 2>/dev/null; then
        log_info "Unmounting manual mount: $mm"
        sudo umount "$mm" || log_warn "Failed to unmount manual mount: $mm"
      fi
    done
  fi

  if [[ "$all" == "true" ]]; then
    local d
    for d in "$BASE_WORK_DIR"/*; do
      [[ -d "$d" ]] || continue
      umount_mount_tree "$d" || true
    done
    return 0
  fi

  if [[ -z "$target_device" ]]; then
    log_warn "No device specified for umount; defaulting to --all"
    handle_umount_command --all
    return 0
  fi

  target_device=$(normalize_device_alias "$target_device")
  umount_mount_tree "$BASE_WORK_DIR/$target_device" || true
}

resume_firmware_artifacts() {
  local firmware_dir="$WORK_DIR/extracted/firmware"
  if [[ ! -d "$firmware_dir" ]]; then
    return 1
  fi

  verify_firmware_structure "$firmware_dir" || return 1

  local super_img
  super_img=$(find_super_image "$firmware_dir") || return 1

  echo "$firmware_dir|$super_img"
}

resume_partitions_artifacts() {
  local partitions_dir="$WORK_DIR/super/partitions"
  if [[ ! -d "$partitions_dir" ]]; then
    return 1
  fi

  if ! find "$partitions_dir" -maxdepth 1 -type f -name "*.img" | grep -q .; then
    return 1
  fi

  echo "$partitions_dir"
}

main() {
  if [[ $# -eq 0 ]] || [[ "$1" == "--help" ]]; then
    usage
  fi
  
  local command="$1"
  shift
  
  local device=""
  local region=""
  local profile="lite"
  local input=""
  local output="odin"
  local verbose="false"
  local clean="false"
  local resume="false"
  local setup_tools="false"
  local keep_mounts="false"
  
  case "$command" in
    build)
      ;;
    clean)
      handle_clean_command "$@"
      exit 0
      ;;
    umount)
      handle_umount_command "$@"
      exit 0
      ;;
    *)
      log_error "Unknown command: $command"
      usage
      ;;
  esac
  
  while [[ $# -gt 0 ]]; do
    case $1 in
      --device)
        device="$2"
        shift 2
        ;;
      --region)
        region="$2"
        shift 2
        ;;
      --profile)
        profile="$2"
        shift 2
        ;;
      --input)
        input="$2"
        shift 2
        ;;
      --output)
        output="$2"
        shift 2
        ;;
      --verbose)
        verbose="true"
        set_log_level "DEBUG"
        shift
        ;;
      --clean)
        clean="true"
        shift
        ;;
      --resume)
        resume="true"
        shift
        ;;
      --setup-tools)
        setup_tools="true"
        shift
        ;;
      --keep-mounts)
        keep_mounts="true"
        shift
        ;;
      --help)
        usage
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        ;;
    esac
  done
  
  if [[ -z "$device" ]] || [[ -z "$input" ]]; then
    log_error "Missing required arguments"
    usage
  fi

  local original_device="$device"
  device=$(normalize_device_alias "$device")
  if [[ "$original_device" != "$device" ]]; then
    log_info "Device alias resolved: $original_device -> $device"
  fi

  WORK_DIR="$BASE_WORK_DIR/$device"
  mkdir -p "$WORK_DIR"

  if is_remote_input "$input" && [[ -z "$region" ]]; then
    log_error "--region is required when --input is a URL or 'auto'"
    usage
  fi
  
  if [[ "$clean" == "true" ]]; then
    if [[ "$resume" == "true" ]]; then
      log_warn "--clean and --resume were both provided; clean takes precedence."
      resume="false"
    fi
    clean_work_dir
  fi
  
  if [[ "$setup_tools" == "true" ]]; then
    if [[ -f "$TOOLS_DIR/setup.sh" ]]; then
      log_info "Running tools setup..."
      "$TOOLS_DIR/setup.sh" || exit 1
    else
      log_error "Setup script not found: $TOOLS_DIR/setup.sh"
      exit 1
    fi
  fi
  
  log_info "=========================================="
  log_info "ROM Builder - Starting Build Process"
  log_info "=========================================="
  log_info "Device: $device | Profile: $profile | Output: $output"
  log_info "Input: $input"
  if [[ -n "$region" ]]; then
    log_info "Region: $region"
  fi
  log_info "=========================================="
  
  validate_prerequisites
  local config_file
  config_file=$(parse_device_config "$device")
  resolve_device_metadata "$device" "$config_file"

  local firmware_info
  local partitions_dir=""
  local firmware_dir=""
  local super_img=""

  if [[ "$resume" == "true" ]]; then
    if partitions_dir=$(resume_partitions_artifacts); then
      log_info "Resuming from existing extracted partitions: $partitions_dir"
      if firmware_info=$(resume_firmware_artifacts); then
        firmware_dir="${firmware_info%|*}"
        super_img="${firmware_info#*|}"
      fi
    else
      log_info "Resume requested but partition artifacts missing; checking firmware artifacts..."
      if firmware_info=$(resume_firmware_artifacts); then
        firmware_dir="${firmware_info%|*}"
        super_img="${firmware_info#*|}"
        log_info "Resuming from existing firmware artifacts: $firmware_dir"
        partitions_dir=$(extract_super_partitions_step "$super_img") || exit 1
      else
        log_warn "Resume artifacts not found. Falling back to full extraction."
      fi
    fi
  fi

  if [[ -z "$firmware_dir" ]] || [[ -z "$super_img" ]]; then
    local resolved_input
    resolved_input=$(prepare_firmware_input "$input" "$device" "$region") || exit 1

    firmware_info=$(extract_firmware "$resolved_input") || exit 1
    firmware_dir="${firmware_info%|*}"
    super_img="${firmware_info#*|}"
  fi

  if [[ -z "$partitions_dir" ]]; then
    partitions_dir=$(extract_super_partitions_step "$super_img") || exit 1
  fi
  
  mount_and_apply_patches "$partitions_dir" "$config_file" "$profile" "$device" "$keep_mounts" || exit 1

  repack_erofs_partitions "$MOUNT_DIR" "$partitions_dir" || exit 1

  local rebuilt_super
  rebuilt_super=$(rebuild_partitions_and_super "$partitions_dir" "$config_file" "$super_img") || exit 1
  
  local vbmeta_img
  vbmeta_img=$(prepare_vbmeta_artifacts "$firmware_dir" "$partitions_dir") || exit 1

  create_output_package "$rebuilt_super" "$output" "$BUILD_OUTPUT_NAME" "$vbmeta_img" "$firmware_dir" "$config_file" "$WORK_DIR/output" || exit 1
  create_shareable_7z_bundle "$BUILD_OUTPUT_NAME"
  
  log_info "=========================================="
  log_success "Build completed successfully!"
  log_info "Output directory: $WORK_DIR/final"
  log_info "=========================================="
}

main "$@"
