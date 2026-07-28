# monerotor

A single, hardened Docker container that runs a **Monero node reachable only over
Tor**, for you and a handful of trusted wallet users. Fail-closed: an
in-container kill-switch drops anything that isn't Tor. **No remote management
surface at all** — admin happens locally via `docker exec`. Setup is one
question; everything your users need fits on three lines (onion, user, password).

> Not affiliated with the Monero project. GPL-3.0-or-later. Review before you run
> it — that's the point.

## What you get

- **Tor-only, no leakage.** monerod runs wrapped in `torsocks`, binds only to
  loopback, and an nftables kill-switch drops any egress that isn't the `tor`
  user. No ports are published on the host.
- **One onion, nothing else.** A single hidden service for the wallet's
  restricted RPC (point Cake at it). No SSH, no shell service, no second
  onion — management is local `docker exec` only, so there is nothing remote
  to attack.
- **Guarded Tor.** The build fails unless tor meets a minimum version, and the
  [vanguards](https://github.com/mikeperry-tor/vanguards) addon runs beside tor
  to defend the onion service against guard-discovery attacks.
- **Hardened.** Alpine base; official monerod binary verified at build (binaryFate
  GPG + signed SHA-256); read-only rootfs; `no-new-privileges`; all caps dropped
  except NET_ADMIN, NET_RAW, SETUID, SETGID, CHOWN; every daemon runs non-root.
- **One-question setup.** The wizard asks pruned-or-full, then prints the three
  things your wallet users need: the onion address, the RPC user (`monerotor`)
  and a random 16-char password. Nothing else to decide, nothing to paste in.
- **Disposable identity — no backups, on purpose.** There is no backup/restore
  and no passphrase to manage. If the host dies, run setup again and hand out
  the new address: a new instance is a new day. This deletes a whole attack
  class (nothing that parses operator-supplied files, nothing to steal) and is
  the right trade for a private 1–5-user node. The blockchain survives in its
  own folder either way and can be copied between machines to skip a re-sync.
- **x86_64 and arm64** (Apple Silicon included) — the verified monerod binary is
  selected per architecture at build time.

## Install

You need **Docker** and about 100 GB of free disk (pruned). The install script
pulls the pre-built image from GHCR, writes a `docker-compose.yml`, runs the
setup wizard, and starts the node. It asks three things: where to install,
where to keep the blockchain, and pruned-or-full.

<details open>
<summary><b>Linux</b></summary>

Install Docker Engine + the compose plugin if you don't have them
([docs](https://docs.docker.com/engine/install/)), then:

```sh
curl -fsSLO https://raw.githubusercontent.com/catsec/monerotor/main/deploy/monerotor-setup.sh
less monerotor-setup.sh            # read it first — it's a security tool
sh monerotor-setup.sh
```

If your user isn't in the `docker` group, run the script with `sudo` (the data
folders will then be root-owned, which is fine).
</details>

<details open>
<summary><b>macOS</b> (Intel and Apple Silicon)</summary>

Install [Docker Desktop](https://docs.docker.com/desktop/install/mac-install/)
and start it, then:

```sh
curl -fsSLO https://raw.githubusercontent.com/catsec/monerotor/main/deploy/monerotor-setup.sh
less monerotor-setup.sh            # read it first — it's a security tool
sh monerotor-setup.sh
```

Keep the blockchain on the internal SSD; an external/network drive will make
sync painfully slow. Docker Desktop's VM needs a disk image large enough for
it — raise **Settings → Resources → Virtual disk limit** above ~120 GB.
</details>

<details open>
<summary><b>Windows</b></summary>

Install [Docker Desktop](https://docs.docker.com/desktop/install/windows-install/)
with the **WSL 2** backend (the default) and start it. Then in PowerShell:

```powershell
irm https://raw.githubusercontent.com/catsec/monerotor/main/deploy/monerotor-setup.ps1 -OutFile monerotor-setup.ps1
notepad monerotor-setup.ps1        # read it first — it's a security tool
powershell -ExecutionPolicy Bypass -File .\monerotor-setup.ps1
```

Keep the data on a native Windows path (e.g. `C:\monerotor`) — Docker Desktop
maps it into WSL for you. Make sure Docker Desktop is set to **Linux
containers** (default).
</details>

### Manual install (any platform)

If you'd rather not run a script, do exactly what it does:

```sh
mkdir -p ~/monerotor && cd ~/monerotor
curl -fsSLO https://raw.githubusercontent.com/catsec/monerotor/main/docker-compose.yml
docker compose pull                    # or: docker compose build
docker compose run --rm -it setup      # wizard — SAVE what it prints
docker compose up -d
```

The shipped `docker-compose.yml` builds from source by default. To use the
pre-built image instead, replace the two `build: .` lines with
`image: ghcr.io/catsec/monerotor:latest`, or just clone the repo and build:

```sh
git clone https://github.com/catsec/monerotor && cd monerotor
docker compose build
```

Data lands in `./data/*`. To put the blockchain elsewhere:
`MONERO_DIR=/big/disk/monero docker compose up -d`.

## Using it

The wizard prints three things — that's the whole handoff to your wallet users:

```
Onion address:  <56-chars>.onion
Port:           18081
RPC user:       monerotor
RPC password:   <16 random chars>
```

**Cake Wallet / Monero.com** (iOS, Android): Settings → Nodes → **+** →
address `<your-onion>.onion`, port `18081`, username `monerotor`, password as
printed, **SSL off**, and enable **"Connect via Tor"** (or run
[Orbot](https://orbot.app) in VPN mode). Tap the node to make it active.

**Feather / Monero GUI** (desktop): point the daemon at `<your-onion>.onion:18081`
with the same credentials, and set the SOCKS5 proxy to your local Tor
(`127.0.0.1:9050`). In the Monero GUI that's Settings → Node → *Remote node* plus
`--proxy 127.0.0.1:9050`.

Onion addresses only resolve through Tor — that's the point. A wallet without
Tor enabled simply won't connect.

## Managing it

All admin is local on the Docker host; there is deliberately no remote way in:

```sh
docker exec monerotor mtor status     # sync status (runs in the node container —
                                      # the RPC listens on its loopback only)
docker exec monerotor mtor onion      # onion address + RPC login, any time
docker exec monerotor mtor logs 200   # tail the monerod log
docker exec monerotor mtor set <key> <value>   # tweak monerod.conf, then restart

cd ~/monerotor                        # where the compose file lives
docker compose logs -f node           # follow container logs
docker compose restart node           # apply a config change
docker compose pull && docker compose up -d    # update to a new release
docker compose down                   # stop
```

Expect the **first sync to take days** over Tor — that is normal and it
resumes safely across restarts. To skip it, stop the node and copy a synced
pruned `data.mdb` into the blockchain folder.

## Lifecycle

| situation | what happens |
|---|---|
| unconfigured | **wizard**: one question, mints your onion, prints onion + user + password |
| configured | node runs headless, auto-restarts; `setup` refuses to overwrite |
| want a fresh identity | stop the node, delete the data folders, run setup again |

There is deliberately **no backup/restore**: nothing that decrypts and unpacks
operator-supplied files ever runs, and there is no passphrase whose loss or
theft matters. Save the three printed lines somewhere safe (`mtor onion`
re-prints them); if the machine is lost, a fresh setup gives your users a new
address. Keep `data/monero` if you want to move the synced chain to new
hardware — it's just a folder copy.

## Management commands (`mtor`)

`setup` · `status` · `onion` · `set <key> <value>` · `logs [n]` — all local,
via `docker exec monerotor mtor …`.

## Requirements & caveats

- **Docker** (Engine + compose plugin on Linux, Docker Desktop on macOS/Windows)
  with a host kernel providing `nf_tables` — standard everywhere, including
  Docker Desktop's VM.
- **Disk:** ~100 GB pruned, ~220 GB+ full, and growing. Put it on a fast local
  disk; network storage makes sync miserable.
- **Platforms:** `linux/amd64` and `linux/arm64` images are published; on
  macOS/Windows they run in Docker Desktop's Linux VM.
- Initial sync over Tor takes days — copy a pruned `data.mdb` into the
  blockchain folder to skip it.
- This protects the node's **network location**, not against the machine's own
  root, and not on-chain privacy (that's Monero's job). See `THREAT_MODEL.md`.
- The container needs `NET_ADMIN`/`NET_RAW` to install its own kill-switch. If
  your host forbids that, the node will refuse to start rather than run
  unprotected — by design.

## Verifying what you run

```sh
git clone https://github.com/catsec/monerotor && cd monerotor
docker compose build          # reproduces the image locally
```

The build itself verifies monerod: it fetches the official binary, imports
binaryFate's key **from the monero-project repo** (not a keyserver), checks the
pinned fingerprint `81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92`, verifies the
signed `hashes.txt`, and matches the tarball's SHA-256 against it. The build
also fails if the packaged Tor is older than the pinned minimum.

## Docs

- `DESIGN.md` — architecture and the full spec
- `THREAT_MODEL.md` — what it defends, what it doesn't, residual risks
- `DEVELOPMENT.md` — security invariants (the review contract) and decisions
- `CONTRIBUTING.md` — ground rules for PRs
