#!/usr/bin/env bash
# Switch the gateway to another model on the same model server.
# Run on the VM as the admin user, from anywhere in the repo:
#
#   ./compose/set-model.sh                      show the current model and what the server offers
#   ./compose/set-model.sh <model-id>           switch to <model-id>
#   ./compose/set-model.sh <model-id> --context 65536 --name "Display name"
#
# It updates config/openclaw.json5 (the model's id and display name, and the
# default model) and tests/phase2-check.sh, then runs ./compose/install.sh and
# ./tests/phase2-check.sh. If install.sh fails, both files are put back and the
# gateway is restarted on the previous model.
#
# Options:
#   --context N   also set contextWindow (must match the server; at least 65536
#                 while tools.toolSearch is false)
#   --name TEXT   display name (default: the model id, plus " (Strata)")
#   --force       switch even if the server does not list <model-id>
#   --no-apply    edit the files only; run ./compose/install.sh yourself
set -Eeuo pipefail
cd "$(dirname "$0")"

CONFIG=../config/openclaw.json5
CHECK=../tests/phase2-check.sh
MIN_CONTEXT=65536   # tools.toolSearch is false: the prompt alone is about 35k tokens

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

NEW="" CONTEXT="" NAME="" FORCE=no APPLY=yes
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)  CONTEXT="${2:?--context needs a number}"; shift 2 ;;
    --name)     NAME="${2:?--name needs a value}"; shift 2 ;;
    --force)    FORCE=yes; shift ;;
    --no-apply) APPLY=no; shift ;;
    -h|--help)  usage 0 ;;
    -*)         echo "Unknown option: $1"; usage 1 ;;
    *)          [[ -z "$NEW" ]] || { echo "Only one model id, please."; exit 1; }; NEW="$1"; shift ;;
  esac
done

[[ $EUID -ne 0 ]] || { echo "Run as your admin user, not with sudo."; exit 1; }
command -v python3 >/dev/null || { echo "python3 is needed."; exit 1; }
[[ -f .env ]] || { echo "compose/.env missing. Run ./compose/install.sh first."; exit 1; }

