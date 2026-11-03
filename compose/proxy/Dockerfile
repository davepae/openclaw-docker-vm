# Squid egress proxy for the agent sandboxes. Runs as the unprivileged
# 'proxy' user with a read-only root (see docker-compose.yml).
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
RUN apt-get update \
 && apt-get install -y --no-install-recommends squid \
 && rm -rf /var/lib/apt/lists/*
USER proxy
# Stream the file logs to stdout (tail inherits the open fd), then run Squid
# in the foreground. tini (compose init: true) reaps both.
ENTRYPOINT ["sh", "-c", "touch /var/log/squid/access.log /var/log/squid/cache.log && tail -qF /var/log/squid/access.log /var/log/squid/cache.log & exec squid -N -f /etc/squid/oc/squid.conf"]
