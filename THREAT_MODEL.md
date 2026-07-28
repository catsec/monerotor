# monerotor — threat model

## Goals

1. **Network-location privacy.** No observer (ISP, peers, the wallet's network
   path) can link the node's IP to its Monero activity or to the operator. All
   egress is Tor; the node is reachable only as onion services.
2. **Fail-closed.** A misconfiguration or a compromise of monerod cannot reach
   the clearnet: the nftables kill-switch permits egress only from the `tor`
   user; everything else is dropped.
3. **Integrity of the binary.** monerod is verified at build against binaryFate's
   OpenPGP-signed hash list; the key is fetched from the Monero repo (not a
   UID-stripping keyserver) and its fingerprint is pinned.
4. **Minimal state worth stealing.** The node holds no wallet keys and no
   backups; its only secrets are one onion key and one RPC password, both
   deliberately disposable — a compromised or lost host is answered by
   re-running setup, not by restoring anything.

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
- **No published ports.** The host exposes nothing. The RPC is an onion service
  only, so there is no LAN/WAN attack surface.
- **No remote management at all.** SSH was removed from the design entirely: no
  login service, no management onion, no admin keypair to protect or lose.
  Management requires local access to the Docker host (`docker exec`). What
  doesn't exist can't be brute-forced, exploited, or misconfigured.
- **Recent Tor + vanguards.** The build fails if tor is older than the pinned
  minimum version, and the vanguards addon runs beside tor (as the tor user,
  over a cookie-authed control socket on tmpfs) to defend the onion service
  against guard-discovery and bandwidth-side-channel attacks.
- **No backup/restore machinery.** Earlier designs restored a passphrase-
  encrypted archive of the onion key — i.e. a root-privileged decrypt-and-unpack
  of an operator-supplied file, and a planted or tampered archive is exactly the
  kind of gift a malicious actor would leave. Deleted wholesale: the identity is
  disposable, so the entire class of file-parsing attacks is gone.
- **Padding is tor's job; no decoy traffic.** `ConnectionPadding 1` /
  `ReducedConnectionPadding 0` are asserted in the torrc so link-level padding
  can't be silently weakened. We deliberately do **not** fetch random websites
  on a timer as cover: a lone periodic homepage GET with no subresources
  matches nothing a real browser does, so it acts as a fingerprint for "this
  host runs monerotor" instead of camouflage; it would also require
  downloading and parsing a third-party site list (the attack class this
  project otherwise refuses) and would spend volunteer Tor exit bandwidth for
  no measurable gain — monerod's own sync traffic already dwarfs it.
- **Minimal capabilities.** Only the five caps the design provably needs; read-only
  rootfs; `no-new-privileges`; non-root daemons.

## Residual risks

- Anyone with control of the Docker host manages the node (`docker exec`) —
  local host security is the management perimeter now, by design.
- Losing the host means a new onion address: your 1–5 wallet users must be
  re-pointed by hand. That inconvenience is the accepted price of having no
  backup/restore surface (nothing that parses operator-supplied files, no
  passphrase to lose or have stolen).
- Tor exit nodes see monerod's clearnet-peer traffic (it's Monero P2P, not your
  identity); onion-to-onion peers avoid exits but need a curated peer set (future
  option).
- `fast` vs `safe:sync` DB mode trades crash-consistency for speed; default is
  `safe:sync`.
