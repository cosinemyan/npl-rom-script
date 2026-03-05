#!/bin/bash
# Device payload overlay for dm3q.
# Place files under: devices/dmqxxx/dm3q/patches/payload/<partition>/...

_fix_payload_perms() {
  local path="$1"

  [[ -e "$path" ]] || return 0

  if [[ -d "$path" ]]; then
    find "$path" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$path" -type f -exec chmod 644 {} \; 2>/dev/null || true
    find "$path" -type f \( -path '*/bin/*' -o -path '*/xbin/*' -o -name '*.sh' \) -exec chmod 755 {} \; 2>/dev/null || true
  else
    chmod 644 "$path" 2>/dev/null || true
    case "$path" in
      */bin/*|*/xbin/*|*.sh)
        chmod 755 "$path" 2>/dev/null || true
        ;;
    esac
  fi
}

payload_overlay() {
  local mp="$1"
  local partition_name
  partition_name=$(basename "$mp")

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local payload_root="$script_dir/payload/$partition_name"
  if [[ ! -d "$payload_root" ]]; then
    log_verbose "[Payload] No dm3q payload for partition: $partition_name"
    return 0
  fi

  local target_root="$mp"
  if [[ -d "$mp/$partition_name" ]]; then
    target_root="$mp/$partition_name"
  fi

  log_info "[Payload] Applying dm3q payload: $payload_root -> $target_root"

  local item name dest
  shopt -s nullglob dotglob
  for item in "$payload_root"/*; do
    name=$(basename "$item")
    [[ "$name" == ".gitkeep" ]] && continue
    dest="$target_root/$name"

    if [[ -d "$item" ]]; then
      mkdir -p "$dest"
      cp -a "$item/." "$dest/"
      _fix_payload_perms "$dest"
    else
      mkdir -p "$(dirname "$dest")"
      cp -a "$item" "$dest"
      _fix_payload_perms "$dest"
    fi
  done
  shopt -u nullglob dotglob

  log_info "[Payload] dm3q payload applied for $partition_name"
}
