#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AION_DIR="${AION_DIR:-$ROOT_DIR/aion}"
LOG_DIR="${AION_LOG_DIR:-$AION_DIR/log}"
STOP_TIMEOUT_SECONDS="${AION_STOP_TIMEOUT_SECONDS:-30}"

SERVICES=(game-server login-server chat-server)

usage() {
  cat <<EOF
Usage: ./stop-aion.sh [--force]

Stops game, login, and chat services started from ./aion.

Options:
  --force     Send SIGKILL if a process is still alive after SIGTERM.
  -h, --help  Show this help.
EOF
}

FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

quote() {
  printf "%q" "$1"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

main_class() {
  case "$1" in
    chat-server) echo "com.aionemu.chatserver.ChatServer" ;;
    login-server) echo "com.aionemu.loginserver.LoginServer" ;;
    game-server) echo "com.aionemu.gameserver.GameServer" ;;
    *)
      echo "Unknown service: $1" >&2
      exit 2
      ;;
  esac
}

short_name() {
  echo "${1%-server}"
}

is_running() {
  local pid="$1"
  kill -0 "$pid" >/dev/null 2>&1
}

wait_for_exit() {
  local pid="$1"
  local timeout="$2"
  local waited=0

  while is_running "$pid"; do
    if (( waited >= timeout )); then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

pid_from_file() {
  local service="$1"
  local pid_file="$LOG_DIR/$(short_name "$service").pid"

  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(tr -cd '0-9' < "$pid_file")"
    if [[ -n "$pid" ]] && is_running "$pid"; then
      echo "$pid"
    fi
  fi
}

pids_from_jps() {
  local class_name="$1"
  jps -l | awk -v class="$class_name" '$2 == class {print $1}'
}

remove_pid_file() {
  local service="$1"
  rm -f "$LOG_DIR/$(short_name "$service").pid"
}

stop_pid() {
  local service="$1"
  local pid="$2"
  local signal="${3:-INT}"

  if ! is_running "$pid"; then
    return 0
  fi

  echo "Stopping $service (PID $pid, SIG$signal)..."
  kill "-$signal" "$pid" 2>/dev/null || true
  if wait_for_exit "$pid" "$STOP_TIMEOUT_SECONDS"; then
    echo "Stopped $service (PID $pid)"
    return 0
  fi

  if [[ "$signal" != "TERM" ]]; then
    echo "$service did not stop after SIG$signal; sending SIGTERM..."
    stop_pid "$service" "$pid" "TERM"
    return $?
  fi

  if [[ "$FORCE" == true ]]; then
    echo "$service did not stop after SIGTERM; sending SIGKILL..."
    kill -KILL "$pid" 2>/dev/null || true
    wait_for_exit "$pid" 5 || true
  else
    echo "$service is still running (PID $pid). Re-run with --force to send SIGKILL." >&2
    return 1
  fi
}

stop_service() {
  local service="$1"
  local class_name
  class_name="$(main_class "$service")"

  local found=false
  local pid
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    found=true
    stop_pid "$service" "$pid"
  done < <(pids_from_jps "$class_name")

  pid="$(pid_from_file "$service" || true)"
  if [[ -n "$pid" ]]; then
    found=true
    stop_pid "$service wrapper" "$pid"
  fi

  remove_pid_file "$service"
  if [[ "$found" == false ]]; then
    echo "$service is not running."
  fi
}

print_log_commands() {
  echo
  echo "Log commands:"
  for service in chat-server login-server game-server; do
    local name
    name="$(short_name "$service")"
    echo "  tail -f $(quote "$LOG_DIR/$name.out.log")"
    echo "  tail -f $(quote "$AION_DIR/$service/log/server_console.log")"
  done
}

main() {
  require_command jps

  for service in "${SERVICES[@]}"; do
    stop_service "$service"
  done

  print_log_commands
}

main "$@"
