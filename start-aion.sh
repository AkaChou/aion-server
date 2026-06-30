#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AION_DIR="${AION_DIR:-$ROOT_DIR/aion}"
LOG_DIR="${AION_LOG_DIR:-$AION_DIR/log}"
START_DELAY_SECONDS="${AION_START_DELAY_SECONDS:-2}"
SERVICES=(chat-server login-server game-server)

usage() {
  cat <<EOF
Usage: ./start-aion.sh [--skip-package]

Builds the Maven zip packages, copies them to ./aion, unzips them there,
then starts chat, login, and game services in the background.

Options:
  --skip-package  Use existing */target/*.zip files instead of running Maven.
  -h, --help      Show this help.
EOF
}

RUN_PACKAGE=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-package)
      RUN_PACKAGE=false
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

package_servers() {
  echo "Packaging Maven modules..."
  (cd "$ROOT_DIR" && mvn -q package)
}

deploy_zip() {
  local service="$1"
  local zip_path="$ROOT_DIR/$service/target/$service.zip"
  local copied_zip="$AION_DIR/$service.zip"
  local service_dir="$AION_DIR/$service"

  if [[ ! -f "$zip_path" ]]; then
    echo "Missing package: $zip_path" >&2
    echo "Run ./start-aion.sh without --skip-package, or run mvn package first." >&2
    exit 1
  fi

  mkdir -p "$AION_DIR"
  cp "$zip_path" "$copied_zip"

  # Keep local config overrides such as mygs.properties, but refresh binaries/scripts.
  rm -rf "$service_dir/libs"
  rm -f "$service_dir/start.sh" "$service_dir/start.bat"
  unzip -oq "$copied_zip" -d "$AION_DIR"
  chmod +x "$service_dir/start.sh"
  echo "Deployed $service from $(quote "$copied_zip")"
}

start_service() {
  local service="$1"
  local short_name="${service%-server}"
  local service_dir="$AION_DIR/$service"
  local wrapper_log="$LOG_DIR/$short_name.out.log"
  local pid_file="$LOG_DIR/$short_name.pid"

  if [[ ! -x "$service_dir/start.sh" ]]; then
    echo "Missing executable start script: $service_dir/start.sh" >&2
    exit 1
  fi

  mkdir -p "$LOG_DIR" "$service_dir/log"
  (
    cd "$service_dir"
    nohup ./start.sh >"$wrapper_log" 2>&1 </dev/null &
    echo $! >"$pid_file"
  )
  echo "Started $service in background (wrapper PID $(cat "$pid_file"))"
}

print_log_commands() {
  echo
  echo "Log commands:"
  for service in "${SERVICES[@]}"; do
    local short_name="${service%-server}"
    echo "  tail -f $(quote "$LOG_DIR/$short_name.out.log")"
    echo "  tail -f $(quote "$AION_DIR/$service/log/server_console.log")"
  done
}

main() {
  require_command unzip
  require_command java
  require_command jps
  if [[ "$RUN_PACKAGE" == true ]]; then
    require_command mvn
    package_servers
  fi

  mkdir -p "$AION_DIR" "$LOG_DIR"
  for service in "${SERVICES[@]}"; do
    deploy_zip "$service"
  done

  for ((i = 0; i < ${#SERVICES[@]}; i++)); do
    start_service "${SERVICES[$i]}"
    if (( i < ${#SERVICES[@]} - 1 )); then
      sleep "$START_DELAY_SECONDS"
    fi
  done

  print_log_commands
}

main "$@"
