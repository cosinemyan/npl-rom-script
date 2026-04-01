#!/bin/bash
# Module Utilities - High-level APK patch helpers
# Adapted from UN1CA's scripts/utils/module_utils.sh

# decode_apk <partition> <apk_path>
# Idempotent decode: skip if already decoded
decode_apk() {
  local partition="$1"
  local apk_path="$2"

  while [[ "${apk_path:0:1}" == "/" ]]; do
    apk_path="${apk_path:1}"
  done

  local apk_name
  apk_name=$(basename "$apk_path")
  local decoded_dir="$APKTOOL_DIR/$partition/${apk_path%/*}/$apk_name"

  if [[ -d "$decoded_dir" ]] && [[ -f "$decoded_dir/apktool.yml" ]]; then
    log_verbose "Already decoded: $apk_name"
    return 0
  fi

  apktool_decode "$partition" "$apk_path" >/dev/null || return 1
}

# inject_smali_files <decoded_apk_dir> <module_smali_dir>
# Copy smali files from module into decoded APK directory
inject_smali_files() {
  local decoded_dir="$1"
  local module_dir="$2"

  if [[ ! -d "$module_dir" ]]; then
    log_warn "Module smali directory not found: $module_dir"
    return 0
  fi

  local count=0
  while IFS= read -r -d '' smali_file; do
    local rel_path="${smali_file#$module_dir/}"
    local target="$decoded_dir/$rel_path"

    log_verbose "  Injecting smali: $rel_path"
    mkdir -p "$(dirname "$target")"
    cp -a "$smali_file" "$target"
    ((count++))
  done < <(find "$module_dir" -type f -name "*.smali" -print0 | sort -z)

  log_info "Injected $count smali file(s)"
}

# inject_resources <decoded_apk_dir> <module_res_dir>
# Copy resources (XML, drawable, layout) from module into decoded APK.
# For XML files that already exist, patches them using the first-line instruction pattern.
inject_resources() {
  local decoded_dir="$1"
  local module_dir="$2"

  if [[ ! -d "$module_dir" ]]; then
    log_warn "Module resource directory not found: $module_dir"
    return 0
  fi

  local count=0
  while IFS= read -r -d '' res_file; do
    local rel_path="${res_file#$module_dir/}"
    local target="$decoded_dir/$rel_path"

    # Skip smali files — those are handled by inject_smali_files
    if [[ "$rel_path" == *".smali" ]]; then
      continue
    fi

    if [[ ! -f "$target" ]] || [[ "$rel_path" != *".xml" ]]; then
      # New file or non-XML — just copy
      log_verbose "  Adding: $rel_path"
      mkdir -p "$(dirname "$target")"
      cp -a "$res_file" "$target"
      ((count++))
    elif [[ "$rel_path" == *"res/values"* ]]; then
      # Existing values XML — merge content before </resources>, idempotently
      log_verbose "  Merging: $rel_path"
      # Extract new resource entries from the module file (skip XML header and <resources>)
      local new_entries
      new_entries=$(sed -e '/<?xml/d' -e '/<resources>/d' -e '/<\/resources>/d' "$res_file")
      # Insert entries before </resources>, skipping entries that already exist
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Extract the resource name attribute to check for duplicates
        local res_name
        res_name=$(echo "$line" | grep -oP 'name="[^"]*"' | head -1)
        if [[ -n "$res_name" ]] && grep -qF "$res_name" "$target"; then
          log_verbose "    Skipping duplicate: $res_name"
          continue
        fi
        # Insert before </resources>
        sed -i "/<\/resources>/i\\$line" "$target"
      done <<< "$new_entries"
      ((count++))
    else
      # Other existing XML — check if module file is a fragment (no XML header)
      # If so, inject content into the target file; otherwise overwrite
      if ! head -1 "$res_file" | grep -q '<?xml'; then
        # Fragment file — inject each line before the closing root tag
        log_verbose "  Injecting into: $rel_path"
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          # Skip if the line's key/identifier already exists in the target
          local line_key
          line_key=$(echo "$line" | grep -oP '(?:android:key|android:name)="[^"]*"' | head -1)
          if [[ -n "$line_key" ]] && grep -qF "$line_key" "$target"; then
            log_verbose "    Skipping duplicate: $line_key"
            continue
          fi
          # Insert before the last closing tag (</PreferenceScreen>, </ScrollView>, etc.)
          sed -i "$(grep -n '</' "$target" | tail -1 | cut -d: -f1)s|^|$line\n|" "$target"
        done < "$res_file"
      else
        # Full XML file — overwrite
        log_verbose "  Overwriting: $rel_path"
        cp -a "$res_file" "$target"
      fi
      ((count++))
    fi
  done < <(find "$module_dir" -type f -print0 | sort -z)

  log_info "Injected $count resource file(s)"
}

