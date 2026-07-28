# DEVELOPMENT.md

Maintainer notes: the security contract, architecture, conventions, and the
decisions behind them. Read this before changing anything — `CONTRIBUTING.md`
points reviewers here.

**monerotor** is a single, hardened Docker container running a **Tor-only Monero
node** for a private circle of 1–5 wallet users. One-question setup prints the
onion + RPC login (`monerotor` + random 16-char password). There is **no remote
management surface** (admin is local `docker exec` only — SSH was removed
2026-07-28) and **no backup/restore** (identity is disposable — removed
2026-07-28; see Decisions for both).

**Status:** v0 — builds cleanly; full test checklist passed on an arm64 Mac
(2026-07-28) including setup + double-boot on named volumes (enforcing-fs =
Linux permission semantics). Not yet exercised on a real linux/amd64 host.

The Dockerfile is arch-aware via BuildKit's `TARGETARCH` (amd64 → `x64`/
`x86_64-linux-gnu`, arm64 → `armv8`/`aarch64-linux-gnu`); multi-arch publishing
is just `docker buildx --platform linux/amd64,linux/arm64` later.

---

## Security invariants (the review contract — never break these)

These are the whole point of the project. Any change must preserve all of them:

1. **Fail-closed egress.** The nftables kill-switch drops all output except from
   user `tor`. monerod reaches loopback only.
2. **No published ports.** `docker-compose.yml` must never gain a `ports:` stanza.
   The RPC is reachable only as an onion service.
3. **Tor-only monerod.** monerod runs wrapped in `torsocks` and binds loopback
   only. torsocks + kill-switch are belt-and-suspenders; keep both.
4. **Minimal, justified caps.** node service: `NET_ADMIN, NET_RAW, SETUID, SETGID,
   CHOWN` — nothing else. `read_only` rootfs, `no-new-privileges`. Every daemon
   runs non-root (tor/monero).
5. **Verified binary.** monerod is fetched + GPG/SHA-256 verified at build against
   binaryFate's key **pulled from the monero repo** (keys.openpgp.org strips the
   UID — do not use it). Fingerprint is pinned in the Dockerfile.
6. **No remote management surface.** No SSH, no shell service, no management
   onion — ever. Admin is `docker exec` on the host. Do not add a remote-access
   path of any kind.
7. **Single onion** — the wallet RPC. No other hidden services.
8. **Recent Tor + vanguards.** The build fails if tor is older than
   `TOR_MIN_VERSION`; the vanguards addon must run beside tor (user tor,
   cookie-authed control socket on tmpfs) and be supervised like the daemons.
9. **No backup/restore code — ever.** Nothing in the container may decrypt,
   unpack, or execute an operator-supplied file. The identity is disposable by
   design: fresh setup = new onion + new password. Don't add import/export
   "conveniences".

If you're unsure whether a change violates one of these, it probably does — ask.
`CONTRIBUTING.md` points reviewers back at this list.

---

## Architecture

One container, PID1 = `tini` → `bin/entrypoint`, which dispatches on argv:

- `run` → refuses unless `/data/config/.configured` exists, else execs
  `bin/supervise`: preps the volumes, applies the kill-switch, then starts `tor`,
  `vanguards`, and `torsocks monerod`, each dropped to its user via `su-exec`.
  Polls the three PIDs every 5s and exits if any dies, so Docker restarts the
  container.
- `setup` / `mtor …` → `bin/mtor`: wizard or a management subcommand.

`docker-compose.yml` defines two services from the same image: `node` (hardened,
long-running) and `setup` (profile-gated, on-demand, interactive; caps only
`CHOWN, SETUID, SETGID` — enough to hand the tor dirs over and mint the onion).

`config/torrc` wires the single onion (RPC :18081 → 127.0.0.1:18081) and a
control socket on `/run/tor` (tmpfs) for vanguards. The onion key dir lives on
the `/data/tor` volume. Paths default to `./data/*`; override inline when
needed (`MONERO_DIR=/big/disk docker compose up -d`) — there is deliberately
no `.env` file (one less implicit input; the deploy wizard bakes chosen paths
straight into the compose file it generates).

**Lifecycle:** unconfigured → **wizard** (one prompt: pruned/full; mints the
onion via a short-lived `tor`, prints onion + `monerotor` + random password) ·
configured → run headless; `setup` refuses to overwrite · fresh identity =
delete the data dirs and re-run setup. The `.configured` marker file is the
single source of truth for "configured". State is bind-mounted across three
volumes: `/data/{monero,tor,config}`.

