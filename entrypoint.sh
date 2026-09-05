#!/bin/bash
# Hermes Cloud Desktop entrypoint.
# 1. Set VNC password from $VNCPASS env (default if unset).
# 2. Start VNC server on :1 (-> TCP 5901).
# 3. Start noVNC web proxy on :7860 (Render's expected app port).
# 4. Start supervisord which manages the Telegram poller.

set +e  # don't bail on transient failures during boot

VNCPASS="${VNCPASS:-hermes-cloud-default}"
echo "[entrypoint] starting; VNCPASS length=${#VNCPASS}; user=$(whoami)"

# Ensure vscode owns its home
mkdir -p /home/vscode/.vnc /var/log/supervisor
chown -R vscode:vscode /home/vscode 2>/dev/null || true

# VNC password
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

# Kill any prior VNC
su vscode -c "vncserver -kill :1 2>/dev/null" || true
sleep 1

# Start VNC as vscode
su vscode -c "vncserver :1 -geometry 1280x720 -depth 24 -localhost no" || true
sleep 3

# Verify VNC port is up
if ! ss -ltn | grep -q ':5901'; then
    echo "[entrypoint] WARNING: VNC not listening on 5901"
    ss -ltn
fi

# Start noVNC bound to all interfaces so Render's proxy can reach it
nohup /usr/share/novnc/utils/novnc_proxy \
    --vnc localhost:5901 \
    --listen 7860 \
    --web /usr/share/novnc \
    > /var/log/novnc.log 2>&1 &
NOVNC_PID=$!
echo "[entrypoint] noVNC started pid=$NOVNC_PID"
sleep 2

# Internal keepalive: every 10 min, hit our own noVNC URL so Render sees inbound traffic
# and doesn't spin us down after 15 min of idle. Costs nothing.
( while true; do
    curl -sf -o /dev/null http://127.0.0.1:7860/ || true
    sleep 600
  done ) &

# Start supervisord (manages the Telegram poller). Foreground so container stays alive.
echo "[entrypoint] starting supervisord..."
exec supervisord -n -c /etc/supervisor/supervisord.conf
