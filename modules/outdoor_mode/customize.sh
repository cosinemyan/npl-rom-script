#!/bin/bash
# Outdoor Mode - Enable Outdoor mode toggle in Samsung Display Settings
# Adapted from UN1CA's unica/mods/outdoor/customize.sh

log_info "Enabling Outdoor mode in SecSettings"

smali_patch "system" "system/priv-app/SecSettings/SecSettings.apk" \
  "smali_classes4/com/samsung/android/settings/display/controller/SecOutDoorModePreferenceController.smali" \
  "return" \
  "isAvailable()Z" \
  "true" || {
  log_warn "Outdoor mode patch failed — smali class path may differ on this firmware"
  return 0
}
