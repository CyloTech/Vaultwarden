"""
Checks a running Vaultwarden container from the inside. tests/smoke.sh pipes
this file into `docker exec -i <container> python3 -I - <check>`; it reads the
account from the container's USERNAME, PASSWORD and ADMIN_TOKEN and talks to
Vaultwarden on http://localhost:80.

Checks:
  login           log in as a Bitwarden client would, then decrypt the account
                  key and the private key to prove the account is usable
  signups-closed  a new registration is refused
  admin           the admin panel accepts ADMIN_TOKEN
  version         print the server version
"""

import hashlib
import hmac
import json
import os
import subprocess
import sys
import uuid
from base64 import b64decode, b64encode
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

BASE = "http://localhost:80"


def post(path, data, form=False):
    if form:
        body, ctype = urlencode(data).encode(), "application/x-www-form-urlencoded"
    else:
        body, ctype = json.dumps(data).encode(), "application/json"
    req = Request(BASE + path, data=body, method="POST",
                  headers={"Content-Type": ctype, "Accept": "application/json"})
    with urlopen(req) as resp:
        text = resp.read().decode()
        return json.loads(text) if text else None


def hkdf_expand(prk, info):
    return hmac.new(prk, info.encode() + b"\x01", hashlib.sha256).digest()


def open_enc_string(enc, enc_key, mac_key):
    """Check the MAC of a type 2 EncString and decrypt it with openssl."""
    kind, rest = enc.split(".", 1)
    assert kind == "2", f"unexpected EncString type {kind}"
    iv, ct, mac = (b64decode(p) for p in rest.split("|"))
    assert hmac.compare_digest(hmac.new(mac_key, iv + ct, hashlib.sha256).digest(), mac), "MAC mismatch"
    out = subprocess.run(["openssl", "enc", "-d", "-aes-256-cbc", "-K", enc_key.hex(), "-iv", iv.hex()],
                         input=ct, capture_output=True, check=True)
    return out.stdout


def login():
    email = os.environ["USERNAME"].lower().strip()
    password = os.environ["PASSWORD"]
    pre = post("/identity/accounts/prelogin", {"email": email})
    kdf = pre.get("kdf", pre.get("Kdf"))
    iterations = pre.get("kdfIterations", pre.get("KdfIterations"))
    assert kdf == 0, f"unexpected KDF {kdf}"

    master_key = hashlib.pbkdf2_hmac("sha256", password.encode(), email.encode(), iterations, 32)
    master_hash = b64encode(hashlib.pbkdf2_hmac("sha256", master_key, password.encode(), 1, 32)).decode()
    token = post("/identity/connect/token", {
        "grant_type": "password",
        "username": email,
        "password": master_hash,
        "scope": "api offline_access",
        "client_id": "web",
        "device_type": "10",
        "device_identifier": str(uuid.uuid4()),
        "device_name": "appbox-smoke",
    }, form=True)
    assert token.get("access_token"), "no access token"

    user_key = open_enc_string(token["Key"], hkdf_expand(master_key, "enc"), hkdf_expand(master_key, "mac"))
    assert len(user_key) == 64, f"user key is {len(user_key)} bytes"
    private_key = open_enc_string(token["PrivateKey"], user_key[:32], user_key[32:])
    assert private_key[:1] == b"\x30", "private key is not DER"
    print("login ok: token issued, account key and private key decrypt")


def signups_closed():
    try:
        post("/identity/accounts/register/send-verification-email",
             {"email": f"intruder-{uuid.uuid4().hex[:8]}@example.test", "name": "x"})
    except HTTPError as e:
        assert e.code == 400, f"registration refused with HTTP {e.code}, expected 400"
        print("signups closed: new registration refused")
        return
    raise AssertionError("a new registration was accepted")


def admin():
    # A valid token answers 200 with the admin page and a VW_ADMIN session
    # cookie; an invalid one answers 401.
    req = Request(BASE + "/admin", data=urlencode({"token": os.environ["ADMIN_TOKEN"]}).encode(),
                  method="POST", headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urlopen(req) as resp:
        cookie = resp.headers.get("Set-Cookie") or ""
        assert resp.status == 200 and "VW_ADMIN=" in cookie, f"admin login gave HTTP {resp.status} without a session"
    print("admin ok: token accepted")


def version():
    with urlopen(BASE + "/api/version") as resp:
        print(json.loads(resp.read().decode()))


if __name__ == "__main__":
    {"login": login, "signups-closed": signups_closed, "admin": admin, "version": version}[sys.argv[1]]()
