#!/bin/sh
set -e

echo "[predbat] Docker startup"

# Prepare config
if [ -z "$(ls -A /config)" ]; then
    echo "/config directory is empty, copying files"
    cp -v /addon/apps.yaml /config/
else
    if [ ! -f /config/apps.yaml ]; then
        cp -v /addon/apps.yaml /config/
    fi
fi

# Block until config is valid
while grep -q "^[^#]*template: true" /config/apps.yaml; do
    echo "#################################################"
    echo "Please update apps.yaml"
    echo "Remove 'template: True'"
    echo "#################################################"
    sleep 30
done

echo "[predbat] Starting Predbat"

# Startup - plain `python3` (system site-packages, not a venv): startup.py
# itself shells out to hass.py via a bare, PATH-resolved `python3` call, so
# deps need to live where that resolves - see the Dockerfile's app-builder
# stage comment for why.
exec python3 /addon/startup.py
