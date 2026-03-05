#!/bin/bash
# Easy interactive build launcher for general users.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_ROOT/cli/main.sh"
FW_ROOT="${FW_ROOT:-$PROJECT_ROOT/firmware}"

normalize_device_alias() {
  case "$1" in
    s23) echo "dm1q" ;;
    s23plus) echo "dm2q" ;;
    s23ultra) echo "dm3q" ;;
    *) echo "$1" ;;
  esac
}

pick_from_list() {
  local prompt="$1"
  shift
  local -a values=("$@")
  local i=1
  echo "$prompt" >&2
  for v in "${values[@]}"; do
    echo "  [$i] $v" >&2
    i=$((i + 1))
  done
  echo -n "Select number: " >&2
  if ! read -r idx; then
    echo "No input received." >&2
    exit 1
  fi
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || [[ "$idx" -lt 1 ]] || [[ "$idx" -gt "${#values[@]}" ]]; then
    echo "Invalid selection." >&2
    exit 1
  fi
  echo "${values[$((idx - 1))]}"
}

discover_firmware_files() {
  local device="$1"
  local -a files=()

  if [[ -d "$FW_ROOT/$device" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$FW_ROOT/$device" -maxdepth 1 -type f \( -name "*.zip" -o -name "*.7z" -o -name "*.tar.md5" \) | sort)
  fi

  if [[ ${#files[@]} -eq 0 ]] && [[ -d "$FW_ROOT" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$FW_ROOT" -maxdepth 1 -type f \( -name "*${device}*.zip" -o -name "*${device}*.7z" -o -name "*${device}*.tar.md5" \) | sort)
  fi

  printf '%s\n' "${files[@]}"
}

main() {
  if [[ ! -x "$CLI" ]]; then
    echo "CLI not found or not executable: $CLI"
    exit 1
  fi

  local device profile output keep_mounts
  device=$(pick_from_list "Choose device:" dm1q dm2q dm3q)
  profile="${EASY_PROFILE:-all}"
  output=$(pick_from_list "Choose output format:" odin twrp)
  keep_mounts=$(pick_from_list "Keep mounts after patching?" "yes" "no")

  local -a fw_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && fw_files+=("$f")
  done < <(discover_firmware_files "$device")

  if [[ ${#fw_files[@]} -eq 0 ]]; then
    echo "No firmware files found for $device."
    echo "Expected locations:"
    echo "  $FW_ROOT/$device/"
    echo "  or $FW_ROOT with filename containing '$device'"
    exit 1
  fi

  local input_fw
  input_fw=$(pick_from_list "Choose firmware file:" "${fw_files[@]}")

  echo "Using patch profile: $profile" >&2

  local -a cmd=("$CLI" build --clean --device "$device" --profile "$profile" --input "$input_fw" --output "$output")
  if [[ "$keep_mounts" == "yes" ]]; then
    cmd+=(--keep-mounts)
  fi

  echo ""
  echo "Running:"
  printf ' %q' "${cmd[@]}"
  echo ""
  echo ""
  "${cmd[@]}"
}

main "$@"