| path | role |
|---|---|
| `Dockerfile` | 2-stage: verify monerod → minimal Alpine runtime (+ tor floor, vanguards) |
| `docker-compose.yml` | `node` (hardened long-run) + `setup` (interactive/mgmt) |
| `config/torrc` | 1 hidden service, loopback SOCKS, control socket for vanguards |
| `config/monerod.conf.default` | pruned, restricted RPC, loopback; wizard appends rpc-login |
| `nftables/killswitch.nft` | fail-closed egress (only `tor` may leave; policy drop) |
| `bin/entrypoint` | mode dispatch (run/setup/mtor) |
| `bin/supervise` | node runtime + supervision |
| `bin/mtor` | wizard, status, onion, set, logs |
| `deploy/monerotor-setup.{sh,ps1}` | host-side install wizards (pull GHCR image, write compose, run setup) |
| `.github/workflows/release.yml` | multi-arch GHCR publish on version tags |

`DESIGN.md` has the full spec, `THREAT_MODEL.md` the scope and residual risks.

---

## Conventions

- **Scripts are POSIX sh for busybox ash** — no bashisms (`[[`, arrays, `wait -n`;
  `local` works in ash but don't rely on it). `shellcheck -s sh` must pass.
- Keep it **reviewable**: small files, comments explaining *why*, no cleverness.
- Never widen the cap set or add a port without updating `THREAT_MODEL.md` and the
  invariants above.
- monerod's restricted-RPC `status` does **not** reliably print `SYNCHRONIZED`;
  detect sync by `Height: A/B` equality or the `100.0%` string, not that word.

## Build / run / lint

```sh
docker compose build
docker compose run --rm -it setup     # wizard; SAVE printed onion + RPC login
docker compose up -d
docker compose logs -f node
docker exec monerotor mtor status     # status needs the node's loopback
```

`Makefile` wraps these (`make build|setup|up|down|logs|status|onion`).

Lint exactly what CI lints:

Use the pinned images — a locally-installed shellcheck may be a different
version than CI and will disagree with it:

```sh
docker run --rm -v "$PWD:/mnt:ro" koalaman/shellcheck:v0.10.0 \
    -s sh /mnt/bin/entrypoint /mnt/bin/supervise /mnt/bin/mtor
docker run --rm -v "$PWD:/mnt:ro" koalaman/shellcheck:v0.10.0 \
    -s bash /mnt/deploy/monerotor-setup.sh
docker run --rm -i hadolint/hadolint < Dockerfile
```

**There is no test suite** — `.github/workflows/ci.yml` runs shellcheck, hadolint,
and a `docker build` smoke job.
There is no way to run "a single test" yet; adding a bats smoke test is on the
roadmap.

---

## TEST CHECKLIST — all passed 2026-07-28 (arm64 Mac, Docker Desktop)

1. ✔ **monerod on musl/Alpine** — official armv8 binary runs under `gcompat`
   (build-stage `--version` check + live sync in the node).
2. ✔ **nftables loads in-container** — `nft -f` succeeds; `su-exec monero wget
   -T5 http://1.1.1.1` times out and the kill-switch drop counter shows exactly
   those packets. tor egresses normally.
3. ✔ **vanguards** — connects to tor over the control socket as user tor
   ("Vanguards 0.3.1 connected to Tor 0.4.9.11 using stem 1.8.2" in docker
   logs), supervised like the other daemons. (Replaced the SSH checklist item
   when SSH was removed.)
4. ✔ **torsocks monerod** — syncs blocks with only tor holding non-loopback
   connections.
5. ✔ **enforcing-fs lifecycle** — setup + boot + restart-boot on named docker
   volumes (real Linux permission semantics; mac bind mounts enforce nothing).
   This is what caught the CAP_DAC_OVERRIDE/CAP_FOWNER boot crashes. (Replaced
   the backup/restore round-trip item when backups were removed.)
6. ✔ **`mtor status` auth** — fixed: it now passes `--rpc-login` from
   `/data/config/rpc_login`. Note it must run in the **node** container
   (`docker exec monerotor mtor status`), not the setup one — the RPC binds the
   node's loopback. Residual `Problem fetching info` noise is the restricted-RPC
   mining-info quirk; the `Height:` line still prints.

Not yet re-tested on linux/amd64 (CI's build job covers the build half).

## Roadmap / TODO

- [x] Write `nftables/killswitch.nft` (was blocking the build).
- [x] Pass the test checklist; fix whatever breaks (admin group, CAP_KILL
      signalling, `mtor status` auth — see Decisions).
- [x] `HEALTHCHECK` (monerod RPC responds) in compose.
- [ ] Optional onion-to-onion peer set (avoid Tor exits for P2P).
- [ ] `mtor set` allowlist (only permit known-safe monerod keys).
- [x] Ship the full GPL-3.0 text as `LICENSE`.
- [ ] Reproducible-build notes; pin Alpine + package digests.
- [ ] I2P option alongside Tor.
- [ ] Tests: a bats/CI smoke test that builds, runs setup non-interactively (env
      seed), and asserts the kill-switch drops non-tor egress.

## Decisions & rationale (don't re-litigate without reason)

- **torsocks AND kill-switch:** app-level + kernel-level defense; either alone is
  weaker.
- **No CAP_KILL — signal via `su-exec`, liveness via `/proc`:** with CAP_KILL
  dropped, root cannot signal (or even `kill -0`) another uid's process. So
  daemons are signalled as their own user (`su-exec tor kill …`) and liveness
  checks use `[ -d /proc/$pid ]`. Don't "simplify" back to bare `kill`/`kill -0`
  and don't add CAP_KILL — the cap set is part of the review contract.
- **monerod shutdown escalation:** while syncing through torsocks, monerod
  wedges on TERM/INT (network threads stuck in SOCKS connects; verified 5min+
  hangs — bare and offline monerod exit in ~2s). `term()` therefore TERMs
  monerod, waits 30s, then SIGKILLs; `db-sync-mode=safe:sync` keeps LMDB
  consistent across the hard kill (verified by resume). compose sets
  `stop_grace_period: 2m` so Docker doesn't SIGKILL PID1 mid-sequence.
- **One container:** portability / single artifact was the explicit goal (a
  two-container Whonix split is more idiomatic but not what we're shipping).
- **SSH removed entirely (2026-07-28):** v0 had dropbear + a second onion +
  a show-once admin keypair; all of it was deleted on the operator's decision.
  Admin is `docker exec` on the host — no remote login surface, no key
  lifecycle. Don't add SSH back (not even "optional"); the OpenSSH-variant
  roadmap item died with it.
- **Tor floor + vanguards addon:** build fails below `TOR_MIN_VERSION`;
  vanguards (pip, pinned, patched for py3.12 — `SafeConfigParser`/`readfp`
  renames in the Dockerfile) runs beside tor for guard-discovery defense.
  It's supervised: if vanguards dies, the container restarts.
- **Root must stay OUT of the service users' dirs:** with the minimal cap set,
  root has neither CAP_DAC_OVERRIDE (can't even enter a 700 tor-owned dir) nor
  CAP_FOWNER (can't chmod another uid's files). The rule in supervise/mtor:
  root only chowns TOP-LEVEL dirs reached through root-owned 755 parents
  (CAP_CHOWN works on any owner); every mkdir/chmod/test *inside* a service
  user's dir runs as that user via `su-exec`. Mac bind mounts enforce none of
  this, so mac runs can't catch regressions — verify with the named-volume boot
  test (setup + two boots on `docker volume` storage = real Linux semantics).
- **Backup/restore removed entirely (2026-07-28):** earlier iterations had an
  age-encrypted identity backup with an interactive restore — i.e. a
  root-privileged decrypt-and-unpack of an operator-supplied file (tar over
  `/`), plus a passphrase lifecycle. Deleted on the operator's decision:
  identity is disposable for a 1–5-user node ("a new instance is a new day").
  Don't reintroduce import/export paths.
- **No application-level decoy/cover traffic (rejected 2026-07-28):** proposal
  was a daily top-100 site list + a random homepage fetch every 30–180s.
  Rejected: a bare periodic homepage GET (no subresources, no human timing) is
  a *fingerprint*, not camouflage; the gain against the real adversary is ~zero
  since all egress is already Tor and block sync dwarfs the decoys; it re-opens
  the parse-external-input surface (invariant 9); and it burns volunteer exit
  bandwidth. Traffic shape is tor's job — `ConnectionPadding 1` /
  `ReducedConnectionPadding 0` are asserted in `config/torrc` instead.
- **Alpine + gcompat:** smallest surface; official monerod binary is glibc.

## History

Converted from a Proxmox-LXC deployment (gateway + node + kill-switch, managed by
`deploy-tor-lab.sh`). This container is the portable, single-artifact successor.
The LXC lessons that carried over: verify binaryFate's key from the repo (not
keyservers); restricted-RPC `status` lacks the `SYNCHRONIZED` string; put the
blockchain on fast local storage, not network storage.
