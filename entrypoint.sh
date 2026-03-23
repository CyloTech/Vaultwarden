#!/bin/bash
set -x

CONFIG_FLAG="/etc/app_configured"
DATA_DIR="/data"
DATA_DB="/data/db.sqlite3"
CONFIG_JSON="/data/config.json"
APP_USER="1000:1000"
LOCAL_URL="http://localhost:80"

wait_for_http() {
    local url="$1"
    local attempts="${2:-60}"
    local sleep_seconds="${3:-2}"
    local i=0

    until curl -sf "${url}" >/dev/null 2>&1; do
        i=$((i + 1))
        if [[ "${i}" -ge "${attempts}" ]]; then
            echo "Timed out waiting for ${url}"
            return 1
        fi
        sleep "${sleep_seconds}"
    done
}

create_admin_user() {
    local attempts=15
    local i=0

    while [[ "${i}" -lt "${attempts}" ]]; do
        if python3 /register_user.py "${LOCAL_URL}" "${USERNAME}" "${PASSWORD}"; then
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done
    return 1
}

callback_installed() {
    if [[ "${SKIP_APPBOX_CALLBACK:-0}" == "1" ]]; then
        echo "Skipping Appbox callback (SKIP_APPBOX_CALLBACK=1)"
        return 0
    fi

    local callback_url="https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}"
    local headers=(
        -H "Accept: application/json"
        -H "Content-Type:application/json"
    )

    if [[ -n "${CALLBACK_TOKEN:-}" ]]; then
        headers+=(-H "Authorization: Bearer ${CALLBACK_TOKEN}")
    fi

    until curl -fsS -o /dev/null "${headers[@]}" -X POST "${callback_url}"; do
        sleep 5
    done
}

chown 1000:1000 "${DATA_DIR}"

# Store admin token as an Argon2 hash in config.json rather than passing it
# as a plaintext env var. This allows moduser.sh to update the token and have
# the change survive container restarts (env vars are re-injected by the
# platform on every start and would overwrite config.json if left set).
if [[ -n "${ADMIN_TOKEN}" ]] && { [[ ! -f "${CONFIG_JSON}" ]] || ! jq -e '.admin_token' "${CONFIG_JSON}" >/dev/null 2>&1; }; then
    HASHED=$(printf '%s\n%s\n' "${ADMIN_TOKEN}" "${ADMIN_TOKEN}" \
        | script -qc "/vaultwarden hash --preset owasp" /dev/null 2>&1 \
        | grep "ADMIN_TOKEN=" \
        | sed "s/.*ADMIN_TOKEN='//;s/'.*//")

    if [[ -z "${HASHED}" ]]; then
        HASHED="${ADMIN_TOKEN}"
    fi

    if [[ -f "${CONFIG_JSON}" ]]; then
        jq --arg token "${HASHED}" '.admin_token = $token' "${CONFIG_JSON}" \
            > "${CONFIG_JSON}.tmp" && mv "${CONFIG_JSON}.tmp" "${CONFIG_JSON}"
    else
        jq -n --arg token "${HASHED}" '{admin_token: $token}' > "${CONFIG_JSON}"
    fi
    chown 1000:1000 "${CONFIG_JSON}"
fi
unset ADMIN_TOKEN

if [[ -z "${SMTP_HOST}" ]]; then
    unset SMTP_HOST SMTP_FROM SMTP_PORT SMTP_SECURITY SMTP_USERNAME SMTP_PASSWORD
else
    for _var in SMTP_FROM SMTP_PORT SMTP_SECURITY SMTP_USERNAME SMTP_PASSWORD; do
        [[ -z "${!_var}" ]] && unset "${_var}"
    done
fi

if [[ ! -f "${CONFIG_FLAG}" ]]; then
    touch "${CONFIG_FLAG}"

    if [[ ! -f "${DATA_DB}" ]]; then
        echo "Fresh install detected, bootstrapping Vaultwarden..."

        # Start Vaultwarden temporarily with signups enabled so the
        # registration API accepts our request.
        SIGNUPS_ALLOWED=true gosu "${APP_USER}" "$@" &
        APP_PID=$!

        wait_for_http "${LOCAL_URL}/alive" 90 2 || true

        if create_admin_user; then
            echo "Admin account created. Disabling public registration."
            if [[ -f "${CONFIG_JSON}" ]]; then
                jq '.signups_allowed = false' "${CONFIG_JSON}" \
                    > "${CONFIG_JSON}.tmp" && mv "${CONFIG_JSON}.tmp" "${CONFIG_JSON}"
            else
                jq -n '{signups_allowed: false}' > "${CONFIG_JSON}"
            fi
            chown 1000:1000 "${CONFIG_JSON}"
        else
            echo "WARNING: Automatic account creation failed."
            echo "Signups left enabled — create your account through the web vault."
        fi

        kill "${APP_PID}" 2>/dev/null || true
        wait "${APP_PID}" 2>/dev/null || true
    else
        echo "Upgrade detected: existing data found at ${DATA_DB}"
    fi

    callback_installed
fi

exec gosu "${APP_USER}" "$@"
