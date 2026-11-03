# Sourced by the login shell OpenClaw uses for sandbox exec (sh -lc).
# The sandbox root and home directory are read-only; only /workspace and the
# tmpfs mounts (/tmp, /var/tmp, /run) are writable. Point every tool's home
# and cache at writable places. Caches in /workspace/.cache persist between
# sessions because the sandbox scope is per agent.

export HOME=/tmp/home
mkdir -p "$HOME" 2>/dev/null

export XDG_CACHE_HOME=/workspace/.cache
export PIP_CACHE_DIR="$XDG_CACHE_HOME/pip"
export npm_config_cache="$XDG_CACHE_HOME/npm"
export GOPATH="$XDG_CACHE_HOME/go"
export GOCACHE="$XDG_CACHE_HOME/go-build"
export GOTOOLCHAIN=local          # never try to download another Go toolchain
export CARGO_HOME="$XDG_CACHE_HOME/cargo"
export MPLCONFIGDIR=/tmp/matplotlib
export PYTHONDONTWRITEBYTECODE=1

export VIRTUAL_ENV=/opt/venv
export PATH="/opt/venv/bin:$GOPATH/bin:$CARGO_HOME/bin:/usr/local/bin:/usr/bin:/bin"
