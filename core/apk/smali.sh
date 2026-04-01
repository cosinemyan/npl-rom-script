#!/bin/bash
# Smali Patching Utilities - Surgical smali bytecode modifications
# Adapted from UN1CA's scripts/utils/smali_utils.sh

# smali_patch <partition> <apk_path> <smali_path> <operation> [method] [value] [replacement]
#
# Operations:
#   null        <method>                            - Empty a void method body (return-void)
#   strip       <method>                            - Remove a method entirely from the smali
#   return      <method> <value>                    - Replace method body with const + return
#   replace     <method> <value> <replacement>      - Replace string/line inside a specific method
#   replaceall  <value> <replacement>               - Global sed replace across the entire file
#   remove                                          - Delete a smali file entirely (with usage check)
smali_patch() {
  local partition="$1"
  local apk_path="$2"
  local smali_path="$3"
  local operation="$4"

  if [[ -z "$partition" ]] || [[ -z "$apk_path" ]] || [[ -z "$smali_path" ]] || [[ -z "$operation" ]]; then
    log_error "smali_patch: missing required arguments"
    return 1
  fi

  # Strip leading slash from apk_path
  while [[ "${apk_path:0:1}" == "/" ]]; do
    apk_path="${apk_path:1}"
  done

  # Ensure the APK is decoded
  local decoded_dir="$APKTOOL_DIR/$partition/${apk_path%/*}/$(basename "$apk_path")"
  if [[ ! -d "$decoded_dir" ]]; then
    apktool_decode "$partition" "$apk_path" >/dev/null || return 1
    decoded_dir="$APKTOOL_DIR/$partition/${apk_path%/*}/$(basename "$apk_path")"
  fi

  local file_path="$decoded_dir/$smali_path"

  # Validate operation
  case "$operation" in
    null|remove|replace|replaceall|return|strip) ;;
    *)
      log_error "smali_patch: invalid operation '$operation'"
      return 1
      ;;
  esac

  # Handle 'remove' (delete entire file)
  if [[ "$operation" == "remove" ]]; then
    if [[ ! -f "$file_path" ]]; then
      log_error "smali_patch: file not found: $smali_path"
      return 1
    fi

    # Check if the class is referenced elsewhere
    local class_name
    class_name=$(basename "$smali_path" .smali)
    local usage
    usage=$(grep -r -n -- "${class_name};" "$decoded_dir" --include="*.smali" \
      ! -path "$file_path" 2>/dev/null | head -n 10 || true)

    if [[ -n "$usage" ]]; then
      log_error "smali_patch: cannot remove '$smali_path' — class is used elsewhere"
      echo "$usage" | head -n 5 >&2
      return 1
    fi

    log_info "  smali remove: $smali_path"
    rm -f "$file_path"
    log_patch_action "SMALI_REMOVE partition=$partition apk=$apk_path smali=$smali_path"
    return 0
  fi

  # For all other operations, parse method parameter
  local method="${5:-}"
  if [[ -z "$method" ]]; then
    log_error "smali_patch: method required for operation '$operation'"
    return 1
  fi

  # Parse value/replacement based on operation
  local value=""
  local replacement=""
  case "$operation" in
    replaceall)
      value="${5:-}"
      replacement="${6:-}"
      method=""
      ;;
    return)
      value="${6:-}"
      ;;
    replace)
      value="${6:-}"
      replacement="${7:-}"
      ;;
    null|strip)
      # No extra params needed
      ;;
  esac

  if [[ ! -f "$file_path" ]]; then
    log_error "smali_patch: smali not found: $smali_path"

    # Try to find similar files
    local matches
    matches=$(find "$decoded_dir" -type f -name "*${smali_path##*/}" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      echo "  Possible matches:" >&2
      echo "$matches" | sed "s|$decoded_dir/|    |" | head -n 5 >&2
    fi
    return 1
  fi

  # For method-based operations, verify the method exists
  if [[ -n "$method" ]]; then
    if ! grep -Eq "^\.method.*$(printf '%s' "$method" | sed 's/[[\.*^$()+?{|]/\\&/g')" "$file_path" 2>/dev/null; then
      log_error "smali_patch: method '$method' not found in $smali_path"
      local method_matches
      method_matches=$(grep -r "^\.method.*${method%%(*}" "$decoded_dir" 2>/dev/null | head -n 5 || true)
      if [[ -n "$method_matches" ]]; then
        echo "  Possible matches:" >&2
        echo "$method_matches" | sed "s|$decoded_dir/|    |" | head -n 5 >&2
      fi
      return 1
    fi
  fi

  local before after
  before=$(sha1sum "$file_path" 2>/dev/null | awk '{print $1}')

  case "$operation" in
    null)    _smali_null "$file_path" "$method" ;;
    strip)   _smali_strip "$file_path" "$method" ;;
    return)  _smali_return "$file_path" "$method" "$value" ;;
    replace) _smali_replace "$file_path" "$method" "$value" "$replacement" ;;
    replaceall) _smali_replaceall "$file_path" "$value" "$replacement" ;;
  esac

  after=$(sha1sum "$file_path" 2>/dev/null | awk '{print $1}')

  if [[ "$before" == "$after" ]]; then
    log_error "smali_patch: $operation had no effect on $smali_path (method=$method)"
    return 1
  fi

  log_verbose "SMALI_${operation^^} partition=$partition apk=$apk_path smali=$smali_path method=${method:-none}"
  return 0
}

