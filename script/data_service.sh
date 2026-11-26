#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/com.aryan.TradingWorkspace"
SERVICE_DIR="$SUPPORT/DataService"
BINARY="$SERVICE_DIR/trading-data-service"
LABEL="com.aryan.TradingWorkspace.data-service"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
JOB="$DOMAIN/$LABEL"

is_loaded() { launchctl print "$JOB" >/dev/null 2>&1; }

sync_chart() {
  mkdir -p -m 700 "$SERVICE_DIR/Chart"
  rsync -a --delay-updates --delete-after "$ROOT_DIR/.build/chart-host/" "$SERVICE_DIR/Chart/"
}

sync_research() {
  local source="$ROOT_DIR/research-host" target="$SERVICE_DIR/ResearchHost" node_binary file
  node_binary="$(command -v node)"
  mkdir -p -m 700 "$target"
  if [[ ! -d "$target/node_modules/acpx" ]] || ! cmp -s "$source/package-lock.json" "$target/package-lock.json"; then
    npm ci --prefix "$source" --ignore-scripts --no-audit --no-fund --prefer-offline
    mkdir -p "$target/node_modules"
    rsync -a --delay-updates --delete-after "$source/node_modules/" "$target/node_modules/"
    install -m 600 "$source/package-lock.json" "$target/package-lock.json"
  fi
  for file in research-messages.mjs research-tools.mjs mcp-stdio.mjs host.mjs; do
    install -m 600 "$source/$file" "$target/$file.new"
    mv -f "$target/$file.new" "$target/$file"
  done
  printf '%s\n' "$node_binary" > "$target/node-path"
}

build_binary() {
  local stage
  cargo build --manifest-path "$ROOT_DIR/backend/trading-data/Cargo.toml" --locked
  mkdir -p -m 700 "$SERVICE_DIR"
  sync_research
  stage="$(mktemp "$SERVICE_DIR/.trading-data-service.XXXXXX")"
  if ! install -m 700 "$ROOT_DIR/backend/trading-data/target/debug/trading-data-service" "$stage" \
    || ! mv -f "$stage" "$BINARY"; then
    rm -f -- "$stage"
    return 1
  fi
}

write_plist() (
  mkdir -p "$(dirname "$PLIST")"
  local stage argument index=0
  stage="$(mktemp "$PLIST.XXXXXX")"
  trap 'rm -f -- "$stage"' EXIT
  plutil -create xml1 "$stage"
  plutil -insert Label -string "$LABEL" "$stage"
  plutil -insert KeepAlive -bool YES "$stage"
  plutil -insert LimitLoadToSessionType -string Aqua "$stage"
  plutil -insert StandardErrorPath -string "$SERVICE_DIR/service.log" "$stage"
  plutil -insert ProgramArguments -array "$stage"
  for argument in "$BINARY" --assets "$SERVICE_DIR/Chart" --database "$SUPPORT/portfolio.sqlite" \
    --quote-config "$SUPPORT/quotes.env" --endpoint-file "$SERVICE_DIR/endpoint.json"; do
    plutil -insert "ProgramArguments.$index" -string "$argument" "$stage"
    index=$((index + 1))
  done
  plutil -lint -s "$stage"
  mv -f "$stage" "$PLIST"
)

ensure_job() {
  if is_loaded; then return; fi
  if [[ ! -s "$SERVICE_DIR/Chart/index.html" || ! -s "$SERVICE_DIR/Chart/chart.js" ]]; then
    npm ci --prefix "$ROOT_DIR/chart-host" --no-audit --no-fund --prefer-offline
    npm run --prefix "$ROOT_DIR/chart-host" build
    sync_chart
  fi
  if [[ ! -x "$BINARY" ]]; then build_binary; fi
  write_plist
  launchctl bootstrap "$DOMAIN" "$PLIST"
}

case "${1:-status}" in
  install) ensure_job ;;
  sync-chart) sync_chart; ensure_job ;;
  build)
    build_binary
    if is_loaded; then launchctl kickstart -k "$JOB"; else ensure_job; fi
    ;;
  restart) launchctl kickstart -k "$JOB" ;;
  status) launchctl print "$JOB" ;;
  uninstall)
    if is_loaded; then launchctl bootout "$JOB"; fi
    rm -f -- "$PLIST" "$SERVICE_DIR/endpoint.json"
    ;;
  *) echo "usage: $0 [install|build|restart|status|uninstall]" >&2; exit 2 ;;
esac
