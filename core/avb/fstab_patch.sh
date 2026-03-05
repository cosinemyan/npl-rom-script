#!/bin/bash
# FSTAB Patching - Modify fstab for device-specific changes

_fstab_log_action() {
  local message="$1"
  if [[ -n "${PATCH_ACTION_LOG:-}" ]]; then
    printf '%s %s\n' "[$(date '+%Y-%m-%d %H:%M:%S')]" "$message" >> "$PATCH_ACTION_LOG"
  fi
}

_fstab_log_diff() {
  local before_file="$1"
  local after_file="$2"
  local path="$3"
  local variant="$4"

  local old_sha new_sha
  old_sha=$(sha256sum "$before_file" | awk '{print $1}')
  new_sha=$(sha256sum "$after_file" | awk '{print $1}')

  if [[ "$old_sha" == "$new_sha" ]]; then
    _fstab_log_action "FSTAB_NOOP path=$path variant=$variant"
    return 0
  fi

  local removed_count added_count
  removed_count=$(diff -u "$before_file" "$after_file" | grep -E '^-([^ -]|$)' | grep -vc '^---' || true)
  added_count=$(diff -u "$before_file" "$after_file" | grep -E '^\+([^ +]|$)' | grep -vc '^\+\+\+' || true)
  _fstab_log_action "FSTAB_CHANGED path=$path variant=$variant removed=${removed_count} added=${added_count}"

  # Log exact changed lines for easier debugging/tracking in patch_actions.log.
  diff -u "$before_file" "$after_file" \
    | grep -E '^[+-]' \
    | grep -vE '^(\+\+\+|---)' \
    | while IFS= read -r line; do
        escaped=$(printf "%s" "$line" | sed "s/'/'\"'\"'/g")
        _fstab_log_action "FSTAB_DIFF path=$path variant=$variant line='${escaped}'"
      done
}

patch_fstab() {
  local mount_point="$1"
  local device_config="$2"

  log_info "Patching fstab..."

  local fstab_file
  fstab_file=$(find "$mount_point" -maxdepth 4 -name "fstab.*" ! -name "*.ramplus" | head -n 1)

  if [[ -z "$fstab_file" ]]; then
    log_verbose "fstab not found, skipping"
    return 0
  fi

  log_info "Found fstab: $fstab_file"

  local fstab_name
  fstab_name=$(basename "$fstab_file")
  local before_tmp
  before_tmp=$(mktemp)
  cp "$fstab_file" "$before_tmp"

  case "$fstab_name" in
    fstab.qcom)
      _patch_fstab_qcom "$fstab_file"
      ;;
    fstab.exynos9820|fstab.exynos9825|fstab.exynos990)
      _patch_fstab_exynos_s10 "$fstab_file"
      ;;
    fstab.s5e9925)
      _patch_fstab_exynos_s22 "$fstab_file"
      ;;
    fstab.exynos2100)
      _patch_fstab_exynos_s21 "$fstab_file"
      ;;
    *)
      log_warn "Unknown fstab variant: $fstab_name — applying generic AVB strip"
      _patch_fstab_generic "$fstab_file"
      ;;
  esac

  _fstab_log_diff "$before_tmp" "$fstab_file" "$fstab_file" "$fstab_name"
  rm -f "$before_tmp"
  log_info "fstab patched: $fstab_file"
}

