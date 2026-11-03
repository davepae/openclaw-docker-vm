#!/usr/bin/env bash
# Phase 3 — build the agent sandbox image, install the web plugins, and turn
# sandboxing on. Run on the VM as the admin user from the repo:  ./sandbox/install.sh
# Safe to re-run.
set -Eeuo pipefail  # -E: the ERR trap also fires inside functions
cd "$(dirname "$0")/.."
REPO="$(pwd)"

SANDBOX_IMAGE="openclaw-sandbox-local:2"   # must match agents.defaults.sandbox.docker.image
log() { printf '\n==> %s\n' "$*"; }

[[ $EUID -ne 0 ]] || { echo "Run as your admin user, not with sudo."; exit 1; }
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
python3 - <<PY
import docx, openpyxl, pptx
d = docx.Document(); d.add_paragraph("lo docx ok"); d.save("lodoc.docx")
p = pptx.Presentation(); p.slides.add_slide(p.slide_layouts[0]).shapes.title.text = "lo pptx ok"; p.save("lodeck.pptx")
wb = openpyxl.Workbook(); ws = wb.active; ws["A1"] = 2; ws["A2"] = 3; ws["A3"] = "=SUM(A1:A2)*10"; wb.save("losheet.xlsx")
PY
mkdir lo-out
soffice --headless --convert-to pdf --outdir lo-out lodoc.docx lodeck.pptx >/dev/null 2>&1
pdftotext lo-out/lodoc.pdf - | grep -q "lo docx ok"
pdftotext lo-out/lodeck.pdf - | grep -q "lo pptx ok"
soffice --headless --convert-to xlsx --outdir lo-out losheet.xlsx >/dev/null 2>&1
python3 - <<PY
import openpyxl
assert openpyxl.load_workbook("lo-out/losheet.xlsx", data_only=True).active["A3"].value == 50
PY
grep -q OOXMLRecalcMode "$HOME/.config/libreoffice/4/user/registrymodifications.xcu"
pdftoppm -r 50 -png -f 1 -l 1 lo-out/lodoc.pdf lo-out/page
test -s lo-out/page-1.png
echo "office  $(soffice --version | cut -d" " -f1-2): docx/pptx to pdf, xlsx recalc, page render ok"
if curl -s -m 3 https://example.com >/dev/null 2>&1; then echo "UNEXPECTED: network reachable"; exit 1; fi
echo "network none (as intended)"
'
echo "    smoke test passed"

# --- 2. Web plugins (searxng, firecrawl) ------------------------------------------
# The gateway has no internet, so the packages are fetched by a one-shot
# container on Docker's default network and installed into /srv/openclaw/state.
# It uses a throwaway config (the real one is read-only); config/openclaw.template.json5
# already enables both plugins. The throwaway config lives in a directory node
# owns, because OpenClaw chmods its config directory (root-owned /tmp fails). The gateway must be stopped: the install needs
# the state lock.
if [[ "$(docker inspect -f '{{.State.Running}}' openclaw-gateway 2>/dev/null)" == "true" ]]; then
  log "Stopping the gateway for the plugin install"
  (cd compose && docker compose stop openclaw-gateway)
  # If anything below fails, don't leave the gateway down.
  trap 'echo "!! Failed; starting the gateway again"; (cd "$REPO/compose" && docker compose start openclaw-gateway) || true' ERR
fi

# Version of a plugin already installed in the state dir, or empty.
installed_version() {  # npm package name, e.g. @openclaw/searxng-plugin
  local pj
  pj="$(ls -d /srv/openclaw/state/npm/projects/*/node_modules/"$1"/package.json 2>/dev/null | head -1 || true)"
  [[ -n "$pj" ]] || return 0
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("version", ""))' "$pj"
}

install_plugin() {  # npm package name
  local pkg="$1" have force=()
  have="$(installed_version "$pkg")"
  if [[ "$have" == "$VERSION" ]]; then
    echo "    ${pkg} ${VERSION} already installed"
    return
  fi
  # Replacing an installed plugin (an upgrade) requires --force.
  [[ -z "$have" ]] || { echo "    upgrading ${pkg} ${have} -> ${VERSION}"; force=(--force); }
  docker run --rm --network bridge \
    --cap-drop ALL --security-opt no-new-privileges \
    -e HOME=/home/node -e OPENCLAW_HOME=/home/node \
    -e OPENCLAW_STATE_DIR=/srv/openclaw/state \
    -e OPENCLAW_CONFIG_PATH=/home/node/plugin-install/openclaw.json \
    -v /srv/openclaw:/srv/openclaw \
    --entrypoint node "$GW_IMAGE" dist/index.js plugins install "${force[@]}" "${pkg}@${VERSION}"
}

log "Installing the web plugins (${VERSION})"
install_plugin @openclaw/searxng-plugin
install_plugin @openclaw/firecrawl-plugin

# --- 3. Validate config, set approvals, restart ----------------------------------------
trap - ERR   # compose/install.sh has its own recovery
log "Handing off to compose/install.sh (validate, approvals, recreate sandboxes, restart)"
"$REPO/compose/install.sh"


cat <<'EOF'

Phase 3 installed. Next:
  1. ./tests/phase3-check.sh            (static checks)
  2. In the Control UI, ask the agent to run:  python3 --version && go version && pwd
     That starts its sandbox container.
  3. ./tests/phase3-check.sh again       (now also inspects the live sandbox)
EOF
