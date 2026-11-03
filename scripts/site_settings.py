#!/usr/bin/env python3
"""Site settings for the OpenClaw VM: one place for the values that differ
between networks (model server, web tools, DNS, admin machine).

The settings live in site.env at the repo root (git-ignored, mode 600). Every
install script and check reads them through this helper, so the OpenClaw
config, the firewall and the checks can never disagree.

    python3 scripts/site_settings.py configure          interactive setup, writes site.env
    python3 scripts/site_settings.py check              validate site.env (no network)
    python3 scripts/site_settings.py render-config      render the OpenClaw config
    python3 scripts/site_settings.py firewall-vars      shell variables for the firewall
    python3 scripts/site_settings.py endpoint NAME      "ip port" for llm|searxng|firecrawl
    python3 scripts/site_settings.py env NAME           one value from site.env
    python3 scripts/site_settings.py proxmox-rules      the Proxmox VM firewall file
    python3 scripts/site_settings.py selftest           offline unit tests

Standard library only; runs on the Ubuntu host's python3 (3.10+).
"""
import argparse
import getpass
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE_ENV = os.path.join(REPO, "site.env")
TEMPLATE = os.path.join(REPO, "config", "openclaw.template.json5")
LEGACY_ENV = os.path.join(REPO, "compose", ".env")

SITE_VERSION = "1"

# Measured with OpenClaw 2026.10.10 (first request of a new session, all
# allowlisted plugins): about 15k tokens with Tool Search on, 35k with it off.
MIN_CONTEXT = 32768          # smallest context verified to work (Tool Search on)
DIRECT_TOOLS_CONTEXT = 65536  # recommended context (Tool Search off at the default max tokens)
# Room for the prompt = context window - max output tokens. OpenClaw's first
# request is about 15k tokens with Tool Search on and about 35k with it off.
MIN_PROMPT_ROOM = 24576       # 32768 - 8192
DIRECT_TOOLS_ROOM = 57344     # 65536 - 8192: at or above this, Tool Search is off
PROVIDERS = ("openai-compatible",)   # more choices (e.g. Anthropic) can be added later

# Docker networks this build creates; a service must not live inside them.
RESERVED_NETS = [ipaddress.ip_network(n) for n in
                 ("172.30.10.0/24", "172.30.20.0/24", "172.30.30.0/24", "172.17.0.0/16")]

# Order matters: it is the order configure asks and the order site.env is written.
FIELDS = [
    ("MODEL_PROVIDER", "Model provider type"),
    ("LLM_BASE_URL", "Model server base URL"),
    ("LLM_MODEL", "Model name"),
    ("LLM_API_KEY", "Model server API key"),
    ("LLM_CONTEXT_WINDOW", "Context window (tokens)"),
    ("LLM_MAX_TOKENS", "Max output tokens"),
    ("LLM_IMAGE_INPUT", "Model accepts images (yes/no)"),
    ("SEARXNG_URL", "SearXNG URL"),
    ("FIRECRAWL_URL", "Firecrawl URL"),
    ("DNS_SERVERS", "DNS server(s) the VM uses"),
    ("ADMIN_IP", "Admin machine IP or subnet"),
]


class SiteError(Exception):
    pass


# --------------------------------------------------------------------------
# site.env: KEY='value' lines, readable by bash `source` and Docker Compose
# --------------------------------------------------------------------------
_LINE = re.compile(r"^([A-Z][A-Z0-9_]*)=(?:'([^']*)'|([A-Za-z0-9._:/@+,-]*))$")


def parse_env(text):
    values = {}
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = _LINE.match(line)
        if not m:
            raise SiteError(f"site.env line {n} is not KEY='value': {raw!r}")
        values[m.group(1)] = m.group(2) if m.group(2) is not None else m.group(3)
    return values


def load(path=None):
    path = path or SITE_ENV
    if not os.path.exists(path):
        raise SiteError(f"{path} not found. Run ./configure.sh first.")
    with open(path) as f:
        return parse_env(f.read())


def quote(value):
    if "'" in value or "\n" in value or "\r" in value:
        raise SiteError("values cannot contain single quotes or line breaks")
    return f"'{value}'"


def write(values, path=None):
    path = path or SITE_ENV
    lines = ["# Site settings for this OpenClaw VM. Written by ./configure.sh;",
             "# re-run it to change a value. Contains the model server API key:",
             "# keep it private (mode 600, git-ignored).",
             f"SITE_VERSION={quote(SITE_VERSION)}"]
    for key, _ in FIELDS:
        lines.append(f"{key}={quote(values[key])}")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".site.env.")
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


