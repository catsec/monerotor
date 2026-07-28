# CLAUDE.md — monerotor project memory

Read this first. It's the working context for developing **monerotor**: a single,
hardened Docker container running a **Tor-only Monero node**, managed over Tor,
with a guided setup + encrypted-backup lifecycle.

**Status:** v0 — code-complete, **not yet exercised on a real Docker host.** The
top priority is the test checklist below, not new features.

---

## Security invariants (the review contract — never break these)

These are the whole point of the project. Any change must preserve all of them:

1. **Fail-closed egress.** The nftables kill-switch (`nftables/killswitch.nft`)
   drops all output except from user `tor`. monerod/dropbear reach loopback only.
2. **No published ports.** `docker-compose.yml` must never gain a `ports:` stanza.
   RPC and SSH are reachable only as onion services.
3. **Tor-only monerod.** monerod runs wrapped in `torsocks` and binds loopback
   only. torsocks + kill-switch are belt-and-suspenders; keep both.
4. **Minimal, justified caps.** node service: `NET_ADMIN, NET_RAW, SETUID, SETGID,
   CHOWN` — nothing else. `read_only` rootfs, `no-new-privileges`. Every daemon
   runs non-root (tor/monero/admin).
5. **Verified binary.** monerod is fetched + GPG/SHA-256 verified at build against
   binaryFate's key **pulled from the monero repo** (keys.openpgp.org strips the
   UID — do not use it). Fingerprint is pinned in the Dockerfile.
6. **Admin private key is never persisted.** Generated at setup, shown once,
   `shred`-ded. The node and the backup keep only the public key.
7. **Two separate onions** — one RPC, one SSH. Never merge them.
8. **Backup contents:** onion identities + config + creds + SSH host key + authorized
   *public* key. **Never** the blockchain, **never** the admin private key.

If you're unsure whether a change violates one of these, it probably does — ask.

---

## Architecture (see DESIGN.md for the full version)

One container, PID1 = `tini` → `bin/entrypoint`:
- `run`  → `bin/supervise`: applies kill-switch, then `tor` + `dropbear` +
  `torsocks monerod`, each dropped to its user via `su-exec`. Monitors; exits if a
  service dies so Docker restarts.
- `setup` → `bin/mtor setup`: interactive wizard or restore.

State is bind-mounted for portability: `/data/{monero,tor,config,backups}`.

## Lifecycle

unconfigured + no backup → **wizard** (prompts, mints onions, shows admin key
once, writes first backup) · unconfigured + `*.age` in config folder → offer
**restore** · configured → run headless · `mtor set` → offer fresh backup.

## File map

| path | role |
|---|---|
| `Dockerfile` | 2-stage: verify monerod → minimal Alpine runtime |
| `docker-compose.yml` | `node` (hardened long-run) + `setup` (interactive/mgmt) |
| `config/torrc` | 2 hidden services, loopback SOCKS |
| `config/monerod.conf.default` | pruned, restricted RPC, loopback; wizard appends rpc-login |
| `nftables/killswitch.nft` | fail-closed egress (only `tor`) |
| `bin/entrypoint` | mode dispatch (run/setup/mtor) |
| `bin/supervise` | node runtime + supervision |
| `bin/mtor` | wizard, status, onion, set, backup, restore, logs |

---

## Conventions

- **Scripts are POSIX sh for busybox ash** — no bashisms (`[[`, arrays, `wait -n`,
  `local` is OK in ash but avoid relying on it). `shellcheck -s sh` must pass.
- Keep it **reviewable**: small files, comments explaining *why*, no cleverness.
- Never widen the cap set or add a port without updating THREAT_MODEL.md and this
  file's invariants.
- monerod's restricted-RPC `status` does **not** reliably print `SYNCHRONIZED`;
  detect sync by `Height: A/B` equality or the `100.0%` string, not that word.

## Build / run / test

```sh
docker compose build
docker compose run --rm -it setup     # wizard; SAVE printed SSH key + onion
docker compose up -d
docker compose logs -f node
docker compose run --rm -it setup mtor status
```

Lint locally: `shellcheck -s sh bin/*` and `hadolint Dockerfile` (CI runs both).

---

## TEST CHECKLIST (do this first — unverified on real Docker)

1. **monerod on musl/Alpine** — `gcompat` is installed; confirm the static binary
   launches. If not, the fix is usually adding a lib or switching to the
   `-static` build.
2. **nftables loads in-container** — needs host `nf_tables` + NET_ADMIN. Confirm
   `nft -f` succeeds and non-tor egress is actually dropped (test:
   `su-exec monero wget -T5 http://1.1.1.1` must fail; `torsocks` path works).
3. **rootless dropbear** — key-only login over the SSH onion as `admin`; verify
   `-r` host key + `authorized_keys` path (admin home = `/data/config/home`).
4. **torsocks monerod** — peers connect; confirm egress is Tor (exit IP), not clear.
5. **backup/restore round-trip** — `setup` service has `DAC_OVERRIDE` to read
   Tor's 0700 dir; confirm the `.age` restores onions intact and the node comes
   back with the same addresses.

## Roadmap / TODO

- [ ] Pass the test checklist; fix whatever breaks.
- [ ] `HEALTHCHECK` (monerod RPC responds) in compose.
- [ ] Optional onion-to-onion peer set (avoid Tor exits for P2P).
- [ ] Optional OpenSSH variant (behind a build arg) for operators who want it.
- [ ] `mtor set` allowlist (only permit known-safe monerod keys).
- [ ] Ship the full GPL-3.0 text as `LICENSE` (currently a header stub).
- [ ] Reproducible-build notes; pin Alpine + package digests.
- [ ] I2P option alongside Tor.
- [ ] Tests: a bats/CI smoke test that builds, runs setup non-interactively (env
      seed), and asserts the kill-switch drops non-tor egress.

## Decisions & rationale (don't re-litigate without reason)

- **torsocks AND kill-switch:** app-level + kernel-level defense; either alone is
  weaker.
- **One container:** portability / single artifact was the explicit goal (a
  two-container Whonix split is more idiomatic but not what we're shipping).
- **dropbear, rootless:** minimal + no SETUID-for-login needed; key-only.
- **Admin private key not stored:** bounds blast radius of a node compromise; the
  cost ("lose key = lose access") is intentional and documented.
- **Backup excludes blockchain:** keeps it small/portable; chain is copied or
  re-synced separately.
- **Alpine + gcompat:** smallest surface; official monerod binary is glibc.

## History

Converted from a Proxmox-LXC deployment (gateway + node + kill-switch, managed by
`deploy-tor-lab.sh`). This container is the portable, single-artifact successor.
The LXC lessons that carried over: verify binaryFate's key from the repo (not
keyservers); restricted-RPC `status` lacks the `SYNCHRONIZED` string; put the
blockchain on fast local storage, not network storage.
