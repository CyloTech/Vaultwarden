# Testing Framework for Vaultwarden Appbox App

Complete all applicable tests before submitting.

---

## Prerequisites

- Docker installed and running
- `Dockerfile`, `entrypoint.sh`, `moduser.sh`, `register_user.py`, `appbox.yml`, and `icon.png` in the repo

---

## 1. Build

```bash
docker build -t vaultwarden-appbox .
```

**Checklist:**

- [ ] Build completes without errors
- [ ] No hardcoded secrets in the Dockerfile
- [ ] `gosu`, `jq`, and `python3` are installed
- [ ] `entrypoint.sh` is set as `ENTRYPOINT`
- [ ] `CMD` is `/vaultwarden`

---

## 2. Fresh Install

```bash
docker volume create vw-data

docker run --rm \
  -e USERNAME='admin@example.com' \
  -e PASSWORD='TestPass123!' \
  -e ADMIN_TOKEN='AdminToken123!' \
  -e INSTANCE_ID=test-fresh \
  -e SKIP_APPBOX_CALLBACK=1 \
  -e DOMAIN=http://localhost \
  -v vw-data:/data \
  -p 8080:80 \
  vaultwarden-appbox
```

**Checklist:**

- [ ] Container starts without errors
- [ ] `/etc/app_configured` is created
- [ ] Admin token is hashed and written to `/data/config.json`
- [ ] `ADMIN_TOKEN` env var is unset before Vaultwarden starts
- [ ] Vaultwarden starts temporarily with `SIGNUPS_ALLOWED=true`
- [ ] `register_user.py` creates the admin account successfully
- [ ] `signups_allowed: false` is written to `/data/config.json`
- [ ] Temporary Vaultwarden is stopped cleanly
- [ ] API callback is attempted in the background (will fail locally — expected; Vaultwarden still starts)
- [ ] Vaultwarden starts as the main process
- [ ] Web vault is accessible at `http://localhost:8080`
- [ ] Can log in with `admin@example.com` / `TestPass123!`
- [ ] Admin panel is accessible at `http://localhost:8080/admin` with the token
- [ ] Public registration is disabled (new signups rejected)

---

## 3. Restart

```bash
docker run -d --name vw-test \
  -e USERNAME='admin@example.com' \
  -e PASSWORD='TestPass123!' \
  -e ADMIN_TOKEN='AdminToken123!' \
  -e INSTANCE_ID=test-restart \
  -e SKIP_APPBOX_CALLBACK=1 \
  -e DOMAIN=http://localhost \
  -v vw-data:/data \
  -p 8080:80 \
  vaultwarden-appbox

# Wait for startup, then restart
docker restart vw-test
```

**Checklist:**

- [ ] Container restarts without errors
- [ ] Entrypoint skips ALL setup (`/etc/app_configured` exists)
- [ ] No duplicate user creation attempted
- [ ] No callback attempted
- [ ] Admin token in `config.json` is preserved (not overwritten)
- [ ] Web vault is accessible and working
- [ ] Previous account and data still work
- [ ] Signups remain disabled

---

## 4. Upgrade

```bash
docker stop vw-test && docker rm vw-test

docker build -t vaultwarden-appbox .

docker run --rm \
  -e USERNAME='admin@example.com' \
  -e PASSWORD='TestPass123!' \
  -e ADMIN_TOKEN='AdminToken123!' \
  -e INSTANCE_ID=test-upgrade \
  -e SKIP_APPBOX_CALLBACK=1 \
  -e DOMAIN=http://localhost \
  -v vw-data:/data \
  -p 8080:80 \
  vaultwarden-appbox
```

**Checklist:**

- [ ] Container starts without errors
- [ ] Entrypoint detects existing data (upgrade path)
- [ ] User creation is SKIPPED
- [ ] Admin token in `config.json` preserved from volume (not overwritten)
- [ ] API callback is attempted
- [ ] All previous data preserved (accounts, vault items, organizations)
- [ ] Login still works with original credentials
- [ ] Signups remain disabled

---

## 5. Process and UID Verification

```bash
docker exec vw-test ps aux
```

**Checklist:**

- [ ] `/vaultwarden` is running as UID 1000 (not root)
- [ ] `/vaultwarden` is PID 1
- [ ] No orphan processes

```bash
docker exec vw-test ls -ln /data/
```

- [ ] All data files owned by `1000:1000`

---

## 6. Signal Handling

```bash
time docker stop vw-test
```

**Checklist:**

- [ ] Container stops within 10 seconds
- [ ] No data corruption after stop

---

## 7. Environment Variables

```bash
docker exec vw-test env | grep -E 'DOMAIN|INSTANCE_ID|USERNAME'
```

**Checklist:**

- [ ] `DOMAIN` is set correctly
- [ ] `ADMIN_TOKEN` is NOT in the environment (unset by entrypoint)
- [ ] Admin token works via `config.json`