# --------------------------------------------------------------------------
# validation
# --------------------------------------------------------------------------
def parse_url(url, what):
    """Return (scheme, host, port, normalized_url). Raise SiteError if unusable."""
    url = url.strip()
    if any(c.isspace() for c in url) or "${" in url:
        raise SiteError(f"{what}: no spaces or ${{...}} in the URL ({url!r})")
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https"):
        raise SiteError(f"{what}: must start with http:// or https:// (got {url!r})")
    if not u.hostname:
        raise SiteError(f"{what}: no host in {url!r}")
    if u.username or u.password:
        raise SiteError(f"{what}: put credentials in the API key, not the URL")
    if u.query or u.fragment:
        raise SiteError(f"{what}: remove the ?query or #fragment from {url!r}")
    try:
        port = u.port if u.port is not None else (443 if u.scheme == "https" else 80)
    except ValueError:
        raise SiteError(f"{what}: invalid port in {url!r}")
    if port == 0:
        raise SiteError(f"{what}: port 0 is not usable")
    host = u.hostname
    if host == "localhost" or host.endswith(".localhost"):
        raise SiteError(f"{what}: {host} would point at the gateway container itself. "
                        "Use the server's LAN IP address or hostname.")
    path = u.path.rstrip("/")
    netloc = u.netloc
    return u.scheme, host, port, urllib.parse.urlunsplit((u.scheme, netloc, path, "", ""))


def local_ipv4s():
    """IPv4 addresses on this machine (to refuse services on the VM itself)."""
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr", "show"], capture_output=True,
                             text=True, check=False).stdout
    except FileNotFoundError:
        return set()
    return {m.group(1) for m in re.finditer(r"inet (\d+\.\d+\.\d+\.\d+)/", out)}


def resolve(host, resolver=None):
    """IPv4 addresses for host. Literal IPs are returned as-is."""
    try:
        return [str(ipaddress.IPv4Address(host))]
    except ValueError:
        pass
    if resolver is not None:
        found = resolver(host)
    else:
        try:
            infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
        except socket.gaierror as e:
            raise SiteError(f"cannot resolve {host}: {e.strerror}")
        found = [i[4][0] for i in infos]
    return sorted(set(found), key=lambda a: ipaddress.IPv4Address(a))


def check_ips(ips, what, locals_):
    for a in ips:
        ip = ipaddress.IPv4Address(a)
        if ip.is_loopback or ip.is_unspecified:
            raise SiteError(f"{what}: resolves to {a}, which would point at the gateway "
                            "container itself. Use the server's LAN address.")
        if a in locals_:
            raise SiteError(f"{what}: {a} is this VM. Services on the VM itself are not "
                            "supported (traffic to the host bypasses the gateway firewall).")
        if any(ip in n for n in RESERVED_NETS):
            raise SiteError(f"{what}: {a} is inside a Docker network this build uses.")


SERVICES = (("llm", "LLM_BASE_URL", "Model server URL"),
            ("searxng", "SEARXNG_URL", "SearXNG URL"),
            ("firecrawl", "FIRECRAWL_URL", "Firecrawl URL"))


def endpoint(name, raw_url, resolver=None, locals_=None):
    """(url, [ips], port) for one service. Raises SiteError if unusable."""
    what = {n: w for n, _, w in SERVICES}[name]
    locals_ = local_ipv4s() if locals_ is None else locals_
    scheme, host, port, url = parse_url(raw_url, what)
    ips = resolve(host, resolver)
    if not ips:
        raise SiteError(f"{what}: {host} has no IPv4 address")
    check_ips(ips, what, locals_)
    if name == "firecrawl" and scheme == "http" and not all(
            ipaddress.IPv4Address(a).is_private for a in ips):
        raise SiteError("Firecrawl URL: OpenClaw accepts plain http:// for Firecrawl "
                        "only on private addresses. Use https:// or a private address.")
    return url, ips, port


def endpoints(values, resolver=None, locals_=None):
    """{name: (url, [ips], port)} for the three services the gateway may reach."""
    locals_ = local_ipv4s() if locals_ is None else locals_
    return {name: endpoint(name, values[key], resolver, locals_) for name, key, _ in SERVICES}


