#!/bin/bash
# Patch Engine - Apply patches in a modular, data-driven way
# Supports: replace_line, append, delete, replace_file, regex, shell_script

_partition_from_mount_point() {
  local mount_point="$1"
  basename "$mount_point"
}

_path_target_partition() {
  local path="$1"
  local first="${path%%/*}"
  case "$first" in
    system|vendor|product|odm|system_ext|prism|optics)
      echo "$first"
      ;;
    *)
      echo ""
      ;;
  esac
}

_patch_targets_current_partition() {
  local mount_point="$1"
  local patch_path="$2"
  local partition_name
  partition_name=$(_partition_from_mount_point "$mount_point")
  local target_partition
  target_partition=$(_path_target_partition "$patch_path")

  if [[ -z "$target_partition" ]]; then
    return 0
  fi

  [[ "$target_partition" == "$partition_name" ]]
}

resolve_patch_path() {
  local mount_point="$1"
  local raw_path="$2"
  local partition_name
  partition_name=$(_partition_from_mount_point "$mount_point")

  local full_path="$mount_point/$raw_path"
  if [[ -e "$full_path" ]]; then
    echo "$full_path"
    return 0
  fi

  if [[ "$raw_path" == "$partition_name/"* ]]; then
    local stripped="${raw_path#"$partition_name/"}"
    full_path="$mount_point/$stripped"
    if [[ -e "$full_path" ]]; then
      echo "$full_path"
      return 0
    fi
  fi

  echo "$mount_point/$raw_path"
}

_script_matches_partition() {
  local script_name="$1"
  local partition_name="$2"

  case "$script_name" in
    *system*)
      [[ "$partition_name" == "system" ]]
      ;;
    *vendor*)
      [[ "$partition_name" == "vendor" ]]
      ;;
    *product*|*prism*|*csc*)
      [[ "$partition_name" == "product" ]]
      ;;
    *odm*)
      [[ "$partition_name" == "odm" ]]
      ;;
    *)
      return 0
      ;;
  esac
}

log_patch_action() {
  local message="$1"
  case "$message" in
    DELETE\ *|DELETE_SKIP\ *|FS_DELETED\ *|FS_NEW\ *)
      return 0
      ;;
  esac
  if [[ -n "${PATCH_ACTION_LOG:-}" ]]; then
    printf '%s %s\n' "[$(date '+%Y-%m-%d %H:%M:%S')]" "$message" >> "$PATCH_ACTION_LOG"
  fi
}

apply_patch_line() {
  local file="$1"
  local match="$2"
  local replace="$3"

  log_verbose "Patching line in: $file"

  if [[ ! -f "$file" ]]; then
    log_error "File not found: $file"
    log_patch_action "ERROR replace_line file_missing path=$file match=$match replace=$replace"
    return 1
  fi

  local before_line=""
  before_line=$(grep -m1 -E "$match" "$file" 2>/dev/null || true)
  sed -i "s|$match|$replace|g" "$file"
  local after_line=""
  after_line=$(grep -m1 -F "$replace" "$file" 2>/dev/null || true)
  log_patch_action "REPLACE_LINE path=$file match=$match replace=$replace before='${before_line}' after='${after_line}'"
}

append_to_file() {
  local file="$1"
  local content="$2"

  log_verbose "Appending to: $file"

  mkdir -p "$(dirname "$file")"
  echo "$content" >> "$file"
  log_patch_action "APPEND path=$file content='${content}'"
}

delete_file() {
  local target="$1"
  local mount_point="$2"

  log_info "Deleting: $target"

  local full_path="$mount_point/$target"

  if [[ -e "$full_path" ]]; then
    rm -rf "$full_path"
    log_patch_action "DELETE path=$full_path"
  else
    log_patch_action "DELETE_SKIP path=$full_path reason=not_found"
  fi
}

replace_file() {
  local target="$1"
  local source="$2"
  local mount_point="$3"

  log_info "Replacing: $target"

  local full_path="$mount_point/$target"
  local full_source=""

  if [[ -f "$source" ]]; then
    full_source="$source"
  elif [[ -n "${PROJECT_ROOT:-}" ]] && [[ -f "$PROJECT_ROOT/$source" ]]; then
    full_source="$PROJECT_ROOT/$source"
  elif [[ -f "$mount_point/../$source" ]]; then
    full_source="$mount_point/../$source"
  fi

  if [[ -z "$full_source" ]]; then
    log_error "Source file not found for replace_file patch: $source"
    log_patch_action "ERROR replace_file source_missing target=$target source=$source"
    return 1
  fi

  mkdir -p "$(dirname "$full_path")"
  cp "$full_source" "$full_path"
  log_patch_action "REPLACE_FILE target=$full_path source=$full_source"
}

