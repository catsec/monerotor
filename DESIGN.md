# monerotor — design spec (v0, for review)

A single, hardened, portable Docker container that runs a **Monero node reachable
only over Tor**, for a private circle of 1–5 wallet users. Fail-closed: nothing
leaves the container except through Tor. **There is no remote management
surface** — admin is local `docker exec` only — and **no backup/restore
machinery**: the onion identity is deliberately disposable.

Status: **spec for review** — nothing here is load-bearing until you confirm it.

---

## 1. Threat model (what it defends)

- **Network privacy:** the node's IP is never linked to its Monero traffic or to
  the operator. All egress is Tor; the node is reachable only as an onion service,
  and the vanguards addon defends that onion against guard-discovery attacks.
- **No accidental leak:** even a monerod misconfig or compromise cannot reach
  the clearnet — an in-container kill-switch drops any non-Tor egress.
- **No remote management surface:** nothing to brute-force or exploit remotely;
  admin requires being on the Docker host (`docker exec`).
- **Disposable identity:** there is nothing to back up, restore, or steal. A
  lost host means re-running the one-question setup and handing 1–5 users a new
  address. No code path ever decrypts or unpacks an operator-supplied file.
- **Out of scope:** protecting against a hostile Docker host / hostile kernel
  (the host root can always inspect a container). This is a privacy+integrity
  tool, not a defense against the machine's owner.

## 2. Architecture (one running container)

```
            ┌──────────────────────── monerotor container ────────────────────────┐
            │  PID1: tini → supervise (root, 5 caps only)                          │
            │    ├─ applies nftables kill-switch  (only user 'tor' may egress)     │
            │    ├─ tor          (user tor)   ── publishes 1 onion ────────────────┼──▶ Tor
            │    │     • monero-rpc onion → 127.0.0.1:18081                         │
            │    ├─ vanguards    (user tor, control socket, guard-discovery guard) │
            │    └─ monerod      (user monero, wrapped in torsocks → all via Tor)  │
            │  NO published ports. NO ssh. Reachable ONLY via the RPC onion.       │
            └──────────────────────────────────────────────────────────────────────┘
   volumes (bind-mounted):  /data/monero  /data/tor  /data/config
   management: docker exec monerotor mtor …   (local host only, by design)
```

- **Base:** Alpine (minimal), official monerod binary verified at build (binaryFate
  GPG + signed sha256).
- **monerod over torsocks:** every monerod connection goes through Tor; the
  kill-switch guarantees it even if torsocks is bypassed. Binds only to loopback.
- **One onion only:** the wallet RPC. No management onion exists.
- **Tor kept honest:** the build fails if the packaged tor is older than the
  pinned minimum, and the vanguards addon (as user tor, over a tor-only control
  socket) pins guard layers and watches for onion-service attacks.

## 3. Hardening / privilege model

- `cap_drop: ALL`, then `cap_add:` **NET_ADMIN, NET_RAW** (nftables), **SETUID,
  SETGID** (drop PID1→service users), **CHOWN** (one-time volume ownership). Nothing else.
- `read_only: true` rootfs; writable only on the three data volumes + tmpfs `/run`,`/tmp`.
- `no-new-privileges: true`. Default seccomp.
- Every network-facing daemon runs **non-root** (monero, tor).
- **No published ports at all** — the host exposes nothing; the wallet reaches
  the RPC over Tor; the operator manages via `docker exec` on the host.

## 4. Lifecycle (the state machine you described)

The container behaves differently depending on TTY + state, because the wizard is
interactive but the daemon is headless:

```
              ┌─ configured?  ── yes ──▶  run node (headless; `docker compose up -d`)
 start ──▶────┤
              └─ no ──▶ interactive TTY?
                          ├─ no  ──▶ refuse to start, print:
                          │            "unconfigured — run:  docker compose run -it setup"
                          └─ yes ──▶ WIZARD (one prompt, §5) → write config
                                       → mint onion → PRINT onion + user + password
                                     then: "Setup complete. Start with: docker compose up -d"
```

- **Unconfigured** → **wizard**: one question, then it prints the three lines
  the wallet users need. `mtor onion` re-prints them any time.
- **Configured** → node runs headless and auto-restarts; `setup` refuses to
  overwrite an existing identity.
- **Fresh start** → stop the node, delete the data folders, run setup again
  (new onion, new password — a new instance is a new day).

## 5. Wizard prompts

1. **Node type:** pruned (default, ~100 GB) or full (~220 GB+).

That is the only question. The RPC login is fixed-user `monerotor` plus a
random 16-char `[a-z0-9]` password — never asked, only printed. (To skip the
slow over-Tor initial sync, drop a synced `data.mdb` into the monero volume.)
Everything else uses hardened defaults (restricted RPC, loopback binds,
torsocks, kill-switch, single onion, vanguards).

## 6. `mtor` — the utility CLI

All management is local: `docker exec monerotor mtor …` on the running node;
only the first-run wizard uses the on-demand setup container.

| command | where | what |
|---|---|---|
| `mtor setup` | setup container (tty) | one-question wizard; refuses if configured |
| `mtor status` | node container | monerod sync status via loopback RPC |
| `mtor onion` | node container | print the RPC onion and RPC login |
| `mtor set <key> <value>` | node container | change a monerod.conf value (restart to apply) |
| `mtor logs [n]` | node container | tail monerod log |

## 7. No backups — identity is disposable

There is deliberately no backup/restore. The earlier design encrypted the onion
key + config into a passphrase-protected file that setup would offer to
restore; that meant a root-privileged decrypt-and-unpack of an
operator-supplied file — the most attackable code in the project — plus a
passphrase whose loss or theft mattered. For a private 1–5-user node the right
trade is deletion: lose the host → re-run setup → hand out the new address.
The blockchain lives in its own volume and can be folder-copied to new
hardware to skip a re-sync.

## 8. Repo layout

```
monerotor/
├── README.md            Dockerfile          docker-compose.yml
├── DESIGN.md (this)     THREAT_MODEL.md     LICENSE (GPL-3.0-or-later)
├── .dockerignore        Makefile            CONTRIBUTING.md
├── config/
│   ├── torrc                 (1 hidden service, loopback SOCKS, control socket)
│   └── monerod.conf.default  (pruned, restricted RPC, loopback)
├── nftables/killswitch.nft   (only user 'tor' egresses)
├── deploy/                   (host-side install wizards: bash + powershell)
└── bin/
    ├── supervise             (PID1: kill-switch → tor → vanguards → monerod)
    ├── entrypoint            (state detection: run | setup | refuse)
    └── mtor                  (wizard, status, onion, set, logs)
```

## 9. Decisions (settled)

1. **Interactive/headless split** (§4): the wizard runs via
   `docker compose run -it setup`; the daemon (`up -d`) refuses to start unconfigured.
2. **No remote management.** SSH (dropbear + its onion + admin keypair) was in
   the original design and was deliberately removed: admin is `docker exec` on
   the host, eliminating the whole remote-login attack surface and the key
   lifecycle that came with it.
3. **Tor version floor + vanguards** (§2): build-time minimum version check;
   vanguards addon runs beside tor for onion-service guard defense.
4. **No backup/restore** (§7): backup + restore + passphrase were in earlier
   iterations and were deliberately deleted — the identity is disposable, and
   no code ever unpacks an operator-supplied file.