def check_int_fields(ctx_s, max_s):
    for key, val in (("LLM_CONTEXT_WINDOW", ctx_s), ("LLM_MAX_TOKENS", max_s)):
        if val is not None and not re.fullmatch(r"[1-9][0-9]*", val):
            raise SiteError(f"{key}: must be a whole number")
    if ctx_s is not None and int(ctx_s) < MIN_CONTEXT:
        raise SiteError(f"LLM_CONTEXT_WINDOW: at least {MIN_CONTEXT} is needed. OpenClaw's first "
                        "request alone is about 15k tokens. Raise the server's context size "
                        "(Ollama defaults to 4096; set OLLAMA_CONTEXT_LENGTH).")
    if ctx_s is not None and max_s is not None:
        ctx, mx = int(ctx_s), int(max_s)
        if mx < 256:
            raise SiteError("LLM_MAX_TOKENS: must be at least 256")
        if ctx - mx < MIN_PROMPT_ROOM:
            raise SiteError(f"LLM_MAX_TOKENS: the context window minus max output tokens must "
                            f"leave at least {MIN_PROMPT_ROOM} tokens for the prompt; use at most "
                            f"{ctx - MIN_PROMPT_ROOM} with a {ctx} context")


def check_dns(raw):
    dns = list(dict.fromkeys(raw.split()))
    if not dns:
        raise SiteError("DNS_SERVERS: at least one address is needed")
    for i, a in enumerate(dns):
        try:
            ip = ipaddress.IPv4Address(a)
        except ValueError:
            raise SiteError(f"DNS_SERVERS: {a!r} is not an IPv4 address")
        if ip.is_loopback:
            raise SiteError("DNS_SERVERS: use the real upstream server, not 127.0.0.53")
        if ip.is_unspecified or ip.is_multicast or ip == ipaddress.IPv4Address("255.255.255.255"):
            raise SiteError(f"DNS_SERVERS: {a} is not a usable server address")
        if any(ip in n for n in RESERVED_NETS):
            raise SiteError(f"DNS_SERVERS: {a} is inside a Docker network this build uses")
        dns[i] = str(ip)
    return " ".join(dns)


def check_admin(raw):
    try:
        net = ipaddress.IPv4Network(raw, strict=False)
    except ValueError:
        raise SiteError(f"ADMIN_IP: {raw!r} is not an IPv4 address or subnet")
    if net.prefixlen < 16:
        raise SiteError("ADMIN_IP: a subnet wider than /16 would open SSH too broadly")
    a = net.network_address
    if a.is_unspecified or a.is_loopback or a.is_multicast or a == ipaddress.IPv4Address("255.255.255.255"):
        raise SiteError(f"ADMIN_IP: {raw} is not your admin machine's address")
    # Written in canonical form (host bits cleared) for the Proxmox rule.
    return str(a) if net.prefixlen == 32 else str(net)


def check_text(key, raw):
    # Printable ASCII only (also keeps the HTTP Authorization header valid).
    if any(not 32 <= ord(c) <= 126 for c in raw) or raw != raw.strip() or "'" in raw:
        raise SiteError(f"{key}: printable ASCII only; no single quotes or leading/trailing spaces")
    if "${" in raw:
        raise SiteError(f"{key}: '${{' is not allowed (OpenClaw would substitute it)")
    return raw


def validate(values, resolver=None, locals_=None, network=True):
    """Check every field. Returns normalized values. Raises SiteError."""
    v = dict(values)
    missing = [k for k, _ in FIELDS if not v.get(k, "").strip()]
    if missing:
        raise SiteError("site.env is missing: " + ", ".join(missing))
    for key, _ in FIELDS:
        if "'" in v[key] or "\n" in v[key] or "\r" in v[key]:
            raise SiteError(f"{key}: single quotes and line breaks are not supported")
    if v["MODEL_PROVIDER"] not in PROVIDERS:
        raise SiteError(f"MODEL_PROVIDER must be one of {', '.join(PROVIDERS)}")
    for key in ("LLM_MODEL", "LLM_API_KEY"):
        check_text(key, v[key])
    check_int_fields(v["LLM_CONTEXT_WINDOW"], v["LLM_MAX_TOKENS"])
    if v["LLM_IMAGE_INPUT"] not in ("yes", "no"):
        raise SiteError("LLM_IMAGE_INPUT: yes or no")
    v["DNS_SERVERS"] = check_dns(v["DNS_SERVERS"])
    v["ADMIN_IP"] = check_admin(v["ADMIN_IP"])
    for key, what in (("LLM_BASE_URL", "Model server URL"), ("SEARXNG_URL", "SearXNG URL"),
                      ("FIRECRAWL_URL", "Firecrawl URL")):
        v[key] = parse_url(v[key], what)[3]
    if network:
        endpoints(v, resolver, locals_)
    return v


# --------------------------------------------------------------------------
# outputs
# --------------------------------------------------------------------------
def prompt_room(v):
    return int(v["LLM_CONTEXT_WINDOW"]) - int(v["LLM_MAX_TOKENS"])