# Full Qualcomm fstab decrypt (S23 / SM8550)
_patch_fstab_qcom() {
  local f="$1"
  log_info "Applying Qualcomm fstab decrypt..."

  # Strip all avb-related options: avb, avb=..., avb_keys=..., first_stage_mount_keys=...
  sed -i -E 's/,?avb(=[^,[:space:]]*)?,?//g; s/,?avb_keys=[^,[:space:]]+,?//g' "$f"
  sed -i -E 's/,?first_stage_mount_keys=[^,[:space:]]+,?//g' "$f"

  # Convert fileencryption to encryptable.
  sed -i -E 's/fileencryption=[^,[:space:]]+/encryptable/g' "$f"

  # Remove encryption-related metadata tokens.
  sed -i -E 's/,?(metadata_encryption|keydirectory)=[^,[:space:]]+,?//g' "$f"

  # Strip tech-specific flags (can be standalone or concatenated with +)
  # Handle standalone in column 4 or 5
  sed -i -E 's/,?(inlinecrypt_optimized|inlinecrypt|wrappedkey_v0|wrappedkey),?//g' "$f"
  # Handle concatenated with +
  sed -i -E 's/\+(inlinecrypt_optimized|inlinecrypt|wrappedkey_v0|wrappedkey)//g' "$f"
  sed -i -E 's/(inlinecrypt_optimized|inlinecrypt|wrappedkey_v0|wrappedkey)\+//g' "$f"

  # Normalize system flags
  sed -i 's/formattable_system/formattable/g' "$f"
  sed -i 's/first_stage_mount_system/first_stage_mount/g' "$f"

  # Final cleanup of stray/double commas and trailing whitespace/commas
  sed -i -E 's/,,+/,/g; s/,[[:space:]]*$//g; s/^[[:space:]]*,//g' "$f"
  # Special case: if we removed a token and left a comma before the next field (whitespace)
  sed -i -E 's/,[[:space:]]+/ /g' "$f"
}

# Exynos 9820/9825/990 (S10/S20)
_patch_fstab_exynos_s10() {
  local f="$1"
  sed -i 's/fileencryption=ice/encryptable=ice/g' "$f"
  sed -i 's/avb,//g; s/avb=vbmeta,//g' "$f"
  sed -i 's/,avb_keys=\/avb\/[^[:space:]]*//g' "$f"
}

# Exynos S5E9925 (S22)
_patch_fstab_exynos_s22() {
  local f="$1"
  sed -i 's/fileencryption=ice/encryptable=ice/g' "$f"
  sed -i -E 's/fileencryption=aes-256-xts:[^,[:space:]]+/encryptable=ice/g' "$f"
  sed -i 's/metadata_encryption=aes-256-xts:wrappedkey_v0,//g' "$f"
  sed -i 's/,avb,/,/g; s/,avb=boot//g; s/,avb=vbmeta//g; s/,avb=dtbo//g' "$f"
  sed -i 's/,avb=vendor_boot//g; s/,avb=vbmeta_system//g' "$f"
  sed -i 's/,formattable_system/,formattable/g' "$f"
  sed -i 's/first_stage_mount_system/first_stage_mount/g' "$f"
  sed -i 's/,avb_keys=\/avb\/[^[:space:]]*//g' "$f"
}

# Exynos 2100 (S21)
_patch_fstab_exynos_s21() {
  local f="$1"
  sed -i -E 's/fileencryption=aes-256-xts:[^,[:space:]]+/encryptable=ice/g' "$f"
  sed -i 's/avb,//g; s/avb=vbmeta,//g' "$f"
  sed -i 's/,avb_keys=\/avb\/[^[:space:]]*//g' "$f"
}

# Generic: strip all AVB tokens
_patch_fstab_generic() {
  local f="$1"
  sed -i -E 's/,?avb(=[^,[:space:]]*)?//g' "$f"
  sed -i -E 's/,?avb_keys=[^,[:space:]]+//g' "$f"
  sed -i -E 's/fileencryption=[^,[:space:]]+/encryptable/g' "$f"
  sed -i -E 's/,,+/,/g' "$f"
}

patch_init_rc() {
  local mount_point="$1"
  local service_name="$2"
  local action="${3:-disable}"

  log_info "Patching init.rc for service: $service_name"

  local rc_file
  rc_file=$(find "$mount_point" -name "*.rc" | grep -E "(init\.|vendor\.|odm\.)" | head -n 1)

  if [[ -z "$rc_file" ]]; then
    log_verbose "No init.rc found"
    return 0
  fi

  case "$action" in
    disable)
      log_verbose "Disabling service: $service_name"
      sed -i -E "s/^([[:space:]]*)start[[:space:]]+$service_name([[:space:]]*)$/\1# disabled by rom-builder: start $service_name\2/g" "$rc_file"
      ;;
    enable)
      log_verbose "Enabling service: $service_name"
      sed -i -E "s/^([[:space:]]*)# disabled by rom-builder: start[[:space:]]+$service_name([[:space:]]*)$/\1start $service_name\2/g" "$rc_file"
      ;;
  esac
}
