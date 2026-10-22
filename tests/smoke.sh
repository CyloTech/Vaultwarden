#!/usr/bin/env bash
# Image smoke test (needs Docker; no network access to Appbox):
#   - fresh install: the admin account is created, public registration is
#     closed, the account can log in and its keys decrypt, the admin panel
#     accepts the token, no credential reaches the container log, and the
#     server reports the manifest version;
#   - restart: the account still logs in and the install does not run again;
#   - update (with a previous image): an account created by the previous image
#     logs in after a new container of this image starts on the same /data,
#     and the admin token is kept.
#
# Usage: tests/smoke.sh <image> [<previous-image>]
set -Eeuo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: tests/smoke.sh <image> [<previous-image>]" >&2
    exit 2
fi
image=$1
previous=${2:-}
want_version=$(sed -n 's/^  version: "\(.*\)"$/\1/p' appbox.yml)

run_id="vwsmoke-$$-${RANDOM}"
containers=()
volumes=()
cleanup() {
    local c v
    for c in "${containers[@]+"${containers[@]}"}"; do docker rm -f "${c}" >/dev/null 2>&1 || true; done
    for v in "${volumes[@]+"${volumes[@]}"}"; do docker volume rm "${v}" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

random_hex() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Throwaway test account; hex only, so it is safe to mask with sed.
USERNAME="smoke$(random_hex 4)@example.test"
PASSWORD="smoke$(random_hex 12)"
ADMIN_TOKEN="$(random_hex 24)"
export USERNAME PASSWORD ADMIN_TOKEN

fail() {
    echo "FAIL $1" >&2
    if [[ -n "${2:-}" ]]; then
        docker logs "$2" 2>&1 | tail -40 | sed -e "s/${PASSWORD}/<password>/g" -e "s/${ADMIN_TOKEN}/<admin-token>/g" >&2
    fi
    exit 1
}
pass() { echo "ok   $*"; }

start() {
    local name=$1 img=$2 volume=$3
    docker run -d --name "${name}" \
        -e USERNAME -e PASSWORD -e ADMIN_TOKEN \
        -e DOMAIN=http://localhost -e INSTANCE_ID=smoke -e SKIP_APPBOX_CALLBACK=1 \
        -v "${volume}:/data" "${img}" >/dev/null
    containers+=("${name}")
}

new_volume() {
    docker volume create "$1" >/dev/null
    volumes+=("$1")
}

# wait_for_log <container> <text> [<seconds>]
wait_for_log() {
    local i
    for ((i = 0; i < ${3:-180}; i++)); do
        docker logs "$1" 2>&1 | grep -qF "$2" && return 0
        docker logs "$1" 2>&1 | grep -qF 'Automatic account creation failed' && fail "$1: account creation failed" "$1"
        [[ "$(docker inspect -f '{{.State.Running}}' "$1")" == true ]] || fail "$1: container stopped" "$1"
        sleep 1
    done
    fail "$1: no '$2' in the log after ${3:-180}s" "$1"
}

# Wait until the entrypoint has exec'd the final Vaultwarden (PID 1) and it
# answers. During a fresh install a temporary Vaultwarden with signups enabled
# runs first; checks must not reach it.
wait_alive() {
    local i
    for ((i = 0; i < 180; i++)); do
        if [[ "$(docker exec "$1" cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ')" == '/vaultwarden ' ]] \
            && docker exec "$1" curl -sf http://localhost:80/alive >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    fail "$1: the final Vaultwarden did not answer" "$1"
}

check() { docker exec -i "$1" python3 -I - "$2" <tests/vault_check.py || fail "$1: $2 check" "$1"; }

config_value() {
    docker exec "$1" cat /data/config.json | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]))' "$2"
}

no_credentials_logged() {
    if docker logs "$1" 2>&1 | grep -qF -e "${PASSWORD}" -e "${ADMIN_TOKEN}"; then
        fail "$1: a credential appears in the container log"
    fi
    pass "$1: no credential in the container log"
}

# --- fresh install ---------------------------------------------------------------
fresh="${run_id}-fresh"
new_volume "${fresh}"
start "${fresh}" "${image}" "${fresh}"
wait_for_log "${fresh}" 'Admin account created. Disabling public registration.'
wait_alive "${fresh}"
pass "fresh install created the admin account"

[[ "$(config_value "${fresh}" signups_allowed)" == False ]] || fail "signups_allowed is not false in config.json" "${fresh}"
[[ "$(config_value "${fresh}" admin_token)" == '$argon2'* ]] || fail "admin_token is not an Argon2 hash" "${fresh}"
pass "config.json: signups closed, admin token hashed"

check "${fresh}" login
check "${fresh}" signups-closed
check "${fresh}" admin
got_version=$(check "${fresh}" version)
[[ "${got_version}" == "${want_version}" ]] || fail "server reports ${got_version}, manifest says ${want_version}"
pass "server version ${got_version}"
echo "info web vault $(docker exec "${fresh}" cat /web-vault/vw-version.json)"
no_credentials_logged "${fresh}"

# --- restart ---------------------------------------------------------------------
docker restart "${fresh}" >/dev/null
wait_alive "${fresh}"
check "${fresh}" login
[[ "$(docker logs "${fresh}" 2>&1 | grep -cF 'Fresh install detected')" == 1 ]] || fail "install ran again after a restart" "${fresh}"
pass "restart kept the account and did not reinstall"

# --- update from the previous image ----------------------------------------------
if [[ -n "${previous}" ]]; then
    update="${run_id}-update"
    new_volume "${update}"
    start "${update}-old" "${previous}" "${update}"
    wait_for_log "${update}-old" 'Admin account created'
    wait_alive "${update}-old"
    old_token=$(config_value "${update}-old" admin_token)
    docker rm -f "${update}-old" >/dev/null

    start "${update}-new" "${image}" "${update}"
    wait_for_log "${update}-new" 'Upgrade detected'
    wait_alive "${update}-new"
    check "${update}-new" login
    check "${update}-new" admin
    check "${update}-new" signups-closed
    [[ "$(config_value "${update}-new" admin_token)" == "${old_token}" ]] || fail "the update replaced the admin token" "${update}-new"
    no_credentials_logged "${update}-new"
    pass "update from ${previous} kept the account and the admin token"
fi

echo "smoke test passed for ${image}"