def render_config(values, template=None):
    template = template or TEMPLATE
    """The OpenClaw config with site values filled in (JSON-escaped)."""
    v = values
    subst = {
        "LLM_BASE_URL": json.dumps(v["LLM_BASE_URL"]),
        "LLM_MODEL": json.dumps(v["LLM_MODEL"]),
        "LLM_PRIMARY": json.dumps("llm/" + v["LLM_MODEL"]),
        "LLM_CONTEXT_WINDOW": str(int(v["LLM_CONTEXT_WINDOW"])),
        "LLM_MAX_TOKENS": str(int(v["LLM_MAX_TOKENS"])),
        "LLM_INPUT": json.dumps(["text", "image"] if v["LLM_IMAGE_INPUT"] == "yes" else ["text"]),
        "SEARXNG_URL": json.dumps(v["SEARXNG_URL"]),
        "FIRECRAWL_URL": json.dumps(v["FIRECRAWL_URL"]),
        # Direct tool schemas help heavily quantized models, but need the room.
        "TOOL_SEARCH": "false" if prompt_room(v) >= DIRECT_TOOLS_ROOM else "true",
    }
    with open(template) as f:
        text = f.read()
    unknown = set(re.findall(r"@@([A-Z_]+)@@", text)) - set(subst)
    if unknown:
        raise SiteError("template has unknown placeholders: " + ", ".join(sorted(unknown)))
    for k, s in subst.items():
        text = text.replace(f"@@{k}@@", s)
    if "@@" in text:
        raise SiteError("template still contains @@ after rendering")
    header = ("// GENERATED by scripts/site_settings.py from config/openclaw.template.json5 and\n"
              "// site.env. Do not edit: change the template or re-run ./configure.sh,\n"
              "// then ./compose/install.sh.\n")
    return header + text


def firewall_vars(values, resolver=None):
    eps = endpoints(values, resolver)
    pairs = []
    for name in ("llm", "searxng", "firecrawl"):
        _, ips, port = eps[name]
        for ip in ips:
            p = f"{ip}:{port}"
            if p not in pairs:
                pairs.append(p)
    return f'DNS_IP="{values["DNS_SERVERS"]}"\nALLOW_TCP="{" ".join(pairs)}"\n'


def proxmox_rules(values, resolver=None):
    eps = endpoints(values, resolver)
    lines = ["[OPTIONS]", "enable: 1", "policy_in: DROP", "policy_out: DROP", "dhcp: 1", "",
             "[RULES]", f"IN SSH(ACCEPT) -source {values['ADMIN_IP']}"]
    seen = []
    for name in ("llm", "searxng", "firecrawl"):
        _, ips, port = eps[name]
        for ip in ips:
            if (ip, port) not in seen:
                seen.append((ip, port))
                lines.append(f"OUT ACCEPT -dest {ip} -p tcp -dport {port}")
    for d in values["DNS_SERVERS"].split():
        lines.append(f"OUT DNS(ACCEPT) -dest {d}")
    lines += ["OUT NTP(ACCEPT)",
              "OUT DROP -dest 10.0.0.0/8", "OUT DROP -dest 172.16.0.0/12",
              "OUT DROP -dest 192.168.0.0/16",
              "OUT HTTP(ACCEPT)", "OUT HTTPS(ACCEPT)"]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# configure (interactive)
# --------------------------------------------------------------------------
def detect_dns():
    """Upstream DNS servers the VM uses (systemd-resolved's real servers)."""
    for path in ("/run/systemd/resolve/resolv.conf", "/etc/resolv.conf"):
        try:
            with open(path) as f:
                found = re.findall(r"^nameserver\s+(\d+\.\d+\.\d+\.\d+)", f.read(), re.M)
        except OSError:
            continue
        found = [a for a in found if not ipaddress.IPv4Address(a).is_loopback]
        if found:
            return " ".join(dict.fromkeys(found))
    return ""


def admin_from_ssh():
    """The address this SSH session comes from, as a default for ADMIN_IP."""
    parts = os.environ.get("SSH_CONNECTION", "").split()
    try:
        return str(ipaddress.IPv4Address(parts[0])) if parts else ""
    except ValueError:
        return ""


def http_get(url, key=None, timeout=10):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"} if key else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(2_000_000)
    except urllib.error.HTTPError as e:
        return e.code, e.read(200_000)


