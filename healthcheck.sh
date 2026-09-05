#!/bin/bash
# Simple healthcheck responder. Not strictly needed (python http.server covers it)
# but kept for clarity / future override.
# v2: forced redeploy trigger
curl -sf http://127.0.0.1:10000/ >/dev/null && exit 0 || exit 1
