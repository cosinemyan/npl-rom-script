#!/bin/bash

vendor_identity() {
  local mp="$1"
  local partition_name
  partition_name=$(basename "$mp")

  if [[ "$partition_name" != "vendor" ]]; then
    return 0
  fi

  local buildprop=""
  local candidates=(
    "$mp/build.prop"
    "$mp/vendor/build.prop"
    "$mp/etc/build.prop"
  )

  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      buildprop="$c"
      break
    fi
  done

  if [[ -z "$buildprop" ]]; then
    log_warn "[Surgical Prop] No vendor build.prop found under $mp"
    return 0
  fi

  set_prop_value "$buildprop" "ro.product.vendor.device" "dm1qxxx"
  log_info "[Surgical Prop] vendor.device prop updated to dm1qxxx"
}
