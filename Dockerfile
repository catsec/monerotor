# monerotor — hardened, Tor-only Monero node in one Alpine container.
# Two stages: (1) fetch + cryptographically verify monerod; (2) minimal runtime.

# ---------- stage 1: verified monerod ----------
FROM alpine:3.20 AS fetch
# pipefail so `sha256sum | cut` below can't hide a failure
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG MONERO_VERSION=0.18.5.1
# binaryFate's release-signing key fingerprint (pinned).
ARG BINARYFATE_FPR=81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92
# Set by BuildKit to the platform being built (amd64 on x86 hosts, arm64 on
# Apple Silicon). gcompat so the --version smoke check below can run here too.
ARG TARGETARCH
# package pinning is tracked on the roadmap (reproducible builds); alpine:3.20
# already bounds versions, so skip DL3018 for now
# hadolint ignore=DL3018
RUN apk add --no-cache curl gnupg tar gcompat
WORKDIR /tmp
RUN set -eux; \
    # map Docker arch -> monero release naming (tarball vs. extracted dir)
    case "${TARGETARCH}" in \
        amd64) dist=x64;   triplet=x86_64-linux-gnu ;; \
        arm64) dist=armv8; triplet=aarch64-linux-gnu ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    tarball="monero-linux-${dist}-v${MONERO_VERSION}.tar.bz2"; \
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
    install -m0755 "monero-${triplet}-v${MONERO_VERSION}/monerod" /usr/local/bin/monerod; \
    /usr/local/bin/monerod --version

# ---------- stage 2: runtime ----------
FROM alpine:3.20
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# tor must be recent: >= TOR_MIN_VERSION (vanguards-lite, conflux, current HS
# defenses). The build FAILS if the packaged tor is older.
ARG TOR_MIN_VERSION=0.4.8
# vanguards addon: pins layer2/layer3 guards + bandwidth-side-channel defenses
# for the onion service (guard-discovery attacks). Runs beside tor as user tor.
ARG VANGUARDS_VERSION=0.3.1

# gcompat = glibc shim so the official monerod binary runs on musl/Alpine.
# python3 stays for vanguards; pip is removed after installing it.
# hadolint ignore=DL3018
RUN apk add --no-cache \
        tor torsocks nftables su-exec \
        tini coreutils gcompat ca-certificates \
        python3 py3-pip \
    && pip install --no-cache-dir --break-system-packages "vanguards==${VANGUARDS_VERSION}" \
# vanguards 0.3.1 predates python 3.12: SafeConfigParser/readfp were removed.
# Two mechanical renames (their drop-in py3 successors) make it run clean.
    && sed -i 's/SafeConfigParser/ConfigParser/g; s/\.readfp(/.read_file(/g' \
           /usr/lib/python3*/site-packages/vanguards/config.py \
    && apk del py3-pip \
    && tor --version \
    && ver="$(tor --version | sed -n '1s/^Tor version \([0-9.]*\).*$/\1/p')" \
    && { printf '%s\n%s\n' "${TOR_MIN_VERSION}" "${ver}" | sort -C -V \
         || { echo "tor ${ver} is older than required ${TOR_MIN_VERSION}" >&2; exit 1; }; } \
    && vanguards --help >/dev/null \
    && addgroup -S monero \
    && adduser  -S -G monero -H -s /sbin/nologin monero

COPY --from=fetch /usr/local/bin/monerod /usr/local/bin/monerod
COPY config/torrc                 /etc/tor/torrc
COPY config/monerod.conf.default  /etc/monerod.conf.default
COPY nftables/killswitch.nft      /etc/nftables/killswitch.nft
COPY bin/entrypoint bin/supervise bin/mtor /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint /usr/local/bin/supervise /usr/local/bin/mtor

VOLUME ["/data/monero", "/data/tor", "/data/config"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint"]
CMD ["run"]