---

## 8. Persistence Verification

```bash
# Log in via a Bitwarden client and add a vault item, then:
docker stop vw-test && docker rm vw-test

docker run -d --name vw-test2 \
  -e USERNAME='admin@example.com' \
  -e PASSWORD='TestPass123!' \
  -e ADMIN_TOKEN='AdminToken123!' \
  -e INSTANCE_ID=test-persist \
  -e SKIP_APPBOX_CALLBACK=1 \
  -e DOMAIN=http://localhost \
  -v vw-data:/data \
  -p 8080:80 \
  vaultwarden-appbox
```

**Checklist:**

- [ ] Vault items persist across container replacement
- [ ] Account credentials persist
- [ ] Organizations and collections persist
- [ ] Admin panel settings persist
- [ ] `signups_allowed` remains `false` in config.json

---

## 9. Security

**Checklist:**

- [ ] Master password uses `complexPassword` validation
- [ ] No default/hardcoded credentials
- [ ] Admin token is Argon2-hashed in `config.json` (not plaintext)
- [ ] Public registration is disabled after initial setup
- [ ] Vaultwarden binds to `0.0.0.0`
- [ ] No unnecessary ports exposed
- [ ] `entrypoint.sh` does not download external scripts

---

## 10. Password Change Script (moduser.sh)

```bash
docker exec vw-test /moduser.sh "NewToken456!"
echo $?
```

**Checklist:**

- [ ] `/moduser.sh` exists and is executable
- [ ] Accepts one argument (new admin token)
- [ ] Updates `config.json` with hashed token
- [ ] Prints usage and exits non-zero with no arguments
- [ ] After container restart, new token works for admin panel access

```bash
docker exec vw-test /moduser.sh
# Should print usage and exit non-zero
```

---

## 11. Registration Script (register_user.py)

Verify the Bitwarden key derivation produces a valid account.

```bash
# After fresh install, confirm:
# 1. User can log in via the web vault
# 2. User can log in via the Bitwarden CLI:
#    bw config server http://localhost:8080
#    bw login admin@example.com TestPass123!
# 3. Vault operations work (add/edit/delete items)
```

**Checklist:**

- [ ] Registration succeeds on fresh install
- [ ] Created account works with all official Bitwarden clients
- [ ] Key derivation matches Bitwarden protocol (PBKDF2 + HKDF + AES)
- [ ] RSA keypair is generated and encrypted correctly

---

## 12. appbox.yml Validation

**Checklist:**

- [ ] `app.display_name` and `app.publisher` are set
- [ ] `app.description` and `app.short_description` are meaningful
- [ ] `app.icon` points to a valid 512x512 PNG
- [ ] `app.categories` lists "Privacy"
- [ ] `image.name` and `image.version` are set
- [ ] No ports defined (web-only app, uses nginx reverse proxy)
- [ ] `volumes` covers `/data` with `uid: 1000`
- [ ] `USERNAME` field uses `email` type with email validation
- [ ] `PASSWORD` field uses `complexPassword` validation
- [ ] `ADMIN_TOKEN` field auto-generates with `%RAND.48%`
- [ ] `behavior.expect_callback` is `true`
- [ ] `DOMAIN` env uses `template_type: instance`

---

## Quick Reference

```bash
# Build
docker build -t vaultwarden-appbox .

# Fresh install
docker volume create vw-data
docker run -d --name vw-test \
  -e USERNAME='admin@example.com' -e PASSWORD='TestPass123!' \
  -e ADMIN_TOKEN='AdminToken123!' -e INSTANCE_ID=test \
  -e SKIP_APPBOX_CALLBACK=1 -e DOMAIN=http://localhost \
  -v vw-data:/data -p 8080:80 vaultwarden-appbox

# Check logs
docker logs -f vw-test

# Check process owner
docker exec vw-test ps aux

# Check file ownership
docker exec vw-test ls -ln /data/

# Verify signups disabled
docker exec vw-test jq '.signups_allowed' /data/config.json

# Restart test
docker restart vw-test

# Upgrade test
docker stop vw-test && docker rm vw-test
docker build -t vaultwarden-appbox .
docker run -d --name vw-test \
  -e USERNAME='admin@example.com' -e PASSWORD='TestPass123!' \
  -e ADMIN_TOKEN='AdminToken123!' -e INSTANCE_ID=test \
  -e SKIP_APPBOX_CALLBACK=1 -e DOMAIN=http://localhost \
  -v vw-data:/data -p 8080:80 vaultwarden-appbox

# Admin token change test
docker exec vw-test /moduser.sh "NewToken456!"

# Graceful shutdown
time docker stop vw-test

# Debug shell
docker exec -it vw-test bash

# Cleanup
docker stop vw-test && docker rm vw-test
docker volume rm vw-data
```
