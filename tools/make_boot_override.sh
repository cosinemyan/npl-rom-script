#!/bin/bash
# Build full boot.img.lz4 override from stock AP boot + custom kernel.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat << 'EOF'
Usage:
  make_boot_override.sh --ap-archive AP.tar.md5 --kernel /path/to/kernel [options]
  make_boot_override.sh --stock-boot /path/to/boot.img(.lz4) --kernel /path/to/kernel [options]

Required:
  --kernel PATH              Custom kernel blob to inject.
  One of:
    --ap-archive PATH        AP archive containing boot.img.lz4 or boot.img.
    --stock-boot PATH        Direct stock boot image (raw or .lz4).

Options:
  --out PATH                 Output boot.img.lz4 path (default: ./boot.img.lz4)
  --install-dir DIR          Also copy output to DIR/boot.img.lz4
  --magiskboot PATH          Path to magiskboot binary
  --lz4 PATH                 Path to lz4 binary
  --work-dir DIR             Reuse a working directory instead of temporary dir
  --keep-work                Keep temporary working directory
  -h, --help                 Show this help

Environment:
  MAGISKBOOT=/path/to/magiskboot
  LZ4=/path/to/lz4
EOF
}

log() {
  printf '[boot-override] %s\n' "$*"
}

die() {
  printf '[boot-override] ERROR: %s\n' "$*" >&2
  exit 1
}

resolve_tool() {
  local explicit="${1:-}"
  local name="$2"

  if [[ -n "$explicit" ]]; then
    [[ -x "$explicit" ]] || die "$name is not executable: $explicit"
    echo "$explicit"
    return 0
  fi

  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi

  if [[ -x "$PROJECT_ROOT/tools/bin/$name" ]]; then
    echo "$PROJECT_ROOT/tools/bin/$name"
    return 0
  fi

  die "Missing tool: $name (set --$name or add to PATH)"
}

extract_boot_from_ap() {
  local ap_archive="$1"
  local lz4_bin="$2"
  local out_raw="$3"
  local temp_lz4="$4"

  if tar -xOf "$ap_archive" boot.img.lz4 > "$temp_lz4" 2>/dev/null; then
    "$lz4_bin" -d -f "$temp_lz4" "$out_raw" >/dev/null
    return 0
  fi

  if tar -xOf "$ap_archive" boot.img > "$out_raw" 2>/dev/null; then
    return 0
  fi

  return 1
}

