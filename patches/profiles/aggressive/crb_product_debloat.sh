#!/bin/bash
# CRB Kitchen - Product/Prism Debloat (aggressive profile)
# Source: CRB Kitchen debloatPPV(), adapted for rom-builder
# Applies to: product partition mount point

crb_product_debloat() {
  local mp="$1"  # mount point (work/mount/product)
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local list_file="$script_dir/product_debloat.list"

  log_info "[CRB] Product/Prism debloat: removing Google apps and bloat..."

  if [[ ! -f "$list_file" ]]; then
    log_warn "Product debloat list not found: $list_file"
  else
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^#.*$ ]] && continue
      [[ -z "$line" ]] && continue
      rm -rf "$mp/$line" 2>/dev/null || true
    done < "$list_file"
  fi

  # ── Google deodex oat dirs ────────────────────────────────────────────────
  find "$mp/app"      -mindepth 2 -maxdepth 2 -type d -name "oat" -exec rm -rf {} + 2>/dev/null || true
  find "$mp/priv-app" -mindepth 2 -maxdepth 2 -type d -name "oat" -exec rm -rf {} + 2>/dev/null || true

  log_info "[CRB] Product debloat complete"
}
