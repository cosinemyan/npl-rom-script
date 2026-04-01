#!/bin/bash
# NPL Settings Module - Customize Script
# Injects NPL ROM Settings fragment into Samsung SecSettings.apk

NPL_PARTITION="system"
NPL_APK="system/priv-app/SecSettings/SecSettings.apk"
NPL_MOD_DIR="$MODULE_DIR/SecSettings.apk"

# Decode SecSettings.apk
log_info "Decoding SecSettings.apk..."
decode_apk "$NPL_PARTITION" "$NPL_APK" || {
  log_error "Failed to decode SecSettings.apk"
  return 1
}

local decoded_dir="$APKTOOL_DIR/$NPL_PARTITION/${NPL_APK%/*}/$(basename "$NPL_APK")"

# Inject NPL smali files
log_info "Injecting NPL smali files..."
inject_smali_files "$decoded_dir" "$NPL_MOD_DIR" || {
  log_error "Failed to inject NPL smali files"
  return 1
}

# Inject NPL resources (XML, drawables, layout)
log_info "Injecting NPL resources..."
inject_resources "$decoded_dir" "$NPL_MOD_DIR" || {
  log_error "Failed to inject NPL resources"
  return 1
}

# Register NPL Settings fragment in SettingsGateway (dynamic array extension)
log_info "Registering NPL Settings in SettingsGateway..."
local gateway_path
gateway_path=$(find "$decoded_dir" -path "*/gateway/SettingsGateway.smali" -type f 2>/dev/null | head -1)
if [[ -n "$gateway_path" ]]; then
  gateway_path="${gateway_path#$decoded_dir/}"

  # Dynamically find the filled-new-array register range in <clinit>
  local array_match
  array_match=$(grep -oP 'filled-new-array/range \{v\d+ \.\. v(\d+)\}' "$decoded_dir/$gateway_path" | tail -1)
  local last_reg
  last_reg=$(echo "$array_match" | grep -oP 'v(\d+)\}' | grep -oP '\d+' | tail -1)

  if [[ -n "$last_reg" ]]; then
    local next_reg=$((last_reg + 1))
    local old_array="filled-new-array/range {v1 .. v$last_reg}, [Ljava/lang/String;"
    local new_array="    const-string v$next_reg, \"io.npl.rom.settings.NPLSettingsFragment\"

    filled-new-array/range {v1 .. v$next_reg}, [Ljava/lang/String;"

    smali_patch "$NPL_PARTITION" "$NPL_APK" \
      "$gateway_path" "replace" \
      '<clinit>()V' \
      "$old_array" \
      "$new_array" \
      || log_warn "Failed to patch SettingsGateway (array size may differ)"
  else
    log_warn "Could not detect array size in SettingsGateway — skipping"
  fi
else
  log_warn "SettingsGateway.smali not found — skipping registration"
fi

# Update isValidFragment array size dynamically
log_info "Updating isValidFragment array size..."
local settings_activity_path
settings_activity_path=$(find "$decoded_dir" -path "*/settings/SettingsActivity.smali" -type f 2>/dev/null | head -1)
if [[ -n "$settings_activity_path" ]]; then
  settings_activity_path="${settings_activity_path#$decoded_dir/}"

  # Find the current array size const in isValidFragment
  local cur_size
  cur_size=$(awk '/^\.method.*isValidFragment/,/^\.end method/' "$decoded_dir/$settings_activity_path" \
    | grep -oP 'const/16 v\d+, 0x[0-9a-f]+' | head -1)

  if [[ -n "$cur_size" ]]; then
    local cur_hex
    cur_hex=$(echo "$cur_size" | grep -oP '0x[0-9a-f]+')
    local cur_dec=$((cur_hex))
    local new_dec=$((cur_dec + 1))
    local new_hex
    new_hex=$(printf '0x%x' "$new_dec")
    local cur_reg
    cur_reg=$(echo "$cur_size" | grep -oP 'v\d+')

    local old_size="const/16 $cur_reg, $cur_hex"
    local new_size="const/16 $cur_reg, $new_hex"

    smali_patch "$NPL_PARTITION" "$NPL_APK" \
      "$settings_activity_path" "replace" \
      'isValidFragment(Ljava/lang/String;)Z' \
      "$old_size" \
      "$new_size" \
      || log_warn "Failed to patch isValidFragment (array size may differ)"
  else
    log_warn "Could not detect array size in isValidFragment — skipping"
  fi
else
  log_warn "SettingsActivity.smali not found — skipping isValidFragment patch"
fi

# Rebuild SecSettings.apk
log_info "Rebuilding SecSettings.apk..."
apktool_build "$NPL_PARTITION" "$NPL_APK" || {
  log_error "Failed to rebuild SecSettings.apk"
  return 1
}

log_info "NPL Settings module applied successfully"