main() {
  local ap_archive=""
  local stock_boot=""
  local custom_kernel=""
  local out_path="$PWD/boot.img.lz4"
  local install_dir=""
  local magiskboot_bin="${MAGISKBOOT:-}"
  local lz4_bin="${LZ4:-}"
  local work_dir=""
  local keep_work="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ap-archive)
        ap_archive="$2"
        shift 2
        ;;
      --stock-boot)
        stock_boot="$2"
        shift 2
        ;;
      --kernel)
        custom_kernel="$2"
        shift 2
        ;;
      --out)
        out_path="$2"
        shift 2
        ;;
      --install-dir)
        install_dir="$2"
        shift 2
        ;;
      --magiskboot)
        magiskboot_bin="$2"
        shift 2
        ;;
      --lz4)
        lz4_bin="$2"
        shift 2
        ;;
      --work-dir)
        work_dir="$2"
        shift 2
        ;;
      --keep-work)
        keep_work="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done

  [[ -n "$custom_kernel" ]] || die "--kernel is required"
  [[ -f "$custom_kernel" ]] || die "Custom kernel not found: $custom_kernel"

  if [[ -n "$ap_archive" && -n "$stock_boot" ]]; then
    die "Use only one of --ap-archive or --stock-boot"
  fi
  if [[ -z "$ap_archive" && -z "$stock_boot" ]]; then
    die "One of --ap-archive or --stock-boot is required"
  fi

  if [[ -n "$ap_archive" ]]; then
    [[ -f "$ap_archive" ]] || die "AP archive not found: $ap_archive"
  fi
  if [[ -n "$stock_boot" ]]; then
    [[ -f "$stock_boot" ]] || die "Stock boot not found: $stock_boot"
  fi

  magiskboot_bin="$(resolve_tool "$magiskboot_bin" "magiskboot")"
  lz4_bin="$(resolve_tool "$lz4_bin" "lz4")"

  local created_work_dir="false"
  if [[ -z "$work_dir" ]]; then
    work_dir="$(mktemp -d /tmp/rom_builder_boot_XXXXXX)"
    created_work_dir="true"
  else
    mkdir -p "$work_dir"
  fi

  if [[ "$created_work_dir" == "true" && "$keep_work" != "true" ]]; then
    trap "rm -rf '$work_dir'" EXIT
  fi

  mkdir -p "$work_dir"
  local stock_raw="$work_dir/boot-stock.img"
  local stock_lz4="$work_dir/boot-stock.img.lz4"
  local repack_out="$work_dir/boot-custom.img"
  local repack_dir="$work_dir/repack"

  if [[ -n "$ap_archive" ]]; then
    log "Extracting stock boot from AP archive"
    extract_boot_from_ap "$ap_archive" "$lz4_bin" "$stock_raw" "$stock_lz4" \
      || die "Failed to extract boot.img(.lz4) from: $ap_archive"
  else
    if [[ "$stock_boot" == *.lz4 ]]; then
      log "Decompressing stock boot.lz4"
      "$lz4_bin" -d -f "$stock_boot" "$stock_raw" >/dev/null
    else
      cp -f "$stock_boot" "$stock_raw"
    fi
  fi

  [[ -s "$stock_raw" ]] || die "Stock boot image is empty"

  rm -rf "$repack_dir"
  mkdir -p "$repack_dir"
  cp -f "$stock_raw" "$repack_dir/boot.img"

  (
    cd "$repack_dir" || exit 1
    log "Unpacking stock boot with magiskboot"
    "$magiskboot_bin" unpack boot.img >/dev/null

    kernel_target=""
    candidate=""
    for candidate in kernel kernel_dtb zImage Image; do
      if [[ -f "$candidate" ]]; then
        kernel_target="$candidate"
        break
      fi
    done

    [[ -n "$kernel_target" ]] || die "magiskboot unpack did not produce a kernel blob file"

    log "Replacing kernel blob: $kernel_target"
    cp -f "$custom_kernel" "$kernel_target"

    log "Repacking boot image"
    "$magiskboot_bin" repack boot.img "$repack_out" >/dev/null
  )

  [[ -s "$repack_out" ]] || die "Repacked boot image is missing/empty"

  # Samsung Odin requires the SEANDROIDENFORCE footer on boot images.
  printf 'SEANDROIDENFORCE' >> "$repack_out"
  log "Appended SEANDROIDENFORCE footer"

  local stock_size new_size
  stock_size=$(stat -c%s "$stock_raw")
  new_size=$(stat -c%s "$repack_out")
  if [[ "$new_size" -gt "$stock_size" ]]; then
    die "Repacked boot is larger than stock ($new_size > $stock_size)"
  fi
  if [[ "$new_size" -lt "$stock_size" ]]; then
    truncate -s "$stock_size" "$repack_out"
    log "Padded repacked boot to stock size: $stock_size bytes"
  fi

  mkdir -p "$(dirname "$out_path")"
  log "Compressing output to boot.img.lz4"
  "$lz4_bin" -B4 --content-size -f "$repack_out" "$out_path" >/dev/null
  [[ -s "$out_path" ]] || die "Output file is missing/empty: $out_path"
  log "Created: $out_path"

  if [[ -n "$install_dir" ]]; then
    mkdir -p "$install_dir"
    cp -f "$out_path" "$install_dir/boot.img.lz4"
    log "Installed override: $install_dir/boot.img.lz4"
  fi

  if [[ "$keep_work" == "true" ]]; then
    log "Work directory kept at: $work_dir"
  fi
}

main "$@"
