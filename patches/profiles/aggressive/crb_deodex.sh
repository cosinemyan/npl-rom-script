#!/bin/bash
# CRB Kitchen - Deodex (aggressive profile)
# Source: CRB Kitchen deodex(), adapted for rom-builder
# Applies to: system partition mount point

crb_deodex() {
  local mp="$1"  # mount point (work/mount/system)

  log_info "[CRB] Deodex: removing pre-compiled OAT/ODEX/VDEX files from system..."

  # Framework compiled dirs
  rm -rf "$mp/system/framework/arm"  2>/dev/null || true
  rm -rf "$mp/system/framework/arm64" 2>/dev/null || true
  rm -rf "$mp/system/framework/oat"  2>/dev/null || true

  # Boot framework vdex files
  local vdex_files=(
    boot-apache-xml boot-bouncycastle boot-core-icu4j boot-core-libart
    boot-esecomm boot-ext boot-framework-adservices boot-framework-graphics
    boot-framework-location boot-framework-nfc
    boot-framework-ondeviceintelligence-platform
    boot-framework-platformcrashrecovery boot-framework boot-ims-common
    boot-knoxsdk boot-okhttp boot-QPerformance boot-tcmiface
    boot-telephony-common boot-telephony-ext boot-UxPerformance boot
    boot-voip-common
  )
  for f in "${vdex_files[@]}"; do
    rm -f "$mp/system/framework/${f}.vdex" 2>/dev/null || true
  done

  # OAT dirs under app/priv-app (compiled art/odex from on-device dexopt)
  find "$mp/system/app"      -mindepth 2 -maxdepth 2 -type d -name "oat" -exec rm -rf {} + 2>/dev/null || true
  find "$mp/system/priv-app" -mindepth 2 -maxdepth 2 -type d -name "oat" -exec rm -rf {} + 2>/dev/null || true

  # Services odex/art/vdex
  rm -f "$mp/system/framework/oat/arm64/services.art"  2>/dev/null || true
  rm -f "$mp/system/framework/oat/arm64/services.odex" 2>/dev/null || true
  rm -f "$mp/system/framework/oat/arm64/services.vdex" 2>/dev/null || true

  log_info "[CRB] Deodex complete"
}
