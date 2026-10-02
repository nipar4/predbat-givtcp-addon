#!/bin/sh
set -e

echo "[givtcp] Docker startup"

# Defensive only - GivTCP's own first-boot bootstrap writes its allsettings.json
# here (a hardcoded path in its own startup.py, not env-configurable); not
# confirmed whether its code assumes the dir pre-exists, cheap to ensure either way.
mkdir -p /config/GivTCP

cd /app

echo "[givtcp] Starting GivTCP"

# Startup - plain `python3` (system site-packages, not a venv): GivTCP's own
# code hardcodes /usr/local/bin/python3 when it re-execs its own subprocesses,
# so its deps are installed there rather than in an isolated venv - see the
# Dockerfile's givtcp-builder stage comment for why.
exec python3 /app/startup.py