regex_replace() {
  local file="$1"
  local pattern="$2"
  local replacement="$3"

  log_verbose "Regex replace in: $file"

  if [[ ! -f "$file" ]]; then
    log_error "File not found: $file"
    log_patch_action "ERROR regex file_missing path=$file pattern=$pattern replacement=$replacement"
    return 1
  fi

  sed -i -E "s|$pattern|$replacement|g" "$file"
  log_patch_action "REGEX path=$file pattern=$pattern replacement=$replacement"
}

# Surgical property patching: replace value if exists, append if missing.
# Usage: set_prop_value "/path/to/build.prop" "ro.build.display.id" "NPL ROM"
set_prop_value() {
  local prop_file="$1"
  local key="$2"
  local value="$3"
  local delimiter="${4:-=}"

  if [[ ! -f "$prop_file" ]]; then
    log_warn "Property file not found: $prop_file"
    log_patch_action "PROP_SKIP file_missing path=$prop_file key=$key value=$value"
    return 1
  fi

  # Escape special characters for sed
  local escaped_key=$(echo "$key" | sed 's/[^^]/[&]/g; s/\^/\\^/g')
  local escaped_value=$(echo "$value" | sed 's/[&/\]/\\&/g')

  local old_line=""
  old_line=$(grep -m1 "^${escaped_key}${delimiter}" "$prop_file" 2>/dev/null || true)

  if grep -q "^${escaped_key}${delimiter}" "$prop_file"; then
    log_verbose "Updating prop: $key -> $value"
    sed -i "s|^${escaped_key}${delimiter}.*|${key}${delimiter}${value}|" "$prop_file"
    log_patch_action "PROP_UPDATE path=$prop_file key=$key old='${old_line}' new='${key}${delimiter}${value}'"
  else
    log_verbose "Adding prop: $key -> $value"
    echo "${key}${delimiter}${value}" >> "$prop_file"
    log_patch_action "PROP_ADD path=$prop_file key=$key new='${key}${delimiter}${value}'"
  fi
}

# Run a shell script patch.
# The script is sourced and a function with the same name as the script
# (basename without .sh) is called with the mount_point as $1.
apply_shell_script() {
  local script_path="$1"
  local mount_point="$2"

  if [[ ! -f "$script_path" ]]; then
    log_error "Shell script patch not found: $script_path"
    return 1
  fi

  log_info "Running shell-script patch: $(basename "$script_path")"

  # Source the script to get its functions into scope
  # shellcheck disable=SC1090
  source "$script_path"

  # Derive function name from filename (strip path + .sh)
  local fn_name
  fn_name=$(basename "$script_path" .sh)

  if declare -F "$fn_name" > /dev/null; then
    "$fn_name" "$mount_point"
  else
    log_error "Expected function '$fn_name' not found in $script_path"
    return 1
  fi
}

parse_patch_file() {
  local patch_file="$1"

  log_verbose "Parsing patch: $patch_file"

  local type="" target="" file="" match="" replace="" content="" source=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      type:*)    type="${line#type: }"    ;;
      target:*)  target="${line#target: }" ;;
      file:*)    file="${line#file: }"   ;;
      match:*)   match="${line#match: }"  ;;
      replace:*) replace="${line#replace: }" ;;
      content:*) content="${line#content: }" ;;
      source:*)  source="${line#source: }" ;;
    esac
  done < "$patch_file"

  echo "$type|$target|$file|$match|$replace|$content|$source"
}

