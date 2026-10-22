#!/usr/bin/env bash
# Release gate: run with the exact built image reference as the only argument.
# Exits zero only when the static checks, the callback tests and the image
# smoke test (including an update from the previous release) pass for that
# image and the authenticated registry reports that exact tag as definitively
# not found. Every other registry response (found, auth, transport, server
# error) fails.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

# The release this one replaces; update it with each release.
previous_release="repo.cylo.net/vaultwarden:1.37.1"

if [[ $# -ne 1 ]]; then
    echo "usage: tests/release-gate.sh <image-reference>" >&2
    exit 2
fi

IMAGE_REF="$1"
case "${IMAGE_REF}" in
    repo.cylo.net/[a-z0-9._/-]*:[A-Za-z0-9._-]*) ;;
    *) echo "unexpected image reference: ${IMAGE_REF}" >&2; exit 2 ;;
esac

REGISTRY="${IMAGE_REF%%/*}"
REPO_AND_TAG="${IMAGE_REF#*/}"
REPO="${REPO_AND_TAG%:*}"
TAG="${REPO_AND_TAG##*:}"

manifest_name=$(sed -n 's/^  name: "\(.*\)"$/\1/p' appbox.yml)
manifest_version=$(sed -n 's/^  version: "\(.*\)"$/\1/p' appbox.yml)
manifest_tag=$(sed -n 's/^  tag: "\(.*\)"$/\1/p' appbox.yml)
base_version=$(sed -n 's|^FROM vaultwarden/server:\(.*\)$|\1|p' Dockerfile)
[[ "${REPO}" == "${manifest_name}" && "${TAG}" == "${manifest_tag}" ]] \
    || { echo "image ${IMAGE_REF} does not match appbox.yml (${manifest_name}:${manifest_tag})" >&2; exit 1; }
[[ "${base_version}" == "${manifest_version}" ]] \
    || { echo "Dockerfile base ${base_version} does not match appbox.yml version ${manifest_version}" >&2; exit 1; }

bash -n entrypoint.sh moduser.sh appbox-installed-callback tests/smoke.sh
python3 -I -c 'import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' register_user.py tests/vault_check.py
echo "ok   static checks"

bash tests/test-installed-callback.sh

docker image inspect "${previous_release}" >/dev/null 2>&1 || docker pull "${previous_release}"
bash tests/smoke.sh "${IMAGE_REF}" "${previous_release}"

AUTH="$(python3 -c 'import json,sys,os; print(json.load(open(os.path.expanduser("~/.docker/config.json")))["auths"][sys.argv[1]]["auth"])' "${REGISTRY}")"
# The credential goes to curl on stdin, not on its command line.
STATUS="$(printf 'Authorization: Basic %s\n' "${AUTH}" | curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    -H @- \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://${REGISTRY}/v2/${REPO}/manifests/${TAG}")" || STATUS="curl-failed"

case "${STATUS}" in
    404) echo "registry reports ${IMAGE_REF} not found; release may proceed" ;;
    200) echo "tag already exists in the registry: ${IMAGE_REF}" >&2; exit 1 ;;
    *)   echo "indeterminate registry response (${STATUS}) for ${IMAGE_REF}" >&2; exit 1 ;;
esac
