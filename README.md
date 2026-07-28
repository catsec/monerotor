# monerotor

A single, hardened Docker container that runs a **Monero node reachable only over
Tor**, managed **only over Tor (SSH)**, with a guided setup + encrypted backup
lifecycle. Fail-closed: an in-container kill-switch drops anything that isn't Tor.

> Not affiliated with the Monero project. GPL-3.0-or-later. Review before you run
> it — that's the point.

## What you get

- **Tor-only, no leakage.** monerod runs wrapped in `torsocks`, binds only to
  loopback, and an nftables kill-switch drops any egress that isn't the `tor`
  user. No ports are published on the host.
- **Two onions.** One for the wallet's restricted RPC (point Cake at it), a
  **different** one for SSH management.
- **Hardened.** Alpine base; official monerod binary verified at build (binaryFate
  GPG + signed SHA-256); read-only rootfs; `no-new-privileges`; all caps dropped
  except NET_ADMIN, NET_RAW, SETUID, SETGID, CHOWN; every daemon runs non-root.
- **Guided lifecycle.** First run walks a wizard, mints your onions, shows your
  admin SSH key once, and writes a passphrase-encrypted backup. Drop a backup in
  the config folder and it offers to restore instead. Config changes prompt for a
  fresh backup.
- **Portable.** All state is bind-mounted. Move the encrypted backup (identity +
  config) to new hardware and you keep the **same onion addresses**. Copy the
  blockchain folder to skip a fresh sync.

## Quick start

```sh
cp .env.example .env          # optionally edit the data paths
docker compose build
docker compose run --rm -it setup     # wizard: SAVE the printed SSH key + onion
docker compose up -d                  # run the node
```

Manage it over Tor (from a machine with Tor/torsocks):

```sh
torsocks ssh -p 22 admin@<your-ssh-onion>.onion
mtor status         # sync status
mtor onion          # your onions + RPC login
```

Wallet: in Cake, add a custom node → address `<rpc-onion>.onion`, port `18081`,
login `cake`, the password from setup, SSL **off**, with Orbot running.

## Lifecycle

| situation | what happens |
|---|---|
| unconfigured, no backup | **wizard** builds config, mints onions, shows your admin key, writes first backup |
| unconfigured, a `*.age` backup in the config folder | offers to **restore** (passphrase) |
| configured | node runs headless, auto-restarts |
| `mtor set …` | applies change, then offers a **fresh backup** |

## Backups

`mtor backup` writes an **age passphrase-encrypted** file containing your onion
identities, `monerod.conf`, RPC login, SSH host key, and authorized key. It does
**not** contain the blockchain, and does **not** contain your admin SSH *private*
key — that is shown once at setup and kept only by you. Losing it means losing
management access (recover only with host access), so save it.

To move machines: copy the `.age` backup into the new host's config folder and run
`setup` → it restores your identity; copy `data/monero` too if you want to skip the
sync.

## Management commands (`mtor`)

`setup` · `status` · `onion` · `set <key> <value>` · `backup [file]` · `restore
<file>` · `logs [n]`.

## Requirements & caveats

- Docker with the host kernel providing `nf_tables` (standard).
- Initial sync over Tor is slow — copy a pruned `data.mdb` into `data/monero` to
  skip it.
- This protects against network observers, not against the machine's own root.
  See `THREAT_MODEL.md`.

See `DESIGN.md` for the full architecture and `THREAT_MODEL.md` for scope.