apply_patch() {
  local patch_file="$1"
  local mount_point="$2"

  log_info "Applying patch: $(basename "$patch_file")"

  local patch_data
  patch_data=$(parse_patch_file "$patch_file")

  IFS='|' read -r type target file match replace content source <<< "$patch_data"

  local scope_path=""
  case "$type" in
    delete|replace_file) scope_path="$target" ;;
    replace_line|append|regex) scope_path="$file" ;;
  esac

  if [[ -n "$scope_path" ]] && ! _patch_targets_current_partition "$mount_point" "$scope_path"; then
    log_verbose "Skipping patch $(basename "$patch_file") for mount $(basename "$mount_point"): target=$scope_path"
    return 0
  fi

  case "$type" in
    delete)
      delete_file "$target" "$mount_point"
      ;;
    replace_file)
      replace_file "$target" "$source" "$mount_point"
      ;;
    replace_line)
      local full_file
      full_file=$(resolve_patch_path "$mount_point" "$file")
      apply_patch_line "$full_file" "$match" "$replace"
      ;;
    append)
      local full_file
      full_file=$(resolve_patch_path "$mount_point" "$file")
      append_to_file "$full_file" "$content"
      ;;
    regex)
      local full_file
      full_file=$(resolve_patch_path "$mount_point" "$file")
      regex_replace "$full_file" "$match" "$replace"
      ;;
    *)
      log_error "Unknown patch type: $type"
      return 1
      ;;
  esac
}

# Apply all .patch files AND .sh shell-script patches from a directory
apply_patches_from_dir() {
  local patches_dir="$1"
  local mount_point="$2"
  local partition_name
  partition_name=$(_partition_from_mount_point "$mount_point")

  if [[ ! -d "$patches_dir" ]]; then
    log_verbose "Patch directory not found: $patches_dir"
    return 0
  fi

  log_info "Applying patches from: $patches_dir"

  local patch_count=0

  # .patch descriptor files
  for patch_file in "$patches_dir"/*.patch; do
    if [[ -f "$patch_file" ]]; then
      apply_patch "$patch_file" "$mount_point"
      (( patch_count++ ))
    fi
  done

  # .sh shell-script patches
  for script_file in "$patches_dir"/*.sh; do
    if [[ -f "$script_file" ]]; then
      local script_name
      script_name=$(basename "$script_file")
      if ! _script_matches_partition "$script_name" "$partition_name"; then
        log_verbose "Skipping shell-script patch $script_name for partition $partition_name"
        continue
      fi
      apply_shell_script "$script_file" "$mount_point"
      (( patch_count++ ))
    fi
  done

  log_info "Applied $patch_count patches from $(basename "$patches_dir")"
}

resolve_device_patch_dirs() {
  local device="$1"
  local config_file="${2:-}"
  local -a dirs=()
  local family="" variant=""

  if [[ -n "$config_file" ]] && [[ -f "$config_file" ]]; then
    family=$(parse_yaml_value "$config_file" "family" || true)
    variant=$(parse_yaml_value "$config_file" "variant" || true)

    if [[ -z "$variant" ]]; then
      variant="$(basename "$(dirname "$config_file")")"
    fi
    if [[ -z "$family" ]]; then
      local config_parent
      config_parent="$(basename "$(dirname "$(dirname "$config_file")")")"
      if [[ "$config_parent" != "devices" ]]; then
        family="$config_parent"
      fi
    fi
  fi

  if [[ -n "$family" ]]; then
    dirs+=("$DEVICES_DIR/$family/patches")
  fi
  if [[ -n "$family" ]] && [[ -n "$variant" ]]; then
    dirs+=("$DEVICES_DIR/$family/$variant/patches")
  fi
  dirs+=("$DEVICES_DIR/$device/patches")

  local -A seen=()
  local d
  for d in "${dirs[@]}"; do
    [[ -n "$d" ]] || continue
    if [[ -z "${seen["$d"]+x}" ]]; then
      echo "$d"
      seen["$d"]=1
    fi
  done
}

apply_patch_profile() {
  local profile="$1"
  local mount_point="$2"
  local device="$3"
  local config_file="${4:-}"

  local -a profiles_to_apply=()
  case "$profile" in
    all|both|full)
      profiles_to_apply=(lite aggressive)
      ;;
    *)
      profiles_to_apply=("$profile")
      ;;
  esac

  log_info "Applying patch profile(s): ${profiles_to_apply[*]}"

  log_info "Step 1: Applying global patches"
  apply_patches_from_dir "$PATCHES_DIR/global" "$mount_point"

  log_info "Step 2: Applying profile patches"
  local p
  for p in "${profiles_to_apply[@]}"; do
    apply_patches_from_dir "$PATCHES_DIR/profiles/$p" "$mount_point"
  done

  log_info "Step 3: Applying device-specific patches"
  local patch_dir
  while IFS= read -r patch_dir; do
    [[ -n "$patch_dir" ]] || continue
    apply_patches_from_dir "$patch_dir" "$mount_point"
  done < <(resolve_device_patch_dirs "$device" "$config_file")

  log_info "All patches applied"
}
