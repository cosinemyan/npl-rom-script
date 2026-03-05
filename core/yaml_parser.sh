#!/bin/bash
# YAML Parser - Simple YAML value parser for bash

parse_yaml_value() {
  local file="$1"
  local key="$2"
  
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  
  if [[ "$key" == *.* ]]; then
    local parent="${key%%.*}"
    local child="${key#*.}"
    awk -v parent="$parent" -v child="$child" '
      function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
      BEGIN { in_parent=0 }
      $0 ~ "^" parent ":[[:space:]]*$" { in_parent=1; next }
      in_parent && $0 ~ "^[^[:space:]]" { in_parent=0 }
      in_parent && $0 ~ "^[[:space:]]+" child ":[[:space:]]*" {
        sub(/^[[:space:]]+/, "", $0)
        sub("^" child ":[[:space:]]*", "", $0)
        print trim($0)
        exit
      }
    ' "$file"
  else
    awk -v key="$key" '
      function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
      $0 ~ "^" key ":[[:space:]]*" {
        sub("^" key ":[[:space:]]*", "", $0)
        print trim($0)
        exit
      }
    ' "$file"
  fi
}

parse_yaml_array() {
  local file="$1"
  local key="$2"
  
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  
  awk -v key="$key" '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    BEGIN { in_array=0 }
    $0 ~ "^" key ":[[:space:]]*$" { in_array=1; next }
    in_array && $0 ~ "^[^[:space:]]" { in_array=0; exit }
    in_array && $0 ~ "^[[:space:]]*-[[:space:]]*" {
      sub(/^[[:space:]]*-[[:space:]]*/, "", $0)
      print trim($0)
    }
  ' "$file"
}

get_device_partitions() {
  local config_file="$1"
  
  parse_yaml_array "$config_file" "partitions"
}

get_device_fstab() {
  local config_file="$1"
  
  parse_yaml_value "$config_file" "fstab"
}

get_device_soc() {
  local config_file="$1"
  
  parse_yaml_value "$config_file" "soc"
}

check_feature_enabled() {
  local config_file="$1"
  local feature="$2"
  
  local value
  value=$(parse_yaml_value "$config_file" "features.$feature")
  
  [[ "$value" == "true" ]]
}
