# Hermes Cloud Telegram bot — minimal image for Render free tier.
# ~120MB. Just Python 3.11 + Hermes CLI + the Telegram poller.
FROM python:3.11-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/root \
    PATH="/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# System deps: curl for healthcheck, ca-certs for HTTPS, jq not needed at runtime
# (the poller uses Python only). Keep it minimal.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && rm -rf /usr/share/doc /usr/share/man /usr/share/locale

# Clone Hermes and install. Use --depth 1 for speed. Pin to a specific commit
# later once we know which works; for now main.
WORKDIR /opt
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git hermes-src \
 && pip install --no-cache-dir -e ./hermes-src 2>&1 | tail -3 \
 && rm -rf hermes-src/.git \
 || echo "hermes install deferred"

# Project files
COPY poller.py /opt/poller.py
COPY healthcheck.sh /opt/healthcheck.sh
RUN chmod +x /opt/healthcheck.sh

# Healthcheck: hit / and report 200 — Render's free tier requires this for the
# "always awake" promise, otherwise the instance will be marked unhealthy and
# recycled. We use python's http.server on :10000 for this.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -sf http://127.0.0.1:10000/ >/dev/null || exit 1

EXPOSE 10000

# Run the healthcheck HTTP server + the Telegram poller together via a tiny
# shell supervisor (no need for the supervisor package — adds bloat).
CMD ["sh", "-c", "python3 -m http.server 10000 --bind 127.0.0.1 & exec python3 /opt/poller.py"]
