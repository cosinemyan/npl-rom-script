#!/bin/bash
# CRB Kitchen - Vendor Partition Mods (lite profile)
# Source: CRB Kitchen modvendor(), adapted for rom-builder
# Applies to: vendor partition mount point

crb_vendor_mods() {
  local mp="$1"   # mount point (work/mount/vendor)
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local list_file="$script_dir/vendor_debloat.list"

  log_info "[CRB] Vendor mods: disabling services and removing bloat..."

  if [[ ! -f "$list_file" ]]; then
    log_warn "Vendor debloat list not found: $list_file"
  else
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^#.*$ ]] && continue
      [[ -z "$line" ]] && continue
      rm -rf "$mp/$line" 2>/dev/null || true
    done < "$list_file"
  fi

  # ── CASS ──────────────────────────────────────────────────────────────────
  local cass="$mp/etc/init/cass.rc"
  if [[ -f "$cass" ]]; then
    sed -i 's/start cass/stop cass/g' "$cass"
    log_info "[CRB] CASS disabled"
  fi

  # ── PROCA (S23/S22 use qsee, others use teegris) ─────────────────────────
  local proca_q="$mp/etc/init/pa_daemon_qsee.rc"
  local proca_t="$mp/etc/init/pa_daemon_teegris.rc"
  if [[ -f "$proca_q" ]]; then
    sed -i 's/start proca/stop proca/g' "$proca_q"
    log_info "[CRB] PROCA (qsee) disabled"
  fi
  if [[ -f "$proca_t" ]]; then
    sed -i 's/start proca/stop proca/g' "$proca_t"
    log_info "[CRB] PROCA (teegris) disabled"
  fi

  # ── Vaultkeeper ───────────────────────────────────────────────────────────
  local vault="$mp/etc/init/vaultkeeper_common.rc"
  if [[ -f "$vault" ]]; then
    sed -i 's/start vaultkeeper/stop vaultkeeper/g' "$vault"
    log_info "[CRB] Vaultkeeper disabled"
  fi

  log_info "[CRB] Vendor mods complete"
}
