#!/bin/bash
# KnoxPatch - Set of Knox bypasses for custom ROM
# Adapted from UN1CA's unica/mods/knoxpatch
#
# Standalone subset (no deknox dependency required):
#   1. System property changes (ICCC, WFD HDCP)
#   2. Delete WSM libraries
#   3. Bypass integrity verification (isVerifiableIntegrity → true)
#   4. Hide root status (isRootedDevice → false)
#
# Deferred (requires deknox integration):
#   - KnoxPatchHooks injection (framework.jar + knoxsdk.jar)
#   - ICD verification bypass (AttestParameterSpec signature change)
#   - SAK disable in DarManagerService
#   - KmxService.apk spoofing
#   - KnoxGuard disable

log_info "Applying KnoxPatch module"

# ── 1. System property changes ──────────────────────────────────────────

local prop_file="$MOUNT_DIR/system/system/build.prop"
if [[ -f "$prop_file" ]]; then
  log_verbose "Patching system properties for Knox bypass"
  # Remove ICCC prop
  if grep -q "^ro.config.iccc_version=" "$prop_file" 2>/dev/null; then
    sed -i "s/^ro.config.iccc_version=.*/ro.config.iccc_version=/" "$prop_file"
  else
    echo "ro.config.iccc_version=" >> "$prop_file"
  fi
  # Disable HDCP in WFD
  if ! grep -q "^wlan.wfd.hdcp=" "$prop_file" 2>/dev/null; then
    echo "wlan.wfd.hdcp=disable" >> "$prop_file"
  fi
fi

# ── 2. Delete WSM (Samsung Wallet Security Module) ──────────────────────

local wsm_files=(
  "system/etc/public.libraries-wsm.samsung.txt"
  "system/lib/libhal.wsm.samsung.so"
  "system/lib/vendor.samsung.hardware.security.wsm.service-V1-ndk.so"
  "system/lib64/libhal.wsm.samsung.so"
  "system/lib64/vendor.samsung.hardware.security.wsm.service-V1-ndk.so"
)

local mount_system="$MOUNT_DIR/system"
for f in "${wsm_files[@]}"; do
  local target="$mount_system/$f"
  if [[ -f "$target" ]]; then
    rm -f "$target"
    log_verbose "Removed WSM: $f"
  fi
done

# ── 3. Bypass integrity verification ────────────────────────────────────
# samsungkeystoreutils.jar — isVerifiableIntegrity()Z → return true

log_verbose "Patching samsungkeystoreutils.jar"
decode_apk "system" "system/framework/samsungkeystoreutils.jar" 2>/dev/null || true

local keystore_decoded="$APKTOOL_DIR/system/system/framework/samsungkeystoreutils.jar"
if [[ -d "$keystore_decoded" ]]; then
  local attest_spec
  attest_spec=$(find "$keystore_decoded" -type f -name "AttestParameterSpec.smali" | head -n 1 || true)
  if [[ -n "$attest_spec" ]]; then
    smali_patch "system" "system/framework/samsungkeystoreutils.jar" \
      "${attest_spec#$keystore_decoded/}" \
      "return" \
      "isVerifiableIntegrity()Z" \
      "true" 2>/dev/null || log_verbose "isVerifiableIntegrity patch skipped"
  fi
fi

# ── 4. Hide root status ─────────────────────────────────────────────────
# services.jar — isRootedDevice()Z → return false

log_verbose "Patching services.jar"
decode_apk "system" "system/framework/services.jar" 2>/dev/null || true

local services_decoded="$APKTOOL_DIR/system/system/framework/services.jar"
if [[ -d "$services_decoded" ]]; then
  local storage_mgr
  storage_mgr=$(find "$services_decoded" -type f -name "StorageManagerService.smali" | head -n 1 || true)
  if [[ -n "$storage_mgr" ]]; then
    smali_patch "system" "system/framework/services.jar" \
      "${storage_mgr#$services_decoded/}" \
      "return" \
      "isRootedDevice()Z" \
      "false" 2>/dev/null || log_verbose "isRootedDevice patch skipped"
  fi
fi

log_info "KnoxPatch applied (standalone subset)"
