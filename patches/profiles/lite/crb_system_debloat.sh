#!/bin/bash
# CRB Kitchen - System Partition Debloat (lite profile)
# Source: CRB Kitchen script by ZONALRIPPER, adapted for rom-builder
# Applies to: system partition mount point

crb_system_debloat() {
  local mp="$1"  # mount point (work/mount/system OR extracted dir)
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local list_file="$script_dir/system_debloat.list"

  log_info "[CRB] System debloat: removing Samsung bloatware..."

  if [[ ! -f "$list_file" ]]; then
    log_error "Debloat list not found: $list_file"
    return 1
  fi

  local removed=0 skipped=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue

    local target="$mp/$line"
    if [[ -e "$target" ]]; then
      log_verbose "Removing: $line"
      rm -rf "$target" && (( removed++ )) || true
    else
      (( skipped++ ))
    fi
  done < "$list_file"

  # Special handle for patterns (find)
  find "$mp/system/tts/lang_SMT" -maxdepth 1 -name "vdata_de_DE*" -exec rm -rf {} + 2>/dev/null || true
  find "$mp/system/tts/lang_SMT" -maxdepth 1 -name "vdata_en_GB*" -exec rm -rf {} + 2>/dev/null || true
  find "$mp/system/tts/lang_SMT" -maxdepth 1 -name "vdata_es_*"   -exec rm -rf {} + 2>/dev/null || true
  find "$mp/system/tts/lang_SMT" -maxdepth 1 -name "vdata_fr_FR*" -exec rm -rf {} + 2>/dev/null || true
  find "$mp/system/tts/lang_SMT" -maxdepth 1 -name "vdata_it_IT*" -exec rm -rf {} + 2>/dev/null || true
  find "$mp/system/tts/lang_SMT" -maxdepth 1 -name "vdata_pt_BR*" -exec rm -rf {} + 2>/dev/null || true
  find "$mp/system/tts/lang_SMT" -maxdepth 1 -name "vdata_ru_RU*" -exec rm -rf {} + 2>/dev/null || true
  find "$mp/system/priv-app" -maxdepth 1 -name "SOAgent*" -exec rm -rf {} + 2>/dev/null || true

  log_info "[CRB] System debloat complete: removed=$removed, not_found=$skipped"
}
