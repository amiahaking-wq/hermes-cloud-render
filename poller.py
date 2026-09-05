"""Hermes Cloud Telegram poller.

Polls Telegram for new messages, calls Hermes to generate a reply, sends the reply back.
Reads/writes session + message history to Supabase (public.hermes_cloud_* tables).

Env vars required:
  CLOUD_TELEGRAM_BOT_TOKEN      - Telegram bot token
  CLOUD_TELEGRAM_ID             - numeric user id of owner (whitelist; others ignored)
  OPENROUTER_API_KEY            - for the LLM
  SUPABASE_STAGING_URL          - https://<ref>.supabase.co
  SUPABASE_STAGING_SERVICE      - service role key

Optional:
  HERMES_MODEL                  - default 'openrouter/anthropic/claude-3.5-sonnet'
"""
import os, sys, json, time, urllib.request, urllib.error, urllib.parse
from datetime import datetime

# --- Config from env ---
TG_TOKEN = os.environ["CLOUD_TELEGRAM_BOT_TOKEN"]
# Comma-separated list of allowed Telegram user IDs (e.g. "1234,5678")
ALLOWED_IDS = {int(x) for x in os.environ["CLOUD_TELEGRAM_ID"].replace(",", " ").split() if x.strip()}
MODEL = os.environ.get("HERMES_MODEL", "anthropic/claude-3.5-sonnet")
SUPABASE_URL = os.environ["SUPABASE_STAGING_URL"].rstrip("/")
SUPABASE_KEY = os.environ["SUPABASE_STAGING_SERVICE"]

TG_API = f"https://api.telegram.org/bot{TG_TOKEN}"

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
    # Try insert; on conflict, fetch existing.
    body = {"channel": channel, "external_id": external_id, "user_label": label}
    rows, code = sb("POST", "hermes_cloud_sessions?on_conflict=channel,external_id", body)
    if code in (200, 201) and rows:
        return rows[0]
    # If conflict, fetch.
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

# --- Hermes reply (via OpenRouter direct — Hermes gateway would also work but adds latency) ---
def call_openrouter(messages):
    key = os.environ["OPENROUTER_API_KEY"]
    url = "https://openrouter.ai/api/v1/chat/completions"
    body = {
        "model": MODEL,
        "messages": messages,
        "max_tokens": 1500,
        "temperature": 0.7,
    }
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://huggingface.co/spaces/Amiahhhhh/hermes-cloud",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.loads(r.read())
            return d["choices"][0]["message"]["content"], d.get("usage", {}).get("total_tokens")
    except urllib.error.HTTPError as e:
        return f"[OpenRouter error: {e.code}] {e.read().decode()[:200]}", None
    except Exception as e:
        return f"[OpenRouter exception: {type(e).__name__}: {e}]", None

# --- Main loop ---
def main():
    log("poller starting; model=", MODEL)
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
                # Whitelist: only allowed IDs (comma-separated in CLOUD_TELEGRAM_ID)
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

                # Persist user msg, fetch history, call LLM, persist reply, send.
                append_message(sid, "user", text)
                history = fetch_history(sid, limit=20)
                msgs = [{"role": m["role"], "content": m["content"]} for m in history if m["role"] in ("user","assistant","system")]
                reply, tokens = call_openrouter(msgs)
                append_message(sid, "assistant", reply, model=MODEL, tokens=tokens)
                touch_session(sid)
                send_message(chat_id, reply)
        except Exception as e:
            log("loop error:", type(e).__name__, e)
            time.sleep(5)

if __name__ == "__main__":
    main()
