#!/usr/bin/env python3
"""
Register a Bitwarden-compatible account on a Vaultwarden instance.

Replicates the client-side key derivation that Bitwarden clients perform:
  1. PBKDF2-SHA256 to derive the master key from (password, email)
  2. HKDF-Expand to stretch the master key into enc + mac keys
  3. AES-256-CBC (via openssl) to encrypt the generated symmetric key
  4. RSA 2048 keypair (via openssl) encrypted with the symmetric key
  5. POST /identity/accounts/register/send-verification-email for a
     registration token (returned directly while SIGNUPS_VERIFY is off)
  6. POST /identity/accounts/register/finish with the token and the keys

Vaultwarden 1.37.4 removed the single-step /identity/accounts/register.
"""

import hashlib
import hmac as hmac_mod
import json
import os
import subprocess
import sys
from base64 import b64encode
from urllib.error import HTTPError
from urllib.request import Request, urlopen

KDF_ITERATIONS = 600_000


def pbkdf2(password, salt, iterations, dklen=32):
    if isinstance(password, str):
        password = password.encode("utf-8")
    if isinstance(salt, str):
        salt = salt.encode("utf-8")
    return hashlib.pbkdf2_hmac("sha256", password, salt, iterations, dklen)


def hkdf_expand(prk, info, length=32):
    """HKDF-Expand (RFC 5869). PRK is used directly — no Extract step,
    matching the Bitwarden client implementation."""
    if isinstance(info, str):
        info = info.encode("utf-8")
    n = (length + 31) // 32
    okm = b""
    prev = b""
    for i in range(1, n + 1):
        prev = hmac_mod.new(prk, prev + info + bytes([i]), hashlib.sha256).digest()
        okm += prev
    return okm[:length]


def aes_cbc_encrypt(plaintext, key, iv):
    """AES-256-CBC with PKCS#7 padding via openssl CLI."""
    r = subprocess.run(
        ["openssl", "enc", "-aes-256-cbc", "-K", key.hex(), "-iv", iv.hex()],
        input=plaintext,
        capture_output=True,
    )
    if r.returncode != 0:
        raise RuntimeError(f"openssl enc failed: {r.stderr.decode()}")
    return r.stdout


def bw_encrypt(plaintext, enc_key, mac_key):
    """Encrypt in Bitwarden EncString format (type 2 = AesCbc256_HmacSha256_B64)."""
    iv = os.urandom(16)
    ct = aes_cbc_encrypt(plaintext, enc_key, iv)
    mac = hmac_mod.new(mac_key, iv + ct, hashlib.sha256).digest()
    return "2.{}|{}|{}".format(
        b64encode(iv).decode(),
        b64encode(ct).decode(),
        b64encode(mac).decode(),
    )


def generate_rsa_keypair():
    """Return (public_key_der, private_key_pkcs8_der) via openssl."""
    pem = subprocess.run(
        ["openssl", "genrsa", "2048"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout

    pub = subprocess.run(
        ["openssl", "rsa", "-pubout", "-outform", "DER"],
        input=pem,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout

    priv = subprocess.run(
        ["openssl", "pkcs8", "-topk8", "-nocrypt", "-outform", "DER"],
        input=pem,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout

    return pub, priv


def post_json(url, payload):
    """POST JSON and return the decoded JSON response (None when empty)."""
    req = Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with urlopen(req) as resp:
        body = resp.read().decode("utf-8")
        return json.loads(body) if body else None


def register(server_url, email, password, name="Admin"):
    email = email.lower().strip()

    master_key = pbkdf2(password, email, KDF_ITERATIONS)
    master_pw_hash = b64encode(pbkdf2(master_key, password, 1)).decode()

    stretched_enc = hkdf_expand(master_key, "enc", 32)
    stretched_mac = hkdf_expand(master_key, "mac", 32)

    sym_key = os.urandom(64)
    protected_key = bw_encrypt(sym_key, stretched_enc, stretched_mac)

    pub_der, priv_der = generate_rsa_keypair()
    enc_priv = bw_encrypt(priv_der, sym_key[:32], sym_key[32:])

    identity_url = f"{server_url.rstrip('/')}/identity/accounts/register"

    try:
        # The account name travels inside the token's claims.
        token = post_json(f"{identity_url}/send-verification-email", {"email": email, "name": name})
        if not isinstance(token, str) or not token:
            print(
                "Registration failed: no registration token was returned "
                "(email verification for signups is enabled)",
                file=sys.stderr,
            )
            return False

        payload = {
            "email": email,
            "emailVerificationToken": token,
            "masterPasswordHash": master_pw_hash,
            "masterPasswordHint": "",
            "key": protected_key,
            "kdf": 0,
            "kdfIterations": KDF_ITERATIONS,
            "kdfMemory": None,
            "kdfParallelism": None,
            "keys": {
                "publicKey": b64encode(pub_der).decode(),
                "encryptedPrivateKey": enc_priv,
            },
        }
        post_json(f"{identity_url}/finish", payload)
        print(f"User {email} registered successfully")
        return True
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"Registration failed (HTTP {e.code}): {body}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"Registration error: {e}", file=sys.stderr)
        return False


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <server_url> <email> <password>", file=sys.stderr)
        sys.exit(1)
    sys.exit(0 if register(sys.argv[1], sys.argv[2], sys.argv[3]) else 1)