def list_models(base_url, key):
    status, body = http_get(base_url + "/models", key)
    if status in (401, 403):
        raise SiteError(f"{base_url}/models refused the API key (HTTP {status})")
    if status != 200:
        raise SiteError(f"{base_url}/models answered HTTP {status}; is the base URL right "
                        "(usually ending in /v1)?")
    try:
        return [m["id"] for m in json.loads(body).get("data", []) if "id" in m]
    except (ValueError, AttributeError, TypeError):
        raise SiteError(f"{base_url}/models did not return an OpenAI-style model list")


def ask(prompt, default="", secret=False, hint="", check=None):
    """Prompt until the answer passes check (which may normalize it)."""
    if hint:
        print(f"    {hint}")
    shown = ("[keep current]" if secret else f"[{default}]") if default else ""
    while True:
        try:
            label = f"  {prompt} {shown}: " if shown else f"  {prompt}: "
            raw = getpass.getpass(label) if secret else input(label)
        except EOFError:
            raise SiteError("input ended before all settings were entered")
        val = raw.strip() or default
        if not val:
            print("    A value is required.")
            continue
        try:
            return check(val) if check else val
        except SiteError as e:
            print(f"    ! {e}")


def yes(prompt, default=False):
    try:
        raw = input(f"  {prompt} [{'Y/n' if default else 'y/N'}]: ").strip().lower()
    except EOFError:
        raise SiteError("input ended")
    return default if not raw else raw.startswith("y")


def configure(_args):
    cur = {}
    if os.path.exists(SITE_ENV):
        try:
            cur = load()
            print(f"Updating {SITE_ENV}. Press Enter to keep a value.\n")
        except SiteError as e:
            print(f"! {SITE_ENV} could not be read ({e}); starting from scratch.\n")
    if not cur:
        print("Site settings for this OpenClaw VM. You'll need:\n"
              "  - an OpenAI-compatible model server on your LAN (Strata, Ollama, LM Studio,\n"
              "    vLLM, llama.cpp ...): its base URL, model name and API key\n"
              "  - SearXNG and Firecrawl URLs\n")
    legacy_key = ""
    if not cur.get("LLM_API_KEY") and os.path.exists(LEGACY_ENV):
        with open(LEGACY_ENV) as f:
            m = re.search(r"^STRATA_API_KEY='?([^'\n]*)'?$", f.read(), re.M)
        if m and m.group(1):
            legacy_key = m.group(1)
            print("    Found the API key from an earlier install (compose/.env); "
                  "press Enter to reuse it.\n")
    locals_ = local_ipv4s()
    url_check = lambda name: (lambda val: endpoint(name, val, None, locals_)[0])
    v = {"MODEL_PROVIDER": "openai-compatible"}

    print("Model server (OpenAI-compatible)")
    v["LLM_BASE_URL"] = ask("Base URL", cur.get("LLM_BASE_URL", ""), check=url_check("llm"),
                            hint="Examples: Ollama http://192.168.1.20:11434/v1 · "
                                 "LM Studio http://192.168.1.20:1234/v1")
    v["LLM_API_KEY"] = ask("API key (hidden)", cur.get("LLM_API_KEY", legacy_key), secret=True,
                           check=lambda val: check_text("LLM_API_KEY", val),
                           hint="Use 'none' if the server has no authentication "
                                "(Ollama ignores the key; LM Studio needs one only if enabled).")
    models = None
    try:
        models = list_models(v["LLM_BASE_URL"], v["LLM_API_KEY"])
        print(f"    Server reachable. Models: {', '.join(models[:12]) or '(none listed)'}"
              f"{' ...' if len(models) > 12 else ''}")
    except Exception as e:  # unreachable, not HTTP, bad URL ...: never lose the answers
        print(f"    ! Could not list models: {e}")
        if not yes("Continue anyway (for example, the server is offline right now)?"):
            raise SiteError("stopped; check the base URL and key, then re-run ./configure.sh")
    while True:
        default = cur.get("LLM_MODEL", models[0] if models and len(models) == 1 else "")
        v["LLM_MODEL"] = ask("Model name", default, check=lambda val: check_text("LLM_MODEL", val))
        if models is None or v["LLM_MODEL"] in models or yes(
                f"'{v['LLM_MODEL']}' is not in the server's list. Use it anyway?"):
            break
    print(f"    The context window must match the server's setting: at least {MIN_CONTEXT},"
          f"\n    {DIRECT_TOOLS_CONTEXT} or more recommended. Ollama defaults to 4096; raise it on"
          "\n    the server with OLLAMA_CONTEXT_LENGTH. A server that splits its context across"
          "\n    parallel slots (llama.cpp --parallel) gives each request only its share.")
    v["LLM_CONTEXT_WINDOW"] = ask("Context window (tokens)", cur.get("LLM_CONTEXT_WINDOW", "65536"),
                                  check=lambda val: (check_int_fields(val, None), val)[1])
    v["LLM_MAX_TOKENS"] = ask("Max output tokens", cur.get("LLM_MAX_TOKENS", "8192"),
                              check=lambda val: (check_int_fields(v["LLM_CONTEXT_WINDOW"], val), val)[1])

    def yn(val):
        val = val.lower()
        if val not in ("yes", "no"):
            raise SiteError("answer yes or no")
        return val
    v["LLM_IMAGE_INPUT"] = ask("Does the model accept images? (yes/no)",
                               cur.get("LLM_IMAGE_INPUT", "no"), check=yn)

    print("\nWeb tools (self-hosted)")
    v["SEARXNG_URL"] = ask("SearXNG URL", cur.get("SEARXNG_URL", ""), check=url_check("searxng"),
                           hint="Example: http://192.168.1.30:8080")
    v["FIRECRAWL_URL"] = ask("Firecrawl URL", cur.get("FIRECRAWL_URL", ""),
                             check=url_check("firecrawl"), hint="Example: http://192.168.1.30:3002")
    for key, label in (("SEARXNG_URL", "SearXNG"), ("FIRECRAWL_URL", "Firecrawl")):
        try:
            status, _ = http_get(v[key] + "/")
            print(f"    {label} reachable (HTTP {status})")
        except Exception as e:
            print(f"    ! {label} not reachable right now ({e}); saved anyway, the checks will tell")

    print("\nNetwork")
    detected = detect_dns()
    v["DNS_SERVERS"] = ask("DNS server(s) this VM uses", cur.get("DNS_SERVERS", detected),
                           check=check_dns,
                           hint="Detected from the VM's resolver. The gateway may use only these.")
    if detected and set(v["DNS_SERVERS"].split()) != set(detected.split()):
        print(f"    ! The VM resolves through {detected}. Docker passes those servers to the\n"
              "      gateway, so DNS from the gateway fails unless they are allowed here too.")
    v["ADMIN_IP"] = ask("Admin machine IP or subnet (allowed to SSH in)",
                        cur.get("ADMIN_IP", admin_from_ssh()), check=check_admin,
                        hint="The machine you SSH from; used for the Proxmox firewall rules.")
    v = validate(v, locals_=locals_)
    write(v)
    print(f"\nSaved {SITE_ENV} (mode 600).")
    return 0


