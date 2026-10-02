ARG BASE_IMAGE="python:3.13-alpine"
ARG GIVTCP_VERSION

# -------------------------------------------------
# Single canonical GivTCP checkout, reused by both the node builder stage
# (its Vue config UI) and the final stage (its Python source + requirements).
# -------------------------------------------------
FROM alpine:3.20 AS givtcp-src
ARG GIVTCP_VERSION
WORKDIR /src
ADD https://github.com/britkat1980/giv_tcp.git#${GIVTCP_VERSION} /src

# -------------------------------------------------
# GivTCP's Vue config UI (mirrors GivTCP's own Dockerfile's first stage:
# node:current-alpine there is pinned here instead, everything else the same)
# -------------------------------------------------
FROM node:22-alpine AS node-builder
WORKDIR /app
COPY --from=givtcp-src /src/givtcp-vuejs .
RUN npm install && npm run build && mv dist/index.html dist/config.html

# -------------------------------------------------
# Predbat's own venv
# -------------------------------------------------
FROM ${BASE_IMAGE} AS predbat-builder
WORKDIR /install
COPY requirements/predbat-requirements.txt /requirements.txt

# hadolint ignore=DL3018
RUN set -eux; \
    apk add --no-cache --virtual .build-deps gcc g++ libffi-dev musl-dev; \
    python3 -m venv /opt/predbat-venv; \
    /opt/predbat-venv/bin/pip install --no-cache-dir -r /requirements.txt

# -------------------------------------------------
# GivTCP's own deps, straight from its own (unforked) requirements.txt,
# installed system-wide (--prefix=/install, copied to /usr/local/ below) -
# NOT an isolated venv. GivTCP's own code hardcodes absolute paths like
# /usr/local/bin/gunicorn and /usr/local/bin/python3 when it re-execs its own
# subprocesses (confirmed by grepping its source and by a live boot test that
# failed with FileNotFoundError until this was changed from a venv), so it
# needs its deps on the system path it already expects - exactly matching both
# GivTCP's own upstream Dockerfile and predbat_addon's own existing convention.
# Predbat has no such hardcoded paths (confirmed by the same grep against its
# source) and is always invoked via its own fully-qualified venv path, so
# giving it its own isolated venv above remains safe and conflict-free even
# though GivTCP's deps land in the shared system site-packages.
# No C toolchain here - confirmed via a clean build that every GivTCP
# dependency has a musl wheel available.
# -------------------------------------------------
FROM ${BASE_IMAGE} AS givtcp-builder
WORKDIR /install
COPY --from=givtcp-src /src/requirements.txt /requirements.txt
RUN pip install --no-cache-dir --prefix=/install -r /requirements.txt

# -------------------------------------------------
# s6-overlay builder (identical pattern to predbat_addon's own)
# -------------------------------------------------
FROM ${BASE_IMAGE} AS s6-builder

ARG S6_VERSION=v3.2.3.2
ARG TARGETARCH

WORKDIR /tmp/s6

# hadolint ignore=DL3018
RUN apk add --no-cache ca-certificates xz

ADD https://github.com/just-containers/s6-overlay/releases/download/${S6_VERSION}/s6-overlay-noarch.tar.xz .
ADD https://github.com/just-containers/s6-overlay/releases/download/${S6_VERSION}/s6-overlay-x86_64.tar.xz s6-overlay-amd64.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/${S6_VERSION}/s6-overlay-aarch64.tar.xz s6-overlay-arm64.tar.xz
ADD https://github.com/just-containers/s6-overlay/releases/download/${S6_VERSION}/s6-overlay-arm.tar.xz s6-overlay-arm.tar.xz

RUN set -eux; \
    mkdir -p /s6-root; \
    tar -C /s6-root -Jxpf s6-overlay-noarch.tar.xz; \
    case "${TARGETARCH}" in \
      amd64) tar -C /s6-root -Jxpf s6-overlay-amd64.tar.xz ;; \
      arm64) tar -C /s6-root -Jxpf s6-overlay-arm64.tar.xz ;; \
      arm)   tar -C /s6-root -Jxpf s6-overlay-arm.tar.xz ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac

# -------------------------------------------------
# Final runtime stage
# -------------------------------------------------
FROM ${BASE_IMAGE}

ARG USER_NAME="predbat"
ARG USER_GROUP="predbat"
ARG UID="9005"
ARG GID="9005"
ARG PREDBAT_VERSION
ARG GIVTCP_VERSION
ARG BASE_IMAGE
ARG BUILD_DATE
ARG ADDON_VERSION

WORKDIR /config
# Stays root deliberately: the predbat user/group (UID/GID overridable via
# build args) exists for users to opt into via `docker run --user`, but the
# default here needs to stay root both for mount-ownership compatibility
# (matching predbat_addon's own convention) and because GivTCP's scapy-based
# LAN scan needs raw-socket privileges a non-root user can't cleanly have
# without extra capability grants anyway.
# hadolint ignore=DL3002,DL3066
USER root

