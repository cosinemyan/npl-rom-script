#!/bin/bash
# S23 Device Hooks
# Runs CRB patches via device_custom_patches

# Source CRB patch scripts
_S23_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

device_pre_patch() {
  local mount_point="$1"
  log_info "[S23] Pre-patch hook: $mount_point"
}

device_post_patch() {
  local mount_point="$1"
  log_info "[S23] Post-patch hook: fixing permissions in $mount_point"

  # Fix world-readable permissions on app dirs
  find "$mount_point/system/app"      -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "$mount_point/system/app"      -type f -exec chmod 644 {} \; 2>/dev/null || true
  find "$mount_point/system/priv-app" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "$mount_point/system/priv-app" -type f -exec chmod 644 {} \; 2>/dev/null || true
}

device_custom_patches() {
  local mount_point="$1"
  local partition_name
  partition_name=$(basename "$mount_point")

  # Patch scripts are already executed by patch_engine.
  # Keep this hook for future device-only custom logic to avoid duplicate runs.
  log_verbose "[S23] Custom patch hook noop for partition: $partition_name"
}
