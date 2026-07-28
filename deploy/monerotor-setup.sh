#!/usr/bin/env bash
# monerotor deploy wizard — macOS / Linux.
#
# Pulls the pre-built multi-arch image from GHCR and deploys it: asks where to
# keep the data, writes a docker-compose.yml, then hands over to the
# in-container setup wizard (prints onion address + RPC user + password).
#
# Usage:  ./monerotor-setup.sh
# Env:    MONEROTOR_IMAGE   override the image (default ghcr.io/catsec/monerotor:latest)
#
# Works with stock macOS bash 3.2; no bash-4-isms.
set -eu

IMAGE="${MONEROTOR_IMAGE:-ghcr.io/catsec/monerotor:latest}"

say()  { printf '%s\n' "$*"; }
hr()   { printf -- '----------------------------------------------------------------------\n'; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ask()  { # ask "prompt" "default" -> REPLY
    printf '%s [%s] ' "$1" "$2"
    read -r REPLY || true
    [ -n "$REPLY" ] || REPLY="$2"
}

# --- sanity: docker + compose v2 + running daemon ---
command -v docker >/dev/null 2>&1 \
    || die "docker not found. Install Docker Desktop (mac) or docker-ce (linux) first:
       https://docs.docker.com/get-docker/"
docker info >/dev/null 2>&1 \
    || die "the docker daemon is not running (start Docker Desktop / dockerd)."
if docker compose version >/dev/null 2>&1; then
    compose() { docker compose "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then
    compose() { docker-compose "$@"; }
else
    die "docker compose v2 not found (comes with Docker Desktop; on linux install the docker-compose-plugin package)."
fi

hr
say "monerotor deploy wizard"
say "image: ${IMAGE}"
hr

# --- where does everything live? ---
ask "Install directory (compose file, config)" "${HOME}/monerotor"
DIR="$REPLY"

# Existing install → offer update instead of clobbering.
if [ -f "${DIR}/docker-compose.yml" ]; then
    say "An existing monerotor install was found in ${DIR}."
    ask "[U]pdate image + restart, [R]e-run container setup, or [Q]uit?" "U"
    case "$REPLY" in
        [Rr]*) cd "$DIR"; compose run --rm setup; exit 0 ;;
        [Qq]*) exit 0 ;;
        *)     cd "$DIR"
               compose pull
               compose up -d
               say "Updated and restarted. Logs: docker compose logs -f node"
               exit 0 ;;
    esac
fi

say ""
say "The blockchain is the big one: ~100 GB pruned (~220 GB+ full), and it"
say "grows. Put it on a disk with room. Everything else is tiny."
ask "Blockchain directory" "${DIR}/data/monero"
MONERO_DIR="$REPLY"

hr
say "Install dir:     ${DIR}"
say "Blockchain dir:  ${MONERO_DIR}"
ask "Proceed?" "Y"
case "$REPLY" in [Nn]*) exit 0 ;; esac

mkdir -p "$DIR" "$MONERO_DIR" "${DIR}/data/tor" "${DIR}/data/config"

# --- compose file: image-based mirror of the repo's docker-compose.yml, with
# the chosen paths baked in (one file, no .env, nothing implicit).
# KEEP IN SYNC with the repo compose file: same caps, same hardening, and
# never a 'ports:' stanza — the node is reachable only as onion services.
cat > "${DIR}/docker-compose.yml" <<EOF
# monerotor — deployed from the pre-built image (written by the deploy wizard).
# Manage:  docker exec monerotor mtor <status|onion|logs|set ...>
# Fresh start: down, delete the data folders, re-run the deploy wizard.

services:
  node:
    image: "${IMAGE}"
    container_name: monerotor
    command: ["run"]
    restart: unless-stopped
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop: ["ALL"]
    cap_add:                       # justified minimum:
      - NET_ADMIN                  #  load the nftables kill-switch
      - NET_RAW                    #  "
      - SETUID                     #  drop PID1 -> tor/monero
      - SETGID                     #  "
      - CHOWN                      #  one-time ownership of the data volumes
    stop_grace_period: 2m
    tmpfs:
      - /run:mode=0755
      - /tmp:mode=1777
    volumes:
      - "${MONERO_DIR}:/data/monero"
      - "${DIR}/data/tor:/data/tor"
      - "${DIR}/data/config:/data/config"
    healthcheck:
      test: ["CMD", "sh", "-c", "mtor status | grep -q 'Height:'"]
      interval: 60s
      timeout: 30s
      retries: 5
      start_period: 5m
    # Intentionally NO 'ports:' — the host exposes nothing.

  setup:
    image: "${IMAGE}"
    profiles: ["setup"]
    command: ["setup"]
    cap_drop: ["ALL"]
    cap_add: ["CHOWN", "SETUID", "SETGID"]
    volumes:
      - "${MONERO_DIR}:/data/monero"
      - "${DIR}/data/tor:/data/tor"
      - "${DIR}/data/config:/data/config"
EOF

cd "$DIR"
hr
say "Pulling ${IMAGE} ..."
if ! compose pull; then
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
        say "Pull failed, but a local copy of ${IMAGE} exists — using it."
    else
        die "could not pull ${IMAGE}"
    fi
fi

hr
say "Handing over to the container setup wizard."
say "SAVE what it prints: onion address + RPC user + password. That is all"
say "your wallet users need. (Shown again: docker exec monerotor mtor onion)"
hr
compose run --rm setup

hr
ask "Start the node now?" "Y"
case "$REPLY" in
    [Nn]*) say "Later: cd ${DIR} && docker compose up -d" ;;
    *)     compose up -d
           say ""
           say "Node started."
           say "  logs:    cd ${DIR} && docker compose logs -f node"
           say "  status:  docker exec monerotor mtor status"
           say "  onion:   docker exec monerotor mtor onion"
           ;;
esac
hr
say "Initial sync runs over Tor and takes days. To skip it, stop the node and"
say "copy a synced pruned blockchain into: ${MONERO_DIR}"