# hadolint ignore=DL3018
RUN set -eux; \
    apk add --no-cache gcompat netcat-openbsd git mosquitto musl nginx redis tzdata xsel; \
    addgroup -S -g ${GID} ${USER_GROUP}; \
    adduser -D -u ${UID} -G ${USER_GROUP} ${USER_NAME}; \
    chown -R ${USER_NAME} /config; \
    mkdir -p /run/nginx

# s6-overlay
COPY --from=s6-builder /s6-root/ /

# Python deps - Predbat gets its own isolated venv (see predbat-builder stage);
# GivTCP's deps land in the normal system site-packages (see givtcp-builder
# stage for why) - the two don't actually conflict since Predbat is always
# invoked via its own fully-qualified venv path, never via bare `python3`.
COPY --from=predbat-builder /opt/predbat-venv /opt/predbat-venv
COPY --from=givtcp-builder /install /usr/local/

# Predbat source - fetched straight from GitHub, never vendored, exactly like
# predbat_addon's own Dockerfile.alpine
ADD --chown=${USER_NAME} \
    https://github.com/springfall2008/batpred.git#$PREDBAT_VERSION:apps/predbat/ \
    https://github.com/springfall2008/batpred.git#$PREDBAT_VERSION:apps/predbat/config/ \
    /addon/
COPY --chown=${USER_NAME} rootfs/predbat/run.docker.sh /addon/run.docker.sh

# GivTCP source - fetched straight from GitHub, never vendored
COPY --from=givtcp-src /src /app
COPY --from=node-builder /app/dist/ /app/ingress/
COPY rootfs/givtcp/run.docker.sh /app/run.docker.sh

# nginx config - matches GivTCP's own Dockerfile exactly. Alpine's nginx apk
# package ships its own default.conf bound to port 80, which conflicts with
# GivTCP's own ingress.conf/ingress_no_ssl.conf if left in place (confirmed
# live: omitting this caused repeated "bind() to 0.0.0.0:80 failed (Address in
# use)" errors at boot).
COPY --from=givtcp-src /src/ingress.conf /etc/nginx/http.d/
COPY --from=givtcp-src /src/ingress_no_ssl.conf /app/ingress_no_ssl.conf
RUN rm -f /etc/nginx/http.d/default.conf

# Upstream GivTCP (britkat1980/giv_tcp, confirmed broken on tag 3.5 and main as
# of 2026-10) imports a module path pymodbus removed in its 3.x rewrite:
#   startup.py:14 and GivTCP/evc.py:2 both do
#   `from pymodbus.client.sync import ModbusTcpClient`
# requirements.txt pins no pymodbus version, so pip always resolves to
# whatever's latest on PyPI (currently 3.15.0) - this breaks on every build
# regardless of which GivTCP ref is chosen, and there is no newer upstream fix
# to wait for (confirmed broken on main too). We carry this patch ourselves
# indefinitely - see README "Known upstream issues". The grep guard below
# fails the build loudly if a future GivTCP release moves/duplicates the
# broken import in a way this sed no longer catches, instead of silently
# shipping an image with the exact crash this patch exists to prevent.
RUN set -eux; \
    sed -i 's/from pymodbus\.client\.sync import ModbusTcpClient/from pymodbus.client import ModbusTcpClient/' \
        /app/startup.py /app/GivTCP/evc.py; \
    if grep -rl 'pymodbus\.client\.sync' /app; then \
        echo "ERROR: pymodbus.client.sync still present after patch - GivTCP source changed, update this Dockerfile's sed patch" >&2; \
        exit 1; \
    fi

# s6 service definitions
COPY rootfs/docker/s6-rc/ /etc/s6-overlay/s6-rc.d/
COPY rootfs/docker/user-bundles.d/ /etc/s6-overlay/user-bundles.d/

# Define build arguments and labels
LABEL \
    maintainer="nipar4 (https://github.com/nipar4/predbat-givtcp-addon)" \
    org.opencontainers.image.title="Predbat + GivTCP combined image" \
    org.opencontainers.image.description="Home Battery Prediction and Control (Predbat) combined with a GivEnergy inverter bridge (GivTCP) in a single image" \
    org.opencontainers.image.authors="springfall2008, britkat1980, nipar4" \
    org.opencontainers.image.url="https://github.com/nipar4/predbat-givtcp-addon" \
    org.opencontainers.image.source="https://github.com/nipar4/predbat-givtcp-addon" \
    org.opencontainers.image.documentation="https://github.com/nipar4/predbat-givtcp-addon/blob/main/README.md" \
    org.opencontainers.image.created=${BUILD_DATE} \
    org.opencontainers.image.base.digest=${BASE_IMAGE} \
    org.opencontainers.image.version=${ADDON_VERSION}

ENTRYPOINT ["/init"]