# --------------------------------------------------------------------------
# selftest (offline)
# --------------------------------------------------------------------------
def selftest(_args):
    fails = []

    def t(name, cond):
        print(("PASS  " if cond else "FAIL  ") + name)
        if not cond:
            fails.append(name)

    def raises(fn):
        try:
            fn()
        except SiteError:
            return True
        return False

    fake_dns = {"llm.example.lan": ["192.168.1.20"], "multi.example.lan": ["10.0.0.6", "10.0.0.5"],
                "web.example.lan": ["192.168.1.30"], "public.example.com": ["93.184.215.14"],
                "loop.example.lan": ["127.0.1.1"]}
    res = lambda h: fake_dns[h]
    base = {"MODEL_PROVIDER": "openai-compatible", "LLM_BASE_URL": "http://llm.example.lan:11434/v1/",
            "LLM_MODEL": "qwen/qwen3.5-9b", "LLM_API_KEY": "sk-a$b&c|d\\e\"f#g h",
            "LLM_CONTEXT_WINDOW": "32768", "LLM_MAX_TOKENS": "8192", "LLM_IMAGE_INPUT": "no",
            "SEARXNG_URL": "http://web.example.lan:8080", "FIRECRAWL_URL": "http://192.168.1.30:3002",
            "DNS_SERVERS": "192.168.1.1", "ADMIN_IP": "192.168.1.10"}
    mine = {"192.168.1.50"}
    v = validate(base, res, mine)
    t("valid settings pass; trailing slash removed", v["LLM_BASE_URL"] == "http://llm.example.lan:11434/v1")
    t("https without port -> 443", parse_url("https://x.example/v1", "u")[2] == 443)
    t("http without port -> 80", parse_url("http://x.example", "u")[2] == 80)
    t("localhost refused", raises(lambda: parse_url("http://localhost:11434/v1", "u")))
    t("loopback IP refused", raises(lambda: validate({**base, "LLM_BASE_URL": "http://127.0.0.1:1234/v1"}, res, mine)))
    t("name resolving to loopback refused", raises(lambda: validate({**base, "LLM_BASE_URL": "http://loop.example.lan/v1"}, res, mine)))
    t("service on this VM refused", raises(lambda: validate({**base, "SEARXNG_URL": "http://192.168.1.50:8080"}, res, mine)))
    t("Docker network address refused", raises(lambda: validate({**base, "SEARXNG_URL": "http://172.30.20.2:8080"}, res, mine)))
    t("ftp scheme refused", raises(lambda: parse_url("ftp://x/v1", "u")))
    t("credentials in URL refused", raises(lambda: parse_url("http://u:p@x/v1", "u")))
    t("query string refused", raises(lambda: parse_url("http://x/v1?a=1", "u")))
    t("bad port refused", raises(lambda: parse_url("http://x:99999/v1", "u")))
    t("plain-http Firecrawl on a public IP refused", raises(lambda: validate({**base, "FIRECRAWL_URL": "http://public.example.com:3002"}, res, mine)))
    t("https Firecrawl on a public IP allowed", validate({**base, "FIRECRAWL_URL": "https://public.example.com"}, res, mine) is not None)
    t("max tokens >= context refused", raises(lambda: validate({**base, "LLM_MAX_TOKENS": "32768"}, res, mine)))
    t("max tokens leaving < 24576 for the prompt refused", raises(lambda: validate({**base, "LLM_MAX_TOKENS": "8193"}, res, mine)))
    t("32768 context with 8192 max accepted", validate({**base, "LLM_MAX_TOKENS": "8192"}, res, mine) is not None)
    t("port 0 refused", raises(lambda: parse_url("http://x:0/v1", "u")))
    t("space in URL refused", raises(lambda: parse_url("http://x/v 1", "u")))
    t("${ in model name refused", raises(lambda: validate({**base, "LLM_MODEL": "a${HOME}"}, res, mine)))
    t("non-ASCII API key refused", raises(lambda: validate({**base, "LLM_API_KEY": "kéy"}, res, mine)))
    t("DEL in API key refused", raises(lambda: validate({**base, "LLM_API_KEY": "k\x7f"}, res, mine)))
    t("DNS 0.0.0.0 refused", raises(lambda: validate({**base, "DNS_SERVERS": "0.0.0.0"}, res, mine)))
    t("DNS in a build Docker network refused", raises(lambda: validate({**base, "DNS_SERVERS": "172.30.10.1"}, res, mine)))
    t("duplicate DNS servers merged", validate({**base, "DNS_SERVERS": "192.168.1.1 192.168.1.1"}, res, mine)["DNS_SERVERS"] == "192.168.1.1")
    t("admin subnet written canonically", validate({**base, "ADMIN_IP": "192.168.1.10/24"}, res, mine)["ADMIN_IP"] == "192.168.1.0/24")
    t("admin /32 written as a bare address", validate({**base, "ADMIN_IP": "192.168.1.10/32"}, res, mine)["ADMIN_IP"] == "192.168.1.10")
    t("admin 0.0.0.0 refused", raises(lambda: validate({**base, "ADMIN_IP": "0.0.0.0"}, res, mine)))
    t("non-numeric context refused", raises(lambda: validate({**base, "LLM_CONTEXT_WINDOW": "32k"}, res, mine)))
    t("context below 32768 refused", raises(lambda: validate({**base, "LLM_CONTEXT_WINDOW": "16384"}, res, mine)))
    t("context of exactly 32768 accepted", validate({**base, "LLM_CONTEXT_WINDOW": "32768"}, res, mine) is not None)
    t("image input must be yes/no", raises(lambda: validate({**base, "LLM_IMAGE_INPUT": "true"}, res, mine)))
    t("loopback DNS refused", raises(lambda: validate({**base, "DNS_SERVERS": "127.0.0.53"}, res, mine)))
    t("/8 admin subnet refused", raises(lambda: validate({**base, "ADMIN_IP": "10.0.0.0/8"}, res, mine)))
    t("missing field refused", raises(lambda: validate({k: x for k, x in base.items() if k != "LLM_MODEL"}, res, mine)))
    t("unknown provider refused", raises(lambda: validate({**base, "MODEL_PROVIDER": "anthropic"}, res, mine)))
    fw = firewall_vars({**v, "LLM_BASE_URL": "http://multi.example.lan:8000/v1",
                        "DNS_SERVERS": "192.168.1.1 192.168.1.2"}, res)
    t("firewall: all IPs of a name, sorted, deduplicated",
      'ALLOW_TCP="10.0.0.5:8000 10.0.0.6:8000 192.168.1.30:8080 192.168.1.30:3002"' in fw)
    t("firewall: several DNS servers", 'DNS_IP="192.168.1.1 192.168.1.2"' in fw)
    pr = proxmox_rules(v, res)
    t("proxmox: SSH from admin only", "IN SSH(ACCEPT) -source 192.168.1.10" in pr)
    t("proxmox: model server rule", "OUT ACCEPT -dest 192.168.1.20 -p tcp -dport 11434" in pr)
    t("proxmox: accepts come before the private-range drops",
      pr.index("dport 3002") < pr.index("OUT DROP -dest 10.0.0.0/8"))
    # site.env round trip, including a key with shell and compose special characters
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "site.env")
        write(v, p)
        back = load(p)
        t("site.env round trip keeps the API key exactly", back["LLM_API_KEY"] == base["LLM_API_KEY"])
        t("site.env is mode 600", oct(os.stat(p).st_mode & 0o777) == "0o600")
        sh = subprocess.run(["bash", "-c", f"source {p}; printf %s \"$LLM_API_KEY\""],
                            capture_output=True, text=True).stdout
        t("bash `source` reads the same API key", sh == base["LLM_API_KEY"])
    t("single quote in a value refused", raises(lambda: quote("it's")))
    t("malformed site.env line refused", raises(lambda: parse_env("LLM_MODEL=has space")))
    # rendering
    with tempfile.TemporaryDirectory() as d:
        tpl = os.path.join(d, "t.json5")
        with open(tpl, "w") as f:
            f.write('{ a: @@LLM_BASE_URL@@, b: @@LLM_PRIMARY@@, c: @@LLM_CONTEXT_WINDOW@@, '
                    'd: @@LLM_INPUT@@, e: "${LLM_API_KEY}", f: @@TOOL_SEARCH@@ }')
        out = render_config({**v, "LLM_MODEL": 'od"d\\name', "LLM_IMAGE_INPUT": "yes"}, tpl)
        body = out.split("\n", 3)[3]
        t("render: model name JSON-escaped", '"llm/od\\"d\\\\name"' in body)
        t("render: number unquoted", "c: 32768" in body)
        t("render: image input -> text+image", 'd: ["text", "image"]' in body)
        t("render: API key stays an env reference", '"${LLM_API_KEY}"' in body)
        t("render: tool search on at a 32768 context", "f: true" in render_config({**v, "LLM_CONTEXT_WINDOW": "32768"}, tpl))
        t("render: tool search off at 65536 context / 8192 max", "f: false" in render_config({**v, "LLM_CONTEXT_WINDOW": "65536"}, tpl))
        t("render: tool search on just below 65536", "f: true" in render_config({**v, "LLM_CONTEXT_WINDOW": "65535"}, tpl))
        t("render: tool search on at 65536 with 16384 max tokens",
          "f: true" in render_config({**v, "LLM_CONTEXT_WINDOW": "65536", "LLM_MAX_TOKENS": "16384"}, tpl))
        t("render: tool search off at 131072 / 8192 (reference lab)",
          "f: false" in render_config({**v, "LLM_CONTEXT_WINDOW": "131072"}, tpl))
        with open(tpl, "w") as f:
            f.write("{ a: @@NOT_A_FIELD@@ }")
        t("render: unknown placeholder refused", raises(lambda: render_config(v, tpl)))
    print(f"\n{'all' if not fails else len(fails)} {'passed' if not fails else 'failed'}")
    return 1 if fails else 0


