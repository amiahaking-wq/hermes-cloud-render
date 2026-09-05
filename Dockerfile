# Hermes Cloud Telegram bot — TRULY minimal image for Render free tier.
# No Hermes installation. The poller calls OpenRouter directly via urllib
# (stdlib only). Target image: ~80MB compressed.
FROM python:3.11-alpine

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HOME=/root \
    PATH="/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Alpine ships with curl + ca-certificates already. Nothing else needed.
# python:3.11-alpine is ~50MB base.

WORKDIR /opt

# Poller uses urllib from stdlib — zero pip installs needed.
COPY poller.py /opt/poller.py
COPY healthcheck.sh /opt/healthcheck.sh
RUN chmod +x /opt/healthcheck.sh

# Tiny static "ok" page served by python http.server for Render's healthcheck.
RUN mkdir -p /opt/www && printf 'hermes-telegram-bot: ok\n' > /opt/www/index.html

EXPOSE 10000

# HTTP healthcheck on :10000 (for Render's "alive" probe) + Telegram poller.
# Both run as the same container; the http server is tiny and just serves
# the static index.html above. curl polls it every 10min via the poller's
# keepalive loop (see /opt/poller.py).
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:10000/ || exit 1

CMD ["sh", "-c", "cd /opt/www && python3 -m http.server 10000 --bind 0.0.0.0 & exec python3 /opt/poller.py"]