# --- Operation implementations ---

_smali_null() {
  local file="$1"
  local method="$2"

  log_info "  smali null: ${method%%(*} in $(basename "$file")"

  awk -v FN="$method" '
    BEGIN { inside = 0 }
    /^\.method/ && index($0, FN) {
      print
      print "    .locals 0"
      print ""
      print "    return-void"
      inside = 1
      next
    }
    inside && /^\.end method/ {
      print
      inside = 0
      next
    }
    inside { next }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

_smali_strip() {
  local file="$1"
  local method="$2"

  log_info "  smali strip: ${method%%(*} in $(basename "$file")"

  awk -v FN="$method" '
    BEGIN { inside = 0; skip = 0 }
    /^\.method/ && index($0, FN) {
      inside = 1
      next
    }
    inside && /^\.end method/ {
      inside = 0
      skip = 1
      next
    }
    inside { next }
    {
      if (skip) { skip = 0; next }
      print
    }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

_smali_return() {
  local file="$1"
  local method="$2"
  local value="$3"

  local ret_type="${method#*)}"
  local reg="p0"
  local loc=".locals 0"

  # Determine if static with no args → use v0 instead of p0
  if grep "^\.method.*" "$file" | grep -F -- "$method" | grep -q " static " && [[ "$method" == *"()"* ]]; then
    reg="v0"
    loc=".locals 1"
  fi

  local ret_stmt=""
  local const_stmt=""

  if [[ "$ret_type" == "V" ]]; then
    log_error "smali_patch: cannot return a value from void method '$method'"
    return 1
  elif [[ "$ret_type" == "Ljava/lang/String;" ]]; then
    value="\"$value\""
    ret_stmt="return-object $reg"
    const_stmt="const-string $reg, $value"
  elif [[ "$ret_type" =~ ^\[*[ZBCSIJFD]$ ]]; then
    # Boolean
    if [[ "$ret_type" == "Z" ]]; then
      case "$value" in
        true) value="0x1" ;;
        false) value="0x0" ;;
      esac
    fi
    # Convert decimal to hex
    if [[ "$value" =~ ^-?[0-9]+$ ]]; then
      value="0x$(printf '%x' "$value")"
    fi
    # Choose const instruction
    local num
    num=$((value))
    if [[ "$ret_type" == "J" ]]; then
      ret_stmt="return-wide $reg"
      const_stmt="const-wide/16 $reg, $value"
    else
      ret_stmt="return $reg"
      if [[ $num -ge -8 ]] && [[ $num -lt 8 ]]; then
        const_stmt="const/4 $reg, $value"
      else
        const_stmt="const/16 $reg, $value"
      fi
    fi
  else
    # Object return type
    if [[ "$value" == "null" ]]; then
      value="0x0"
    fi
    ret_stmt="return-object $reg"
    const_stmt="const/4 $reg, $value"
  fi

  log_info "  smali return: ${method%%(*} → $value in $(basename "$file")"

  awk -v FN="$method" -v LOC="$loc" -v VAL="$const_stmt" -v RET="$ret_stmt" '
    BEGIN { inside = 0 }
    /^\.method/ && index($0, FN) {
      print
      print "    " LOC
      print ""
      print "    " VAL
      print ""
      print "    " RET
      inside = 1
      next
    }
    inside && /^\.end method/ {
      print
      inside = 0
      next
    }
    inside { next }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

_smali_replace() {
  local file="$1"
  local method="$2"
  local value="$3"
  local replacement="$4"

  log_info "  smali replace: '$value' → '$replacement' in ${method%%(*} ($(basename "$file"))"

  awk -v FN="$method" -v STR="$value" -v REP="$replacement" '
    BEGIN { inside = 0; isline = (index(REP, "\n") > 0) }
    /^\.method/ && index($0, FN) { inside = 1 }
    inside {
      if (isline) {
        if (index($0, STR)) {
          gsub(/\\n/, "\n", REP)
          print REP
          next
        }
      } else if ($0 ~ /^[[:space:]]*const-string(\/jumbo)?/) {
        sub("\"" STR "\"", "\"" REP "\"")
      } else {
        line = $0
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line == STR) {
          match($0, /^[ \t]+/)
          indent = substr($0, RSTART, RLENGTH)
          $0 = indent REP
        }
      }
    }
    inside && /^\.end method/ { inside = 0 }
    { print }
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

_smali_replaceall() {
  local file="$1"
  local value="$2"
  local replacement="$3"

  log_info "  smali replaceall: '$value' → '$replacement' in $(basename "$file")"

  sed -i "s|${value}|${replacement}|g" "$file"
}
