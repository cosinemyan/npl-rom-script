#!/bin/bash
# CRB Kitchen - S23 Build.prop tweaks (Unica-style Surgical Patching)
# Source: CRB Kitchen BUILDPROP and modsystem() build.prop section
# Refined for partition-specific surgical patching.

crb_build_prop() {
  local mp="$1"  # partition mount point
  local partition_name
  partition_name=$(basename "$mp")

  # Find the prop file (can be in /build.prop, /system/build.prop, or /etc/build.prop)
  local buildprop=""
  local candidates=(
    "$mp/build.prop"
    "$mp/system/build.prop"
    "$mp/etc/build.prop"
  )

  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      buildprop="$c"
      break
    fi
  done

  if [[ -z "$buildprop" ]]; then
    log_warn "[Surgical Prop] No build.prop found in $partition_name partition ($mp)"
    return 0
  fi

  log_info "[Surgical Prop] Patching $partition_name: $(basename "$buildprop")"

  # ── 1. System-specific Identity & Security ──────────────────────────────
  if [[ "$partition_name" == "system" ]]; then
    set_prop_value "$buildprop" "ro.build.display.id" "NPL ROM"
    set_prop_value "$buildprop" "ro.config.iccc_version" "iccc_disabled"
    set_prop_value "$buildprop" "ro.config.dmverity" "false"
    set_prop_value "$buildprop" "ro.security.vaultkeeper.feature" "0"

    # Performance/quality tweaks (idempotent block)
    if ! grep -q "##CRB_TWEAKS##" "$buildprop"; then
      cat >> "$buildprop" <<'EOF'
##CRB_TWEAKS##
ring.delay=0
ro.media.enc.jpeg.quality=100
ro.securestorage.support=false
ro.telephony.call_ring.delay=0
wlan.wfd.hdcp=disable
ro.crypto.state=encrypted
wifi.supplicant_scan_interval=120
ro.HOME_APP_ADJ=1
persist.adb.notify=0
persist.service.adb.enable=1
persist.service.debuggable=1
ro.boot.flash.locked=1
ro.config.hw_fast_dormancy=1
ro.config.hw_quickpoweron=true
EOF
      log_info "[Surgical Prop] Performance tweaks appended to system"
    fi
  fi

}
