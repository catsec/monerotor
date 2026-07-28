# monerotor — threat model

## Goals

1. **Network-location privacy.** No observer (ISP, peers, the wallet's network
   path) can link the node's IP to its Monero activity or to the operator. All
   egress is Tor; the node is reachable only as onion services.
2. **Fail-closed.** A misconfiguration or a compromise of monerod/dropbear cannot
   reach the clearnet: the nftables kill-switch permits egress only from the `tor`
   user; everything else is dropped.
3. **Integrity of the binary.** monerod is verified at build against binaryFate's
   OpenPGP-signed hash list; the key is fetched from the Monero repo (not a
   UID-stripping keyserver) and its fingerprint is pinned.
4. **Portable, recoverable identity.** Onion identities + config survive hardware
   moves via one passphrase-encrypted backup.

## Non-goals / out of scope

- **A hostile Docker host / kernel.** Whoever controls the host root or kernel can
  observe or subvert any container. monerotor defends the node's *network* privacy,
  not against the machine's owner.
- **On-chain privacy.** That is Monero's protocol (RingCT, stealth addresses), not
  this container. monerotor only ensures the *transport* is Tor.
- **Anonymity of the operator to the Tor network itself.** Running an onion service
  reveals to your guard relay that *some* hidden service is hosted from your IP; it
  does not reveal *which* onion to clients.

## Key design choices (and why)

- **torsocks + kill-switch (belt and suspenders).** torsocks routes every monerod
  connection through Tor; the kill-switch guarantees it even if torsocks is
  bypassed or a bug opens a socket directly.
- **No published ports.** The host exposes nothing. Management and RPC are onion
  services only, so there is no LAN/WAN attack surface.
- **Rootless, key-only SSH (dropbear) on a separate onion.** Management can't be
  brute-forced (key-only), isn't on the clearnet, and is isolated from the RPC
  onion so knowing one doesn't reveal the other.
- **Admin private key never stored.** Generated at setup, shown once, shredded.
  The node keeps only the public key; the backup keeps only the public key. This
  bounds the blast radius of a node compromise (an attacker can't exfiltrate your
  login key) at the cost of "lose the key = lose access."
- **Minimal capabilities.** Only the five caps the design provably needs; read-only
  rootfs; `no-new-privileges`; non-root daemons.

## Residual risks

- The admin SSH *private* key lives on your client — protect it there.
- The passphrase-encrypted backup is only as strong as the passphrase.
- Tor exit nodes see monerod's clearnet-peer traffic (it's Monero P2P, not your
  identity); onion-to-onion peers avoid exits but need a curated peer set (future
  option).
- `fast` vs `safe:sync` DB mode trades crash-consistency for speed; default is
  `safe:sync`.
