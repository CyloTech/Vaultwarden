#!/bin/bash
# Changes the Vaultwarden admin panel token.
#
# Bitwarden user account passwords cannot be reset server-side because
# the master password is used to derive client-side encryption keys.
# The admin panel token is the primary admin credential for Vaultwarden;
# from the admin panel, users can be managed (deleted, invited, etc.).

NEW_TOKEN="$1"

if [[ -z "${NEW_TOKEN}" ]]; then
    echo "Usage: /moduser.sh <new_admin_token>"
    exit 1
fi

CONFIG="/data/config.json"

HASHED=$(printf '%s\n%s\n' "${NEW_TOKEN}" "${NEW_TOKEN}" \
    | script -qc "/vaultwarden hash --preset owasp" /dev/null 2>&1 \
    | grep "ADMIN_TOKEN=" \
    | sed "s/.*ADMIN_TOKEN='//;s/'.*//")

if [[ -z "${HASHED}" ]]; then
    HASHED="${NEW_TOKEN}"
fi

if [[ -f "${CONFIG}" ]]; then
    jq --arg token "${HASHED}" '.admin_token = $token' "${CONFIG}" \
        > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "${CONFIG}"
else
    jq -n --arg token "${HASHED}" '{admin_token: $token}' > "${CONFIG}"
fi

chown 1000:1000 "${CONFIG}"
echo "Admin token updated. Restart the container for the change to take effect."
