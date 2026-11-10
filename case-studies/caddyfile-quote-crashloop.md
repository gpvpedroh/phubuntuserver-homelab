# Case Study: A Reverse-Proxy Crash-Loop From One Stray Quote

**Date:** 2026-08-04 · **Tags:** caddy / reverse-proxy / config-syntax

## Summary
Adding `basic_auth` in front of Portainer sent Caddy into a crash-loop
(`illegal base64 data at input byte 0`). The bcrypt hash was fine. The
single quotes I wrapped around it in the Caddyfile became part of the
value. Caddy is the stack's only ingress, so every service was
unreachable over HTTPS until I fixed it.

## Problem
After adding a second authentication layer in front of Portainer, the
container restarted in a loop. The hash came from Caddy's own tool,
entered at the interactive prompt so the password stayed out of shell
history:

```bash
docker run --rm -it caddy:2.9.1 caddy hash-password
```

## Diagnosis
An error at byte 0 means something sits in front of the first character
of the value. `docker logs caddy` showed the error on every restart.

| Hypothesis | Check | Result |
|---|---|---|
| Hash generated incorrectly | Removed only the quotes and kept the identical hash | Caddy started: the hash was never the problem |
| Value altered between generation and use | Reviewed what I pasted into the Caddyfile | Single quotes around the hash, a shell/YAML habit |

## Root cause
The Caddyfile does not treat `'` as a string delimiter. The quotes
became literal characters and corrupted the value from its first byte.

```caddyfile
# broken
<ADMIN_USER> '<BCRYPT_HASH>'
# working: the hash has no spaces, so no quoting is needed
<ADMIN_USER> <BCRYPT_HASH>
```

## Fix
Removed the quotes and recreated the container
(`docker compose up -d --force-recreate caddy`, since `admin off` rules out
a live reload). Caddy came up clean with the same credential. Verified in a
browser: `https://portainer.lab` now shows Caddy's credential prompt before
Portainer's own login page.

A second, smaller mistake came up while testing from the CLI: I first passed
the **bcrypt hash** to `curl -u`. That's backwards — `basic_auth` hashes the
*plaintext* password the client sends and compares it to the stored hash.
The client always sends the real password (`curl -u '<user>:<password>'`),
never the hash.

## Lesson
The quotes were correct in the shell and wrong in the Caddyfile. Check
the target format's quoting rules before carrying a convention over.
The error named a symptom (bad base64), not the cause (a character I
added).