# --------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("configure", "check", "render-config", "firewall-vars", "proxmox-rules", "selftest"):
        sub.add_parser(name)
    ep = sub.add_parser("endpoint")
    ep.add_argument("name", choices=("llm", "searxng", "firecrawl"))
    ev = sub.add_parser("env")
    ev.add_argument("name")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "configure":
            return configure(args)
        if args.cmd == "selftest":
            return selftest(args)
        values = validate(load(), network=args.cmd not in ("check", "env"))
        if args.cmd == "check":
            if os.stat(SITE_ENV).st_mode & 0o077:
                print(f"warning: {SITE_ENV} is readable by other users (it holds the API key); "
                      f"run: chmod 600 {SITE_ENV}", file=sys.stderr)
            print("site.env OK")
        elif args.cmd == "env":
            if args.name not in values:
                raise SiteError(f"{args.name} is not a site setting")
            print(values[args.name])
        elif args.cmd == "render-config":
            sys.stdout.write(render_config(values))
        elif args.cmd == "firewall-vars":
            sys.stdout.write(firewall_vars(values))
        elif args.cmd == "proxmox-rules":
            sys.stdout.write(proxmox_rules(values))
        elif args.cmd == "endpoint":
            _, ips, port = endpoints(values)[args.name]
            print(ips[0], port)
        return 0
    except SiteError as e:
        print(f"site settings: {e}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\nstopped", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
