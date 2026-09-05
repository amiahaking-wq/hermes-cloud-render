---
title: Hermes Cloud Desktop
emoji: 🛰️
colorFrom: purple
colorTo: indigo
sdk: docker
app_port: 7860
pinned: false
license: mit
---

# Hermes Cloud Desktop

A free 24/7 cloud VM running Hermes Agent (Telegram bot + email + browser-accessible XFCE desktop).

## Architecture

- **Port 7860**: noVNC web desktop (XFCE4)
- **Background**: Hermes agent polling Telegram and reading email
- **State**: Supabase (`public.hermes_cloud_*` tables)
- **Models**: OpenRouter (`OPENROUTER_API_KEY`)
- **Email**: AgentMail (`amiaha-7376@agentmail.to`)

## Keep-alive

HF Spaces free tier sleeps after 48h of no web-UI visits. Open this Space URL in a browser
once a day to keep it awake (or use cron-job.org to ping it).

## Telegram

Send any message to `@cuddlypotato_bot`.
