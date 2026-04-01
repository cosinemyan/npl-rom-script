#!/bin/bash
# Outdoor Mode - Enable Outdoor mode toggle in Samsung Display Settings
# Adapted from UN1CA's unica/mods/outdoor/customize.sh

log_info "Enabling Outdoor mode in SecSettings"

local apk_path="system/priv-app/SecSettings/SecSettings.apk"
local decoded_dir="$APKTOOL_DIR/system/${apk_path%/*}/$(basename "$apk_path")"

# Find the actual smali path — Samsung moves classes between dex splits across firmware versions
local smali_file
smali_file=$(find "$decoded_dir" -name "SecOutDoorModePreferenceController.smali" -type f 2>/dev/null | head -1)

if [[ -z "$smali_file" ]]; then
  log_warn "SecOutDoorModePreferenceController.smali not found — skipping outdoor mode"
  return 0
fi

smali_file="${smali_file#$decoded_dir/}"

smali_patch "system" "$apk_path" \
  "$smali_file" \
  "return" \
  "isAvailable()Z" \
  "true" || {
  log_warn "Outdoor mode patch failed"
  return 0
}
