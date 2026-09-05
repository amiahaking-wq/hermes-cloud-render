#!/bin/bash
# Hermes Cloud Desktop entrypoint.
# 1. Set VNC password from $VNCPASS (default if unset).
# 2. Start VNC server on :1 (-> TCP 5901).
# 3. Start noVNC web proxy on :7860 (HF Spaces' app_port).
# 4. Start supervisord which manages the Telegram poller.

set -e

VNCPASS="${VNCPASS:-hermes-cloud-default}"
echo "[entrypoint] using VNCPASS length=${#VNCPASS}"

# VNC password (vscode user — entrypoint runs as root, then drops to vscode via su)
mkdir -p /home/vscode/.vnc
printf '%s' "$VNCPASS" | vncpasswd -f > /home/vscode/.vnc/passwd
chmod 600 /home/vscode/.vnc/passwd
chown vscode:vscode /home/vscode/.vnc/passwd

# xstartup for XFCE
cat > /home/vscode/.vnc/xstartup <<'XEOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
XEOF
chmod +x /home/vscode/.vnc/xstartup
chown -R vscode:vscode /home/vscode/.vnc

# Start VNC as vscode (in background)
su vscode -c "vncserver :1 -geometry 1920x1080 -depth 24 -localhost yes" || true
sleep 2

# Start noVNC web proxy bound to 0.0.0.0:7860 (HF Spaces expects this port public)
nohup /usr/share/novnc/utils/novnc_proxy \
    --vnc localhost:5901 \
    --listen 7860 \
    --web /usr/share/novnc \
    > /var/log/novnc.log 2>&1 &
echo "[entrypoint] noVNC started pid=$!"

# Internal keepalive: every 10 min, hit our own noVNC URL so Render sees inbound traffic
# and doesn't spin us down after 15 min of idle. Costs nothing.
( while true; do
    curl -sf -o /dev/null http://127.0.0.1:7860/ || true
    sleep 600
  done ) &

# Start supervisord (manages the Telegram poller). Foreground so container stays alive.
exec supervisord -n -c /etc/supervisor/supervisord.conf