# --- Current values, read from the config ------------------------------------
field() { sed -n "s/^ *$1: *\"\\{0,1\\}\\([^\",]*\\)\"\\{0,1\\},.*/\\1/p" "$CONFIG" | head -1; }
BASE_URL="$(field baseUrl)"
CUR="$(sed -n 's/^ *model: { primary: "strata\/\([^"]*\)" },.*/\1/p' "$CONFIG")"
CUR_CONTEXT="$(field contextWindow)"
[[ -n "$BASE_URL" && -n "$CUR" && -n "$CUR_CONTEXT" ]] || {
  echo "Could not find baseUrl, the default model or contextWindow in $CONFIG."
  echo "Has its layout changed? Edit it by hand instead."; exit 1; }
for f in "id: \"$CUR\"" "primary: \"strata/$CUR\"" ; do
  [[ "$(grep -cF "$f" "$CONFIG")" == 1 ]] || { echo "Expected exactly one '$f' in $CONFIG."; exit 1; }
done
grep -qF "MODEL=\"$CUR\"" "$CHECK" || { echo "Expected MODEL=\"$CUR\" in $CHECK."; exit 1; }

# --- Models the server offers ---------------------------------------------------
KEY="$(sed -n 's/^STRATA_API_KEY=//p' .env | tail -1 | sed "s/^'\(.*\)'$/\1/")"
SERVED="$(curl -fsS -m 15 -H "Authorization: Bearer ${KEY}" "${BASE_URL}/models" 2>/dev/null \
  | python3 -c 'import json, sys; print("\n".join(m["id"] for m in json.load(sys.stdin).get("data", [])))' 2>/dev/null)" || SERVED=""

echo "Model server:    ${BASE_URL}"
echo "Current model:   ${CUR}  (contextWindow ${CUR_CONTEXT})"
if [[ -n "$SERVED" ]]; then
  echo "Server offers:"; while IFS= read -r m; do echo "  $m"; done <<<"$SERVED"
else
  echo "Server offers:   (could not list models; is the server up and the key right?)"
fi
[[ -n "$NEW" ]] || { echo; echo "To switch: $0 <model-id>"; exit 0; }
echo

# --- Checks -------------------------------------------------------------------
[[ "$NEW" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$ ]] || {
  echo "'$NEW' doesn't look like a model id (letters, digits and . _ : / @ + - only)."; exit 1; }
if [[ -n "$CONTEXT" ]]; then
  [[ "$CONTEXT" =~ ^[0-9]+$ ]] || { echo "--context must be a number."; exit 1; }
  (( CONTEXT >= MIN_CONTEXT )) || {
    echo "--context ${CONTEXT} is too small: with tools.toolSearch false the prompt alone"
    echo "is about 35k tokens, so use at least ${MIN_CONTEXT}."; exit 1; }
fi
[[ "$NAME" != *'"'* && "$NAME" != *\\* ]] || { echo "--name may not contain \" or \\."; exit 1; }
[[ -n "$NAME" ]] || NAME="${NEW} (Strata)"
if [[ "$NEW" == "$CUR" && -z "$CONTEXT" ]]; then echo "Already using ${NEW}."; exit 0; fi
if ! grep -qxF "$NEW" <<<"$SERVED"; then
  if [[ "$FORCE" == yes ]]; then
    echo "Warning: the server does not list ${NEW}; continuing because of --force."
  else
    echo "The server does not list ${NEW}. Check the id above, or use --force."; exit 1
  fi
fi

# --- Edit, keeping copies to restore ---------------------------------------------
BACKUP="$(mktemp -d)"
cp -p "$CONFIG" "$BACKUP/config"; cp -p "$CHECK" "$BACKUP/check"
restore() {
  cp -p "$BACKUP/config" "$CONFIG"; cp -p "$BACKUP/check" "$CHECK"
  echo "!! Restored config/openclaw.json5 and tests/phase2-check.sh (model ${CUR})."
}

OLD="$CUR" NEW="$NEW" NAME="$NAME" CONTEXT="$CONTEXT" python3 - "$CONFIG" "$CHECK" <<'PY'
import os, re, sys
cfg, chk = sys.argv[1], sys.argv[2]
old, new, name, ctx = (os.environ[k] for k in ("OLD", "NEW", "NAME", "CONTEXT"))

def sub(text, pattern, repl, path):
    out, n = re.subn(pattern, lambda m: m.group(1) + repl + m.group(2), text, count=1, flags=re.M)
    if n != 1:
        sys.exit(f"could not update {pattern!r} in {path}")
    return out

s = open(cfg).read()
s = sub(s, r'^(\s*id: ")' + re.escape(old) + r'(",)', new, cfg)
# The display name is the line right after the id.
s = sub(s, r'(id: "' + re.escape(new) + r'",\n\s*name: ")[^"\n]*(",)', name, cfg)
s = sub(s, r'(model: \{ primary: "strata/)' + re.escape(old) + r'(" \},)', new, cfg)
if ctx:
    s = sub(s, r'^(\s*contextWindow: )\d+(,)', ctx, cfg)
open(cfg, "w").write(s)

t = open(chk).read()
t = sub(t, r'^(MODEL=")' + re.escape(old) + r'(")', new, chk)
open(chk, "w").write(t)
PY

echo "==> Changed:"
diff "$BACKUP/config" "$CONFIG" | sed -n -e 's/^< */  - /p' -e 's/^> */  + /p' || true
diff "$BACKUP/check" "$CHECK" | sed -n -e 's/^< */  - /p' -e 's/^> */  + /p' || true

if [[ "$APPLY" == no ]]; then
  echo; echo "Files edited. Apply with: ./compose/install.sh"; rm -rf "$BACKUP"; exit 0
fi

# --- Apply ----------------------------------------------------------------------
if ! ./install.sh; then
  restore
  echo "!! Restarting the gateway on the previous config"
  docker compose up -d --force-recreate openclaw-gateway || true
  rm -rf "$BACKUP"; exit 1
fi
rm -rf "$BACKUP"

echo; echo "==> Checking"
../tests/phase2-check.sh || true
cat <<EOF

Now using ${NEW}. Start a new chat in the Control UI: existing sessions may
still point at ${CUR}.
EOF
