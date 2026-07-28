# monerotor deploy wizard — Windows (PowerShell 5.1+ / pwsh).
#
# Pulls the pre-built multi-arch image from GHCR and deploys it: asks where to
# keep the data, writes a docker-compose.yml, then hands over to the
# in-container setup wizard (prints onion address + RPC user + password).
#
# Requires Docker Desktop with WSL2 (Linux containers — the default).
#
# Usage:   powershell -ExecutionPolicy Bypass -File .\monerotor-setup.ps1
# Env:     $env:MONEROTOR_IMAGE   override the image
#          (default ghcr.io/catsec/monerotor:latest)

$ErrorActionPreference = "Stop"

$Image = if ($env:MONEROTOR_IMAGE) { $env:MONEROTOR_IMAGE } else { "ghcr.io/catsec/monerotor:latest" }

function Hr  { Write-Host ("-" * 70) }
function Die ($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Ask ($prompt, $default) {
    $r = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($r)) { return $default }
    return $r
}

# --- sanity: docker + running daemon + compose v2 ---
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Die "docker not found. Install Docker Desktop first: https://docs.docker.com/get-docker/"
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { Die "the docker daemon is not running (start Docker Desktop)." }
docker compose version *> $null
if ($LASTEXITCODE -ne 0) { Die "docker compose v2 not found (it ships with Docker Desktop)." }

Hr
Write-Host "monerotor deploy wizard"
Write-Host "image: $Image"
Hr

# --- where does everything live? ---
$Dir = Ask "Install directory (compose file, config)" "$env:USERPROFILE\monerotor"

# Existing install -> offer update instead of clobbering.
if (Test-Path (Join-Path $Dir "docker-compose.yml")) {
    Write-Host "An existing monerotor install was found in $Dir."
    $a = Ask "[U]pdate image + restart, [R]e-run container setup, or [Q]uit?" "U"
    Set-Location $Dir
    switch -Wildcard ($a) {
        "R*" { docker compose run --rm setup; exit 0 }
        "Q*" { exit 0 }
        default {
            docker compose pull
            docker compose up -d
            Write-Host "Updated and restarted. Logs: docker compose logs -f node"
            exit 0
        }
    }
}

Write-Host ""
Write-Host "The blockchain is the big one: ~100 GB pruned (~220 GB+ full), and it"
Write-Host "grows. Put it on a disk with room. Everything else is tiny."
$MoneroDir = Ask "Blockchain directory" (Join-Path $Dir "data\monero")

Hr
Write-Host "Install dir:     $Dir"
Write-Host "Blockchain dir:  $MoneroDir"
$a = Ask "Proceed?" "Y"
if ($a -like "N*" -or $a -like "n*") { exit 0 }

$TorDir    = Join-Path $Dir "data\tor"
$ConfigDir = Join-Path $Dir "data\config"
foreach ($d in @($Dir, $MoneroDir, $TorDir, $ConfigDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# --- compose file: image-based mirror of the repo's docker-compose.yml, with
# the chosen paths baked in (one file, no .env, nothing implicit).
# KEEP IN SYNC with the repo compose file: same caps, same hardening, and
# never a 'ports:' stanza — the node is reachable only as onion services.
@"
# monerotor — deployed from the pre-built image (written by the deploy wizard).
# Manage:  docker exec monerotor mtor <status|onion|logs|set ...>
# Fresh start: down, delete the data folders, re-run the deploy wizard.

services:
  node:
    image: "$Image"
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
      - "${MoneroDir}:/data/monero"
      - "${TorDir}:/data/tor"
      - "${ConfigDir}:/data/config"
    healthcheck:
      test: ["CMD", "sh", "-c", "mtor status | grep -q 'Height:'"]
      interval: 60s
      timeout: 30s
      retries: 5
      start_period: 5m
    # Intentionally NO 'ports:' — the host exposes nothing.

  setup:
    image: "$Image"
    profiles: ["setup"]
    command: ["setup"]
    cap_drop: ["ALL"]
    cap_add: ["CHOWN", "SETUID", "SETGID"]
    volumes:
      - "${MoneroDir}:/data/monero"
      - "${TorDir}:/data/tor"
      - "${ConfigDir}:/data/config"
"@ | Set-Content -Encoding ascii (Join-Path $Dir "docker-compose.yml")

Set-Location $Dir
Hr
Write-Host "Pulling $Image ..."
docker compose pull
if ($LASTEXITCODE -ne 0) {
    docker image inspect $Image *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Pull failed, but a local copy of $Image exists - using it."
    } else {
        Die "could not pull $Image"
    }
}

Hr
Write-Host "Handing over to the container setup wizard."
Write-Host "SAVE what it prints: onion address + RPC user + password. That is all"
Write-Host "your wallet users need. (Shown again: docker exec monerotor mtor onion)"
Hr
docker compose run --rm setup

Hr
$a = Ask "Start the node now?" "Y"
if ($a -like "N*" -or $a -like "n*") {
    Write-Host "Later: cd $Dir ; docker compose up -d"
} else {
    docker compose up -d
    Write-Host ""
    Write-Host "Node started."
    Write-Host "  logs:    cd $Dir ; docker compose logs -f node"
    Write-Host "  status:  docker exec monerotor mtor status"
    Write-Host "  onion:   docker exec monerotor mtor onion"
}
Hr
Write-Host "Initial sync runs over Tor and takes days. To skip it, stop the node and"
Write-Host "copy a synced pruned blockchain into: $MoneroDir"
