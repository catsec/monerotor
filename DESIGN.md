# monerotor — design spec (v0, for review)

A single, hardened, portable Docker container that runs a **Monero node reachable
only over Tor**, managed **only over Tor (SSH)**, with a guided setup/backup
lifecycle. Fail-closed: nothing leaves the container except through Tor.

Status: **spec for review** — nothing here is load-bearing until you confirm it.

---

## 1. Threat model (what it defends)

- **Network privacy:** the node's IP is never linked to its Monero traffic or to
  the operator. All egress is Tor; the node is reachable only as onion services.
- **No accidental leak:** even a monerod/ssh misconfig or compromise cannot reach
  the clearnet — an in-container kill-switch drops any non-Tor egress.
- **Portable identity:** the onion addresses, config, and credentials survive a
  move to new hardware via one encrypted backup file.
- **Out of scope:** protecting against a hostile Docker host / hostile kernel
  (the host root can always inspect a container). This is a privacy+integrity
  tool, not a defense against the machine's owner.

## 2. Architecture (one running container)

```
            ┌──────────────────────── monerotor container ────────────────────────┐
            │  PID1: tini → supervise (root, 5 caps only)                          │
            │    ├─ applies nftables kill-switch  (only user 'tor' may egress)     │
            │    ├─ tor          (user tor)   ── publishes 2 onions ───────────────┼──▶ Tor
            │    │     • monero-rpc onion → 127.0.0.1:18081                         │
            │    │     • ssh onion        → 127.0.0.1:2222                          │
            │    ├─ monerod      (user monero, wrapped in torsocks → all via Tor)  │
            │    └─ dropbear     (user admin, rootless, key-only, 127.0.0.1:2222)  │
            │  NO published ports. Reachable ONLY via the two onions.              │
            └──────────────────────────────────────────────────────────────────────┘
   volumes (bind-mounted for portability):  /data/monero  /data/tor  /data/config  /data/backups
```

- **Base:** Alpine (minimal), official monerod binary verified at build (binaryFate
  GPG + signed sha256).
- **monerod over torsocks:** every monerod connection goes through Tor; the
  kill-switch guarantees it even if torsocks is bypassed. Binds only to loopback.
- **Two separate onions:** one for the wallet RPC, a different one for SSH mgmt.
- **SSH = dropbear, rootless, key-only,** exposed only as its onion (no host port).

## 3. Hardening / privilege model

- `cap_drop: ALL`, then `cap_add:` **NET_ADMIN, NET_RAW** (nftables), **SETUID,
  SETGID** (drop PID1→service users), **CHOWN** (one-time volume ownership). Nothing else.
- `read_only: true` rootfs; writable only on the four data volumes + tmpfs `/run`,`/tmp`.
- `no-new-privileges: true`. Default seccomp.
- Every network-facing daemon runs **non-root** (monero, tor, admin).
- **No published ports at all** — the host exposes nothing; reach it over Tor.

## 4. Lifecycle (the state machine you described)

The container behaves differently depending on TTY + state, because the wizard is
interactive but the daemon is headless:

```
              ┌─ configured?  ── yes ──▶  run node (headless; `docker compose up -d`)
 start ──▶────┤
              └─ no ──▶ interactive TTY?
                          ├─ no  ──▶ refuse to start, print:
                          │            "unconfigured — run:  docker compose run -it setup"
                          └─ yes ──▶ SETUP:
                                       ├─ backup file found in /data/config?
                                       │     └─ "Restore from <file>? [Y/n]" → passphrase → restore
                                       └─ else ──▶ WIZARD (prompts, §5) → write config
                                                     → "Set a backup passphrase" → write encrypted backup
                                     then: "Setup complete. Start with: docker compose up -d"
```

- **Unconfigured + no backup** → **wizard** builds the config, then immediately
  prompts a passphrase and writes the first encrypted backup.
- **Unconfigured + backup present in the shared config folder** → offer **restore**,
  prompt passphrase, restore, done.
- **Configured** → node runs headless and auto-restarts.
- **Any config change via `mtor set …`** → applies, then prompts:
  *"Configuration changed — create an updated backup now? [Y/n]"* → passphrase → new backup.

## 5. Wizard prompts (proposed)

1. **SSH public key** for management (required; paste, or path). Key-only, no passwords.
2. **Node type:** pruned (default, ~100 GB) or full (~220 GB+).
3. **RPC login:** auto-generate a random `cake:<pass>` (default) or set your own.
4. **Import existing chain?** note: drop a synced `data.mdb` into the monero volume
   to skip the (slow, over-Tor) initial sync.
5. **Backup passphrase** (used to encrypt the backup; never stored).

Everything else uses hardened defaults (restricted RPC, loopback binds, torsocks,
kill-switch, two onions).

## 6. `mtor` — the utility CLI

| command | who | what |
|---|---|---|
| `mtor setup` | interactive | wizard / restore (auto-detects state) |
| `mtor status` | admin (ssh) | monerod sync status via loopback RPC |
| `mtor onion` | admin (ssh) | print the RPC + SSH onions and RPC login |
| `mtor set <key> <value>` | admin | change a config value → prompts for a fresh backup |
| `mtor backup [file]` | privileged | passphrase-encrypted backup (identity+config) |
| `mtor restore <file>` | privileged | restore from an encrypted backup |
| `mtor logs [n]` | admin | tail monerod log |

## 7. Backup format & portability

- **`age` passphrase-encrypted** (`age -p`) — no key files, just the passphrase.
- **Contains:** the two onion private keys (so your addresses move with you),
  `monerod.conf`, the RPC login, the SSH host key + authorized_keys.
- **Excludes the blockchain** (huge; copy `/data/monero` separately, or re-sync).
- **Restore on new hardware:** drop the `.age` file in `/data/config`, start
  interactively → it offers restore → same onions, same identity.

## 8. Repo layout

```
monerotor/
├── README.md            Dockerfile          docker-compose.yml
├── DESIGN.md (this)     THREAT_MODEL.md     LICENSE (GPL-3.0-or-later)
├── .env.example         .dockerignore       Makefile
├── config/
│   ├── torrc                 (2 hidden services, loopback SOCKS)
│   └── monerod.conf.default  (pruned, restricted RPC, loopback)
├── nftables/killswitch.nft   (only user 'tor' egresses)
└── bin/
    ├── supervise             (PID1: kill-switch → tor → dropbear → monerod)
    ├── entrypoint            (state detection: run | setup | refuse)
    └── mtor                  (wizard, status, onion, set, backup, restore)
```

## 9. Decisions to confirm before I implement

1. **Interactive/headless split** (§4): wizard/restore run via
   `docker compose run -it setup`; the daemon (`up -d`) refuses to start unconfigured.
   OK?
2. **Wizard prompt set** (§5) — anything to add/remove?
3. **SSH server:** dropbear (tiny, rootless — my pick) vs OpenSSH (more knobs, needs
   more caps). OK with dropbear?
4. **Backup excludes the blockchain** (§7) — agreed? (keeps the backup small/portable)
