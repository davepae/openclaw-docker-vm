#!/usr/bin/env bash
# Phase 3 — build the agent sandbox image, install the web plugins, and turn
# sandboxing on. Run on the VM as ocadmin from the repo:  ./sandbox/install.sh
# Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

SANDBOX_IMAGE="openclaw-sandbox-local:1"   # must match agents.defaults.sandbox.docker.image
log() { printf '\n==> %s\n' "$*"; }

[[ $EUID -ne 0 ]] || { echo "Run as ocadmin, not with sudo."; exit 1; }
[[ -f compose/.env ]] || { echo "Run ./compose/install.sh (Phase 2) first."; exit 1; }
VERSION="$(sed -n "s/^OPENCLAW_VERSION=//p" compose/.env | tail -1 | tr -d "'")"
GW_IMAGE="openclaw-gateway-local:${VERSION}"
docker image inspect "$GW_IMAGE" >/dev/null 2>&1 || { echo "Gateway image $GW_IMAGE missing; run ./compose/install.sh first."; exit 1; }

# --- 1. Sandbox image ----------------------------------------------------------
log "Building ${SANDBOX_IMAGE} (first build takes several minutes)"
docker build -t "$SANDBOX_IMAGE" sandbox/

log "Smoke-testing the image under sandbox restrictions (no network, read-only root, UID 1000)"
ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
docker run --rm --network none --read-only \
  --tmpfs /tmp --tmpfs /var/tmp --tmpfs /run \
  --cap-drop ALL --security-opt no-new-privileges \
  --user 1000:1000 -v "$ws:/workspace" -w /workspace \
  "$SANDBOX_IMAGE" sh -lc '
set -eu
echo "python  $(python3 --version 2>&1)"
python3 -c "import pypdf, pdfplumber, fitz, pikepdf, reportlab, docx, pptx, openpyxl, numpy, pandas, scipy, matplotlib, PIL, bs4, lxml, yaml, jinja2, requests, httpx, pydantic, rich"
python3 - <<PY
from reportlab.pdfgen import canvas
c = canvas.Canvas("t.pdf"); c.drawString(72, 720, "openclaw sandbox ok"); c.save()
from pypdf import PdfReader
assert "openclaw sandbox ok" in PdfReader("t.pdf").pages[0].extract_text()
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
plt.plot([1, 2, 3]); plt.savefig("t.png")
print("pdf     write + read ok, matplotlib ok")
PY
pdftotext t.pdf - | grep -q "openclaw sandbox ok"
echo "poppler pdftotext ok"
echo "node    $(node --version), pnpm $(pnpm --version)"
node -e "console.log(\"node    script ok\")"
mkdir gohello
cd gohello
printf "package main\nimport \"fmt\"\nfunc main() { fmt.Println(\"ok\") }\n" > main.go
go mod init gohello >/dev/null 2>&1
out="$(go run .)"
test "$out" = ok
echo "go      $(go version | cut -d" " -f3), build + run ok"
cd ..
cargo new --vcs none --quiet rshello
cd rshello
out="$(cargo run --quiet --offline)"
test "$out" = "Hello, world!"
echo "rust    $(rustc --version | cut -d" " -f2), build + run ok"
cd ..
printf "#include <stdio.h>\nint main(void){puts(\"ok\");return 0;}\n" > t.c
cc t.c -o t
test "$(./t)" = ok
echo "c       gcc build + run ok"
if curl -s -m 3 https://example.com >/dev/null 2>&1; then echo "UNEXPECTED: network reachable"; exit 1; fi
echo "network none (as intended)"
'
echo "    smoke test passed"

# --- 2. Web plugins (searxng, firecrawl) ------------------------------------------
# The gateway has no internet, so the packages are fetched by a one-shot
# container on Docker's default network and installed into /srv/openclaw/state.
# It uses a throwaway config (the real one is read-only); config/openclaw.json5
# already enables both plugins. The gateway must be stopped: the install needs
# the state lock.
if [[ "$(docker inspect -f '{{.State.Running}}' openclaw-gateway 2>/dev/null)" == "true" ]]; then
  log "Stopping the gateway for the plugin install"
  (cd compose && docker compose stop openclaw-gateway)
fi

log "Installing @openclaw/searxng-plugin and @openclaw/firecrawl-plugin ${VERSION}"
docker run --rm --network bridge \
  --cap-drop ALL --security-opt no-new-privileges \
  -e HOME=/home/node -e OPENCLAW_HOME=/home/node \
  -e OPENCLAW_STATE_DIR=/srv/openclaw/state \
  -e OPENCLAW_CONFIG_PATH=/tmp/plugin-install.json \
  -v /srv/openclaw:/srv/openclaw \
  --entrypoint node "$GW_IMAGE" dist/index.js plugins install "@openclaw/searxng-plugin@${VERSION}"
docker run --rm --network bridge \
  --cap-drop ALL --security-opt no-new-privileges \
  -e HOME=/home/node -e OPENCLAW_HOME=/home/node \
  -e OPENCLAW_STATE_DIR=/srv/openclaw/state \
  -e OPENCLAW_CONFIG_PATH=/tmp/plugin-install.json \
  -v /srv/openclaw:/srv/openclaw \
  --entrypoint node "$GW_IMAGE" dist/index.js plugins install "@openclaw/firecrawl-plugin@${VERSION}"

# --- 3. Validate config, set approvals, restart ----------------------------------------
log "Handing off to compose/install.sh (validate, approvals, restart)"
"$REPO/compose/install.sh"

log "Recreating any existing sandbox so it uses the current image and config"
docker exec openclaw-gateway openclaw sandbox recreate --all --force >/dev/null 2>&1 || true

cat <<'EOF'

Phase 3 installed. Next:
  1. ./tests/phase3-check.sh            (static checks)
  2. In the Control UI, ask the agent to run:  python3 --version && go version && pwd
     That starts its sandbox container.
  3. ./tests/phase3-check.sh again       (now also inspects the live sandbox)
EOF
