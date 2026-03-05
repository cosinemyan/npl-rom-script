#!/bin/bash
# Logger - Common logging functions + progress utilities

LOG_LEVEL="${LOG_LEVEL:-1}"

LOG_LEVEL_DEBUG=0
LOG_LEVEL_INFO=1
LOG_LEVEL_WARN=2
LOG_LEVEL_ERROR=3

log_debug() {
  if [[ "$LOG_LEVEL" -le "$LOG_LEVEL_DEBUG" ]]; then
    echo -e "\033[0;36m[DEBUG]\033[0m ${*:-}" >&2
  fi
}

log_verbose() {
  log_debug "${*:-}"
}

log_info() {
  if [[ "$LOG_LEVEL" -le "$LOG_LEVEL_INFO" ]]; then
    echo -e "\033[0;32m[INFO]\033[0m ${*:-}" >&2
  fi
}

log_warn() {
  if [[ "$LOG_LEVEL" -le "$LOG_LEVEL_WARN" ]]; then
    echo -e "\033[0;33m[WARN]\033[0m ${*:-}" >&2
  fi
}

log_error() {
  if [[ "$LOG_LEVEL" -le "$LOG_LEVEL_ERROR" ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m ${*:-}" >&2
  fi
}

log_success() {
  echo -e "\033[0;32m[SUCCESS]\033[0m ${*:-}" >&2
}

set_log_level() {
  local level="$1"
  case "$level" in
    DEBUG) LOG_LEVEL="$LOG_LEVEL_DEBUG" ;;
    INFO)  LOG_LEVEL="$LOG_LEVEL_INFO"  ;;
    WARN)  LOG_LEVEL="$LOG_LEVEL_WARN"  ;;
    ERROR) LOG_LEVEL="$LOG_LEVEL_ERROR" ;;
  esac
}

# ─── Progress Utilities ────────────────────────────────────────────────────────

_SPINNER_PID=""
_STEP_START_TIME=""

# Start a background spinner for a long-running operation.
# Usage: progress_start "Extracting firmware"
progress_start() {
  local label="${1:-Working}"
  _STEP_START_TIME=$(date +%s)

  # Only animate if stderr is a terminal
  if [[ -t 2 ]]; then
    (
      local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
      local i=0
      while true; do
        local elapsed=$(( $(date +%s) - _STEP_START_TIME ))
        local mins=$(( elapsed / 60 ))
        local secs=$(( elapsed % 60 ))
        local timer
        if [[ $mins -gt 0 ]]; then
          timer="${mins}m${secs}s"
        else
          timer="${secs}s"
        fi
        printf "\r\033[0;36m[....]\033[0m %s %s  \033[0;36m(%s)\033[0m " \
          "${frames[$i]}" "$label" "$timer" >&2
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.12
      done
    ) &
    _SPINNER_PID=$!
    disown "$_SPINNER_PID" 2>/dev/null || true
  else
    # Non-TTY: fall back to periodic log lines (handled by caller)
    log_info "$label..."
    _SPINNER_PID=""
  fi
}

# Stop the spinner and print a completion line.
# Usage: progress_end "Done" [0|1]   (0=success, 1=fail)
progress_end() {
  local label="${1:-Done}"
  local status="${2:-0}"

  if [[ -n "$_SPINNER_PID" ]]; then
    kill "$_SPINNER_PID" 2>/dev/null || true
    wait "$_SPINNER_PID" 2>/dev/null || true
    _SPINNER_PID=""
  fi

  local elapsed=0
  if [[ -n "$_STEP_START_TIME" ]]; then
    elapsed=$(( $(date +%s) - _STEP_START_TIME ))
  fi
  local mins=$(( elapsed / 60 ))
  local secs=$(( elapsed % 60 ))
  local timer
  if [[ $mins -gt 0 ]]; then
    timer="${mins}m${secs}s"
  else
    timer="${secs}s"
  fi

  if [[ -t 2 ]]; then
    printf "\r" >&2
  fi

  if [[ "$status" -eq 0 ]]; then
    log_success "$label  [$timer]"
  else
    log_error "$label  [$timer]"
  fi
  _STEP_START_TIME=""
}

# Run a command with a spinner + 20s heartbeat log lines.
# Usage: run_with_progress "Extracting super.img" cmd [args...]
run_with_progress() {
  local label="$1"
  shift

  progress_start "$label"

  local start_time=$(date +%s)
  local tmp_out
  tmp_out=$(mktemp)

  # Run in background, capture combined output
  "$@" >"$tmp_out" 2>&1 &
  local cmd_pid=$!

  local last_heartbeat=$start_time
  while kill -0 "$cmd_pid" 2>/dev/null; do
    sleep 5
    local now=$(date +%s)
    local elapsed=$(( now - start_time ))
    # Heartbeat every 20s when not in TTY mode
    if [[ -z "$_SPINNER_PID" ]] && (( now - last_heartbeat >= 20 )); then
      log_info "$label... ${elapsed}s elapsed"
      last_heartbeat=$now
    fi
  done

  wait "$cmd_pid"
  local rc=$?

  if [[ "$rc" -eq 0 ]]; then
    progress_end "$label" 0
  else
    progress_end "$label (FAILED)" 1
    cat "$tmp_out" >&2
  fi
  rm -f "$tmp_out"
  return $rc
}
