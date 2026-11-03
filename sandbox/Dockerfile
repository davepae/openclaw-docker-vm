# OpenClaw agent sandbox for the openclaw VM.
# Sandboxes run with no network during the PoC, so every tool is baked in here.
# Build with ./sandbox/install.sh, which also smoke-tests it.

FROM node:24.22.1-trixie-slim@sha256:43b9ba1142b8dcf33fa8f922ca1be85714adc444e0586c7cf7726daaeabc1bea AS node

# Same Debian base digest OpenClaw's own sandbox image uses.
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# Base tools, compilers, Go, Rust, Python, PDF command-line utilities, and
# headless LibreOffice (Writer, Calc, Impress) with metric-compatible fonts
# for Office documents (Liberation: Arial/Times/Courier; Carlito: Calibri;
# Caladea: Cambria).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl wget git jq ripgrep fd-find file less tree procps \
      unzip zip xz-utils \
      build-essential pkg-config cmake \
      python3 python3-venv python3-dev python3-pip \
      golang-go \
      rustc cargo \
      poppler-utils qpdf ghostscript \
      libreoffice-writer-nogui libreoffice-calc-nogui libreoffice-impress-nogui \
      fonts-dejavu-core fonts-liberation fonts-crosextra-carlito fonts-crosextra-caladea \
      libffi-dev libssl-dev libjpeg-dev zlib1g-dev libxml2-dev libxslt1-dev \
 && rm -rf /var/lib/apt/lists/*

# Node 24 from the official image, plus pnpm.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && npm install -g --no-fund --no-audit pnpm \
 && node --version && npm --version && pnpm --version

# Python libraries in a venv (Debian blocks pip installs into system Python).
COPY requirements.txt /opt/requirements.txt
RUN python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
 && /opt/venv/bin/pip install --no-cache-dir -r /opt/requirements.txt \
 && /opt/venv/bin/pip freeze > /opt/venv/requirements.lock

COPY profile.sh /etc/profile.d/openclaw-sandbox.sh
COPY libreoffice-registrymodifications.xcu /etc/openclaw-sandbox/libreoffice-registrymodifications.xcu

# UID/GID 1000 matches /srv/openclaw/workspace on the host.
RUN groupadd -g 1000 sandbox && useradd -u 1000 -g 1000 -m -s /bin/bash sandbox

ENV VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:/usr/local/bin:/usr/bin:/bin

USER sandbox
WORKDIR /workspace
CMD ["sleep", "infinity"]
