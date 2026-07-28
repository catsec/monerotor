# monerotor — hardened, Tor-only Monero node in one Alpine container.
# Two stages: (1) fetch + cryptographically verify monerod; (2) minimal runtime.

# ---------- stage 1: verified monerod ----------
FROM alpine:3.20 AS fetch
ARG MONERO_VERSION=0.18.5.1
# binaryFate's release-signing key fingerprint (pinned).
ARG BINARYFATE_FPR=81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92
RUN apk add --no-cache curl gnupg tar
WORKDIR /tmp
RUN set -eux; \
    tarball="monero-linux-x64-v${MONERO_VERSION}.tar.bz2"; \
    curl -fsSLO "https://downloads.getmonero.org/cli/${tarball}"; \
    curl -fsSLO "https://www.getmonero.org/downloads/hashes.txt"; \
    # binaryFate's key WITH its user id (keys.openpgp.org strips it), from the repo:
    curl -fsSL "https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/binaryfate.asc" -o binaryfate.asc; \
    gpg --import binaryfate.asc; \
    gpg --list-keys "${BINARYFATE_FPR}"; \
    gpg --verify hashes.txt; \
    dl="$(sha256sum "${tarball}" | cut -d' ' -f1)"; \
    grep -q "${dl}" hashes.txt; \
    tar xjf "${tarball}"; \
    install -m0755 "monero-x86_64-linux-gnu-v${MONERO_VERSION}/monerod" /usr/local/bin/monerod; \
    /usr/local/bin/monerod --version

# ---------- stage 2: runtime ----------
FROM alpine:3.20

# gcompat = glibc shim so the official monerod binary runs on musl/Alpine.
RUN apk add --no-cache \
        tor torsocks nftables dropbear openssh-keygen su-exec \
        age openssl tini coreutils gcompat ca-certificates \
    && addgroup -S monero \
    && adduser  -S -G monero -H -s /sbin/nologin monero \
    && adduser  -S -h /data/config/home -s /bin/sh admin

COPY --from=fetch /usr/local/bin/monerod /usr/local/bin/monerod
COPY config/torrc                 /etc/tor/torrc
COPY config/monerod.conf.default  /etc/monerod.conf.default
COPY nftables/killswitch.nft      /etc/nftables/killswitch.nft
COPY bin/entrypoint bin/supervise bin/mtor /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint /usr/local/bin/supervise /usr/local/bin/mtor

VOLUME ["/data/monero", "/data/tor", "/data/config", "/data/backups"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint"]
CMD ["run"]
