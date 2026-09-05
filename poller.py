"""Hermes Cloud Telegram poller.

Polls Telegram for new messages, calls an LLM via NVIDIA NIM, sends the reply.
Reads/writes session + message history to Supabase (public.hermes_cloud_* tables).

Env vars required:
  CLOUD_TELEGRAM_BOT_TOKEN      - Telegram bot token
  CLOUD_TELEGRAM_ID             - comma-separated numeric user ids (whitelist)
  NVIDIA_API_KEY                - NVIDIA NIM API key (include "Bearer " prefix if you like)
  SUPABASE_STAGING_URL          - https://<ref>.supabase.co
  SUPABASE_STAGING_SERVICE      - service role key

Optional:
  HERMES_MODEL                  - default 'moonshotai/kimi-k3' (NVIDIA NIM)
  NVIDIA_BASE_URL               - default 'https://integrate.api.nvidia.com/v1'
"""
import os, sys, json, time, urllib.request, urllib.error, urllib.parse
from datetime import datetime

# --- Config from env ---
TG_TOKEN = os.environ["CLOUD_TELEGRAM_BOT_TOKEN"]
ALLOWED_IDS = {int(x) for x in os.environ["CLOUD_TELEGRAM_ID"].replace(",", " ").split() if x.strip()}
NVIDIA_KEY = os.environ["NVIDIA_API_KEY"]
# If user stored the value with a "Bearer " prefix, strip it because we add it ourselves.
if NVIDIA_KEY.lower().startswith("bearer "):
    NVIDIA_KEY = NVIDIA_KEY[7:].strip()
MODEL = os.environ.get("HERMES_MODEL", "moonshotai/kimi-k3")
BASE_URL = os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1").rstrip("/")
SUPABASE_URL = os.environ["SUPABASE_STAGING_URL"].rstrip("/")
SUPABASE_KEY = os.environ["SUPABASE_STAGING_SERVICE"]

TG_API = f"https://api.telegram.org/bot{TG_TOKEN}"
NVIDIA_CHAT_URL = f"{BASE_URL}/chat/completions"

def log(*a):
    print(f"[{datetime.utcnow().isoformat()}Z]", *a, flush=True)

# --- Supabase REST helpers ---
def sb(method, path, body=None):
    url = f"{SUPABASE_URL}/rest/v1/{path.lstrip('/')}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "apikey": SUPABASE_KEY,
        "Authorization": f"Bearer {SUPABASE_KEY}",
        "Content-Type": "application/json",
        "Prefer": "return=minimal",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            txt = r.read().decode()
            return (json.loads(txt) if txt else None), r.status
    except urllib.error.HTTPError as e:
        return {"error": e.read().decode()[:500]}, e.code

def get_or_create_session(channel, external_id, label=None):
    body = {"channel": channel, "external_id": external_id, "user_label": label}
    rows, code = sb("POST", "hermes_cloud_sessions?on_conflict=channel,external_id", body)
    if code in (200, 201) and rows:
        return rows[0]
    enc = urllib.parse.quote(external_id, safe="")
    rows, _ = sb("GET", f"hermes_cloud_sessions?channel=eq.{channel}&external_id=eq.{enc}&select=*")
    return rows[0] if rows else None

def append_message(session_id, role, content, model=None, tokens=None):
    body = {"session_id": session_id, "role": role, "content": content, "model": model, "tokens_used": tokens}
    sb("POST", "hermes_cloud_messages", body)

def fetch_history(session_id, limit=20):
    rows, _ = sb("GET", f"hermes_cloud_messages?session_id=eq.{session_id}&order=created_at.desc&limit={limit}&select=role,content")
    return list(reversed(rows or []))

def touch_session(session_id):
    sb("PATCH", f"hermes_cloud_sessions?id=eq.{session_id}", {"last_active_at": "now()"})

# --- Telegram helpers ---
def tg(method, **params):
    url = f"{TG_API}/{method}"
    data = json.dumps(params).encode()
    req = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": e.read().decode()[:300]}

def send_message(chat_id, text):
    # Telegram 4096 char limit; chunk if needed.
    for i in range(0, len(text), 4000):
        tg("sendMessage", chat_id=chat_id, text=text[i:i+4000], parse_mode="")

# --- LLM (NVIDIA NIM, OpenAI-compatible /v1/chat/completions) ---
def call_llm(messages):
    body = {
        "model": MODEL,
        "messages": messages,
        "max_tokens": 1024,
        "temperature": 0.7,
        "stream": False,
    }
    req = urllib.request.Request(NVIDIA_CHAT_URL, data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": f"Bearer {NVIDIA_KEY}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.loads(r.read())
            content = d["choices"][0]["message"]["content"]
            return content, d.get("usage", {}).get("total_tokens")
    except urllib.error.HTTPError as e:
        return f"[NVIDIA error: {e.code}] {e.read().decode()[:200]}", None
    except Exception as e:
        return f"[NVIDIA exception: {type(e).__name__}: {e}]", None

# --- Main loop ---
def main():
    log(f"poller starting; model={MODEL} base={BASE_URL}")
    last_update_id = 0
    while True:
        try:
            r = tg("getUpdates", offset=last_update_id + 1, timeout=25, allowed_updates=["message"])
            if not r.get("ok"):
                log("getUpdates failed:", r)
                time.sleep(5)
                continue
            for upd in r.get("result", []):
                last_update_id = max(last_update_id, upd["update_id"])
                msg = upd.get("message")
                if not msg:
                    continue
                chat_id = msg["chat"]["id"]
                user_id = msg["from"]["id"]
                text = msg.get("text", "").strip()
                if not text:
                    continue
                if user_id not in ALLOWED_IDS:
                    log(f"rejecting message from non-owner user_id={user_id}")
                    send_message(chat_id, "Not authorized. This bot is private.")
                    continue
                log(f"msg from allowed user_id={user_id} chat_id={chat_id}: {text[:80]!r}")

                session = get_or_create_session("telegram", str(chat_id), label=msg["from"].get("username"))
                if not session:
                    send_message(chat_id, "[storage error: could not create session]")
                    continue
                sid = session["id"]

                append_message(sid, "user", text)
                history = fetch_history(sid, limit=20)
                msgs = [{"role": m["role"], "content": m["content"]} for m in history if m["role"] in ("user","assistant","system")]
                reply, tokens = call_llm(msgs)
                append_message(sid, "assistant", reply, model=MODEL, tokens=tokens)
                touch_session(sid)
                send_message(chat_id, reply)
        except Exception as e:
            log("loop error:", type(e).__name__, e)
            time.sleep(5)

if __name__ == "__main__":
    main()