# apply_module <module_dir> [partition]
# Main entry point: applies a module's customize.sh against the build
apply_module() {
  local module_dir="$1"
  local module_name
  module_name=$(basename "$module_dir")
  local customize_script="$module_dir/customize.sh"

  if [[ ! -f "$customize_script" ]]; then
    log_warn "Module has no customize.sh: $module_name"
    return 0
  fi

  log_info "Applying module: $module_name"

  # Capture and disable ALL strict-mode flags FIRST, before any exports.
  # set -u (nounset) and set -o pipefail cause silent exits when variables
  # or pipelines fail — even during export of readonly variables.
  local _prev_opts
  _prev_opts=$(set +o)
  set +eou pipefail

  # Export variables for the customize script
  export MODULE_DIR="$module_dir"
  export APKTOOL_DIR="${APKTOOL_DIR:-}"
  export WORK_DIR="${WORK_DIR:-}"
  export MOUNT_DIR="${MOUNT_DIR:-}"
  # TOOLS_DIR and PROJECT_ROOT are readonly in main.sh — already in scope
  export PROJECT_ROOT="$PROJECT_ROOT" 2>/dev/null || true

  # Source the module's customize script
  local _module_rc=0
  # shellcheck disable=SC1090
  source "$customize_script"
  _module_rc=$?

  eval "$_prev_opts"            # restore previous shell options

  if [[ $_module_rc -ne 0 ]]; then
    log_error "Module failed (exit $_module_rc): $module_name"
    return 1
  fi

  log_info "Module applied: $module_name"

  # If we got here, the module succeeded — check if any signal killed a
  # subprocess.  This is a no-op for the normal case; the real protection
  # is the set +e above.  The silent-exit the user observed was most likely
  # the OOM killer terminating the Java/apktool process, which causes the
  # background wait in run_with_progress to return non-zero, then set -e
  # kills the whole script before the || handler in the sourced script can
  # catch it.  With set +e now active, that path is prevented.
}

# apply_all_modules <modules_dir> [enabled_modules...]
# Apply all (or specified) modules from a directory
apply_all_modules() {
  local modules_dir="$1"
  shift
  local -a enabled_modules=("$@")

  if [[ ! -d "$modules_dir" ]]; then
    log_verbose "No modules directory: $modules_dir"
    return 0
  fi

  # If no modules specified, apply all
  if [[ ${#enabled_modules[@]} -eq 0 ]]; then
    local module_dir
    for module_dir in "$modules_dir"/*/; do
      [[ -d "$module_dir" ]] || continue
      apply_module "$module_dir" || {
        log_warn "Module failed, continuing: $(basename "$module_dir")"
      }
    done
  else
    local mod
    for mod in "${enabled_modules[@]}"; do
      local module_dir="$modules_dir/$mod"
      if [[ ! -d "$module_dir" ]]; then
        log_warn "Module not found: $mod"
        continue
      fi
      apply_module "$module_dir" || {
        log_warn "Module failed: $mod"
      }
    done
  fi
}

# apply_apk_modules <comma_separated_modules>
# Entry point called from cli/main.sh build pipeline.
# Parses comma-separated module list, validates apktool, then delegates to apply_all_modules.
apply_apk_modules() {
  local modules_csv="${1:-}"

  # Skip entirely if no modules requested
  if [[ -z "$modules_csv" ]]; then
    log_verbose "No APK modules to apply"
    return 0
  fi

  # Skip if apktool is not available
  if ! command -v apktool &>/dev/null; then
    log_warn "apktool not found; skipping APK module application"
    log_warn "Install with: ./tools/setup.sh --tool apktool"
    return 0
  fi

  log_info "=== Step 4.5: Applying APK Modules ==="

  # Ensure APKTOOL_DIR is set
  export APKTOOL_DIR="${APKTOOL_DIR:-$WORK_DIR/apktool}"

  # Parse comma-separated list into array
  local -a module_list=()
  local IFS=','
  read -ra module_list <<< "$modules_csv"

  apply_all_modules "$MODULES_DIR" "${module_list[@]}"

  log_info "APK module application complete"
}
