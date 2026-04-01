#!/bin/bash
# Multiuser - Enable multi-user support on Samsung phones
# Adapted from UN1CA's unica/mods/multiuser
#
# Patches MultiUserSupportsHelper.smali in framework.jar to force:
#   IS_TABLET=true, DEFAULT_MAX_USERS=8, DEFAULT_ENABLE_STATUS=true

log_info "Enabling multi-user support"

# Decode framework.jar
decode_apk "system" "system/framework/framework.jar" || {
  log_warn "Failed to decode framework.jar — skipping multiuser patch"
  return 0
}

# Locate the decoded directory
local fw_decoded="$APKTOOL_DIR/system/system/framework/framework.jar"

if [[ ! -d "$fw_decoded" ]]; then
  log_warn "framework.jar decoded directory not found: $fw_decoded"
  return 0
fi

# Find MultiUserSupportsHelper.smali — can be in smali_classes6/, smali/, etc.
local helper_smali
helper_smali=$(find "$fw_decoded" -type f -name "MultiUserSupportsHelper.smali" | head -n 1 || true)

if [[ -z "$helper_smali" ]]; then
  log_warn "MultiUserSupportsHelper.smali not found in framework.jar — skipping multiuser patch"
  return 0
fi

log_info "Found: ${helper_smali#$fw_decoded/}"

# Try applying the diff patch first, fallback to direct awk replacement
local patch_file="$MODULE_DIR/framework.jar/0001-Enable-multi-user-support.patch"
if [[ -f "$patch_file" ]]; then
  # Adjust the smali_classes path in the patch to match actual location
  local rel_path="${helper_smali#$fw_decoded/}"
  local patched=false

  # Create an adapted patch with the correct smali path
  local adapted_patch
  adapted_patch=$(mktemp)
  sed "s|smali_classes6/com/samsung/android/core/pm/multiuser/MultiUserSupportsHelper.smali|${rel_path}|g" \
    "$patch_file" > "$adapted_patch"

  if (cd "$fw_decoded" && patch -p1 --no-backup-if-mismatch -r - < "$adapted_patch") >/dev/null 2>&1; then
    log_info "Multi-user patch applied via diff"
    patched=true
  fi
  rm -f "$adapted_patch"

  if [[ "$patched" == "true" ]]; then
    return 0
  fi
fi

# Fallback: direct awk replacement of <clinit>
log_verbose "Diff patch didn't apply, using direct smali replacement"

local tmp
tmp=$(mktemp)

awk '
/^\.method.*static.*constructor.*<clinit>/ { in_clinit=1; print; next }
in_clinit && /^\.end method/ {
  in_clinit=0
  print "    .locals 2"
  print ""
  print "    const/4 v0, 0x1"
  print ""
  print "    sput-boolean v0, Lcom/samsung/android/core/pm/multiuser/MultiUserSupportsHelper;->IS_TABLET:Z"
  print ""
  print "    const/16 v1, 0x8"
  print ""
  print "    sput v1, Lcom/samsung/android/core/pm/multiuser/MultiUserSupportsHelper;->DEFAULT_MAX_USERS:I"
  print ""
  print "    sput-boolean v0, Lcom/samsung/android/core/pm/multiuser/MultiUserSupportsHelper;->DEFAULT_ENABLE_STATUS:Z"
  print ""
  print "    return-void"
  print ""
  print ".end method"
  next
}
!in_clinit { print }
' "$helper_smali" > "$tmp" && mv "$tmp" "$helper_smali"

log_info "Multi-user support enabled"
