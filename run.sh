#!/usr/bin/env bash
#
# GUIbiont launcher (macOS / Linux).
#
#   ./run.sh            start GUIbiont (pulls the latest image, picks a free
#                       port, opens your browser)
#   ./run.sh stop       stop a running GUIbiont
#
# The only prerequisite is Docker Desktop (https://www.docker.com/products/docker-desktop/).
# Your experiment data lives in ~/GUIbiont-data and is never touched by updates.

set -euo pipefail

IMAGE="${GUIBIONT_IMAGE:-ghcr.io/pinheirogroup/guibiont:latest}"
CONTAINER="guibiont"
DEFAULT_DATA_DIR="$HOME/GUIbiont-data"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/guibiont/data_dir"
PORT_START="${GUIBIONT_PORT:-8080}"
PORT_END=$((PORT_START + 100))

info()  { printf '\033[36m%s\033[0m\n' "$*"; }
ok()    { printf '\033[32m%s\033[0m\n' "$*"; }
err()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }

# Ask (once) where to keep experiment data, then remember the answer.
# Precedence: GUIBIONT_DATA env var > saved choice > interactive prompt > default.
resolve_data_dir() {
  if [[ -n "${GUIBIONT_DATA:-}" ]]; then
    printf '%s' "$GUIBIONT_DATA"; return          # explicit override, not persisted
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    printf '%s' "$(<"$CONFIG_FILE")"; return       # previously chosen
  fi
  if [[ -t 0 ]]; then                              # first run with a real terminal
    printf 'Where should GUIbiont store your experiment data?\n' >&2
    printf '  Press Enter for the default [%s]\n  Folder: ' "$DEFAULT_DATA_DIR" >&2
    local reply; read -r reply
    reply="${reply/#\~/$HOME}"                      # expand a leading ~
    reply="${reply:-$DEFAULT_DATA_DIR}"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    printf '%s\n' "$reply" > "$CONFIG_FILE"         # remember for next time
    printf '%s' "$reply"
  else
    printf '%s' "$DEFAULT_DATA_DIR"                 # non-interactive: use default
  fi
}

# --- stop subcommand --------------------------------------------------------
if [[ "${1:-}" == "stop" ]]; then
  docker stop "$CONTAINER" >/dev/null 2>&1 && ok "🛑 GUIbiont stopped." || info "GUIbiont was not running."
  exit 0
fi

# --- config subcommand: forget the saved folder and ask again next run ------
if [[ "${1:-}" == "config" ]]; then
  rm -f "$CONFIG_FILE"
  ok "🔧 Data-folder choice reset. You'll be asked again on the next run."
  exit 0
fi

# --- 1. Docker present and running? ----------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  err "Docker is not installed. Get Docker Desktop: https://www.docker.com/products/docker-desktop/"
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  err "Docker is installed but not running — please start Docker Desktop and try again."
  exit 1
fi

# --- 2. First-run data folders (mounted into the container) -----------------
DATA_DIR="$(resolve_data_dir)"
mkdir -p "$DATA_DIR/raw_data" "$DATA_DIR/Clean_data"
info "📂 Data folder: $DATA_DIR"

# --- 3. Already running? Just reopen it -------------------------------------
existing_port="$(docker inspect --format '{{ (index (index .NetworkSettings.Ports "8080/tcp") 0).HostPort }}' "$CONTAINER" 2>/dev/null || true)"
if [[ -n "$existing_port" ]]; then
  URL="http://localhost:$existing_port"
  ok "✅ GUIbiont is already running at $URL"
  open_browser() { case "$(uname -s)" in Darwin) open "$1";; *) xdg-open "$1" >/dev/null 2>&1 || true;; esac; }
  open_browser "$URL"
  exit 0
fi

# --- 4. Find a free host port -----------------------------------------------
port_in_use() {
  # Returns 0 (true) if something is already listening on $1.
  if command -v nc >/dev/null 2>&1; then nc -z 127.0.0.1 "$1" >/dev/null 2>&1; return; fi
  (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1 && { exec 3>&- ; return 0; }
  return 1
}
PORT=""
for p in $(seq "$PORT_START" "$PORT_END"); do
  if ! port_in_use "$p"; then PORT="$p"; break; fi
done
[[ -z "$PORT" ]] && { err "No free port found in $PORT_START-$PORT_END."; exit 1; }
info "🔌 Using port $PORT"

# --- 5. Pull the latest image (this is also the update path) ----------------
info "⬇️  Checking for updates…"
if ! docker pull "$IMAGE" 2>/dev/null; then
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    info "   (registry unreachable — using the local copy of $IMAGE)"
  else
    err "Couldn't pull $IMAGE and no local copy is present."
    err "Check your internet connection, or build locally with: docker build -t $IMAGE ."
    exit 1
  fi
fi

# --- 6. Start the container --------------------------------------------------
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" \
  -p "$PORT:8080" \
  -v "$DATA_DIR/raw_data:/app/raw_data" \
  -v "$DATA_DIR/Clean_data:/app/Clean_data" \
  "$IMAGE" >/dev/null

# --- 7. Wait for readiness, then open the browser ---------------------------
URL="http://localhost:$PORT"
info "⏳ Starting GUIbiont…"
for _ in $(seq 1 60); do
  if curl -sf "$URL" >/dev/null 2>&1; then break; fi
  if ! docker ps --format '{{.Names}}' | grep -q "^$CONTAINER$"; then
    err "GUIbiont failed to start. Logs:"; docker logs "$CONTAINER" 2>&1 | tail -20; exit 1
  fi
  sleep 1
done

open_browser() { case "$(uname -s)" in Darwin) open "$1";; *) xdg-open "$1" >/dev/null 2>&1 || true;; esac; }
open_browser "$URL"
ok "✅ GUIbiont running at $URL"
info "   Stop it with:  ./run.sh stop"
