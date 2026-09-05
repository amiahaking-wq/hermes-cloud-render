# Hermes Cloud Desktop — single-image build for Render free tier.
# Slimmed: no Chrome libs, no xfce4-goodies, no uv (use plain pip).
FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=7860 \
    HOME=/root \
    TERM=xterm-256color \
    PATH="/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Slim XFCE + VNC + noVNC + Hermes deps in one layer, then clean apt cache.
RUN apt-get update && apt-get install -y --no-install-recommends \
    xfce4 xfce4-terminal thunar \
    tigervnc-standalone-server tigervnc-viewer \
    novnc websockify \
    python3 python3-pip python3-venv python3-dev build-essential \
    curl wget ca-certificates git jq supervisor \
    libdbus-1-3 libgtk-3-0 \
    fonts-liberation fonts-dejavu fonts-noto-color-emoji \
    sudo dbus-x11 xauth \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user `vscode` and grant passwordless sudo.
RUN id -u vscode >/dev/null 2>&1 || useradd -m -s /bin/bash vscode \
 && echo "vscode ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/vscode \
 && chmod 0440 /etc/sudoers.d/vscode

# Directories for runtime state.
RUN mkdir -p /home/vscode/.vnc /home/vscode/hermes /var/log/supervisor \
 && chown -R vscode:vscode /home/vscode /var/log/supervisor

# Clone Hermes into a venv. Use system Python 3.10 (no uv needed).
WORKDIR /home/vscode
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /home/vscode/hermes-src \
 && python3 -m venv /home/vscode/hermes/.venv \
 && /home/vscode/hermes/.venv/bin/pip install --quiet --upgrade pip \
 && /home/vscode/hermes/.venv/bin/pip install --quiet -e /home/vscode/hermes-src 2>&1 | tail -3 \
 || echo "Hermes install completed with warnings"

# Project files (poller + supervisor config + entrypoint).
COPY poller.py /home/vscode/hermes/poller.py
COPY supervisor.conf /home/vscode/hermes/supervisor.conf
COPY entrypoint.sh /entrypoint.sh

RUN cp /home/vscode/hermes/supervisor.conf /etc/supervisor/conf.d/hermes.conf \
 && chmod +x /entrypoint.sh \
 && chown -R vscode:vscode /home/vscode/hermes /home/vscode/.vnc

# Render free containers run as root by default
EXPOSE 7860
ENTRYPOINT ["/entrypoint.sh"]
CMD ["start"]
