#!/bin/bash
# AVB Signing - Partition image signing and vbmeta patching

_get_avb_key_path() {
  local key="$PROJECT_ROOT/security/avb/testkey_rsa4096.pem"
  if [[ ! -f "$key" ]]; then
    log_error "AVB signing key not found at security/avb/testkey_rsa4096.pem"
    return 1
  fi
  echo "$key"
}

sign_partition_image() {
  local image="$1"
  local partition_name="$2"
  local partition_size="$3"

  if ! command -v avbtool &>/dev/null; then
    log_warn "avbtool not found; skipping AVB signing for $partition_name"
    return 0
  fi

  if avbtool info_image --image "$image" &>/dev/null; then
    log_verbose "$partition_name already has AVB footer, skipping signing"
    return 0
  fi

  local avb_key
  avb_key=$(_get_avb_key_path) || return 1

  if [[ -z "$partition_size" ]] || [[ "$partition_size" -eq 0 ]]; then
    local img_size
    img_size=$(stat -c%s "$image" 2>/dev/null || echo 0)
    partition_size=$(( (img_size * 1003) / 1000 ))
    [[ "$partition_size" -lt 262144 ]] && partition_size=262144
    partition_size=$(( (partition_size + 4095) / 4096 * 4096 ))
  fi

  log_info "Signing $partition_name with AVB hashtree footer (size=$partition_size)"

  avbtool add_hashtree_footer \
    --image "$image" \
    --partition_size "$partition_size" \
    --partition_name "$partition_name" \
    --hash_algorithm "sha256" \
    --algorithm "SHA256_RSA4096" \
    --key "$avb_key" || {
      log_error "Failed to sign $partition_name with AVB"
      return 1
    }
}

sign_all_partitions() {
  local partitions_dir="$1"

  log_info "Signing partition images with AVB..."

  if ! command -v avbtool &>/dev/null; then
    log_warn "avbtool not found, skipping AVB partition signing"
    return 0
  fi

  _get_avb_key_path || return 1

  local img name
  for img in "$partitions_dir"/*.img; do
    [[ -f "$img" ]] || continue
    name=$(basename "$img" .img)

    case "$name" in
      system|vendor|product|odm|system_ext|vendor_dlkm|odm_dlkm|system_dlkm)
        sign_partition_image "$img" "$name" "" || {
          log_warn "AVB signing failed for $name, continuing"
        }
        ;;
    esac
  done
}

disable_avb() {
  local vbmeta_img="$1"
  local output="$2"

  log_info "Disabling AVB verification in vbmeta"

  if ! command -v avbtool &>/dev/null; then
    log_error "avbtool not found. Please add to tools/"
    return 1
  fi

  local input_size
  input_size=$(stat -c%s "$vbmeta_img" 2>/dev/null || echo 0)
  if [[ "$input_size" -le 0 ]]; then
    input_size=4096
  fi

  # vbmeta and vbmeta_system are standalone vbmeta images on Samsung firmware;
  # they usually do not have AVB footers, so erase_footer is not applicable.
  avbtool make_vbmeta_image \
    --flags 2 \
    --set_hashtree_disabled_flag \
    --padding_size "$input_size" \
    --output "$output" || return 1

  log_info "AVB disabled: $output"
}

patch_vbmeta_for_partitions() {
  local vbmeta_img="$1"
  local partitions_dir="$2"
  local output_vbmeta="$3"

  log_info "Patching vbmeta for partitions..."

  local avbtool_args=()

  for img in "$partitions_dir"/*.img; do
    if [[ -f "$img" ]]; then
      local name
      name=$(basename "$img" .img)

      log_verbose "Adding vbmeta chain for: $name"

      avbtool_args+=(
        --chain_partition "$name":"$partitions_dir/avb/$name.avbpubkey":"$img"
      )
    fi
  done

  if [[ ${#avbtool_args[@]} -eq 0 ]]; then
    log_info "No partitions to chain, using empty vbmeta"
    avbtool make_vbmeta_image --output "$output_vbmeta"
    return 0
  fi

  avbtool make_vbmeta_image "${avbtool_args[@]}" --output "$output_vbmeta" || return 1

  log_info "vbmeta patched: $output_vbmeta"
}
