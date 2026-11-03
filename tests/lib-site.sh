# Sourced by the check scripts: site values from site.env, via the same helper
# the installers use, so the checks probe exactly what was configured.
# shellcheck shell=bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
site() { python3 "$REPO/scripts/site_settings.py" "$@"; }
[[ -f "$REPO/site.env" ]] || { echo "FAIL  site.env missing: run ./configure.sh"; exit 1; }
site check >/dev/null || { echo "FAIL  site.env is invalid (see above)"; exit 1; }
LLM_BASE_URL="$(site env LLM_BASE_URL)"
LLM_MODEL="$(site env LLM_MODEL)"
SEARXNG_URL="$(site env SEARXNG_URL)"
FIRECRAWL_URL="$(site env FIRECRAWL_URL)"
DNS1="$(site env DNS_SERVERS | awk '{print $1}')"
read -r LLM_IP LLM_PORT < <(site endpoint llm) || { echo "FAIL  cannot resolve the model server"; exit 1; }
read -r SEARX_IP SEARX_PORT < <(site endpoint searxng) || { echo "FAIL  cannot resolve SearXNG"; exit 1; }
is_private() { python3 -c 'import ipaddress, sys; sys.exit(0 if ipaddress.IPv4Address(sys.argv[1]).is_private else 1)' "$1"; }
export LLM_BASE_URL LLM_MODEL SEARXNG_URL FIRECRAWL_URL DNS1 LLM_IP LLM_PORT SEARX_IP SEARX_PORT
