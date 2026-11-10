# phubuntuserver — Architecture & Rebuild Runbook (Public Edition)

**Status:** sanitized for public portfolio use. Derived from a private,
fully-detailed operational runbook (the internal
source of truth — not published). This document preserves the
architecture, decisions, and troubleshooting substance; it removes anything
that would be a real credential, real network topology detail, or personal
identifying information.

**What changed from the private version:** every `<REDACTED>` marker below
replaces a real value that exists only in the private runbook and an
offline encrypted vault. Nothing in this document is sufficient to
reconstruct access to the live system.

---

## 1. Overview

A single-box home server running a self-hosted service stack behind a
reverse proxy with a private internal certificate authority, built and
rebuilt with an explicit runbook rather than ad hoc changes. Two hardware
targets are documented side by side since the rebuild is written to work
on either the current low-power CPU or a planned mini-PC upgrade — the
architecture doesn't change, only a handful of hardware-dependent settings
do.

**Current hardware:** dual-core low-power x86 CPU (no hyperthreading),
8GB RAM, integrated GPU with hardware video decode/encode limited to
H.264, one SSD for boot/Docker root, one HDD for bulk storage.

**Stack (12 containerized services + 1 native service):** media server,
music server, ebook server, photo management, encrypted collaborative
document editor, web-based file manager, self-hosted password manager,
reverse proxy / TLS termination, container management UI, host+container
metrics monitoring (agent + hub), uptime/reachability monitoring, and a
native (non-containerized) DNS filter + resolver.

---

## 2. Architecture

**Request flow (LAN):**
```
LAN client → DNS filter/resolver (native, non-standard ports)
           → A record for *.lab domain
           → Reverse proxy (ports 80/443, internal-CA TLS)
           → container:internal_port over an isolated bridge network
```

**DNS chain:** client → DNS filter → recursive resolver → root servers.

**Admin/shell access:** direct SSH to the host, guarded by an
SSH-brute-force mitigation daemon. Not proxied through the reverse proxy.

**Container privilege boundary:** the container-management UI does not
hold a direct mount of the Docker control socket in the target
architecture — it talks to Docker through a read-only, capability-scoped
proxy container instead, so a compromise of the management UI's web
interface doesn't hand over host-root-equivalent access to the whole
container runtime. (Deployment of this proxy is tracked as a timing
decision, not yet finalized — see §7.)

A key design decision, worth calling out explicitly: **the host's own DNS
resolver is deliberately not pointed at its own DNS filter service.**
Doing so would create a circular dependency — if the DNS filter goes down
or restarts, the host would lose all DNS resolution, including the
ability to fetch OS package updates needed to fix the problem. Internal
domains are simply not resolvable from the host itself as a result; this
is treated as an accepted, documented trade-off rather than a defect.

---

## 3. Key design decisions (with rationale)

| Decision | Rationale |
|---|---|
| Reverse proxy as sole ingress, no direct host-port publishing on app containers | Every service reachable only via TLS through the proxy, ensuring consistent per-request access logging and certificate coverage. A direct IP:port hit bypasses both. |
| VA-API over Intel Quick Sync on current hardware | The current GPU generation has never supported the driver Quick Sync depends on, genuine driver binary or not — this is a hardware generation limit, not a config bug. VA-API with the correct legacy driver is the only combination that actually offloads video encode on this chip. |
| No ML/face-recognition container for photo management | The current CPU lacks the instruction-set extension (AVX) that the ML runtime requires — deploying it would only crash-loop. Documented as an intentional omission, not an oversight, with a note to re-enable once the CPU is upgraded. |
| Host DNS resolver not pointed at the local DNS filter | Avoids a single-point-of-failure where the DNS filter's own downtime takes out all host DNS resolution, including package-manager access needed to fix it. |
| Versioned root-filesystem backup + external mirrors of the data volume | The OS gets point-in-time history from a weekly backup job; service data is covered by full mirrors on external drives. A second, versioned job for application data is designed but deferred (see §4.8 and §7). |
| Offsite copy of the data volume | Two external drives mirror the data volume, one kept at a trusted offsite location, covering total loss of the server. |
| Second layer of authentication in front of the container-management UI | Even behind the reverse proxy's TLS, the management UI's own login is a single gate. An additional independently-keyed credential at the proxy layer means a leaked session cookie or an unpatched vulnerability in the UI itself still hits a wall before the application loads. |
| Native DNS filter service, not containerized | Kept outside Docker deliberately, unrelated to the containerized stack's lifecycle. |

---

## 4. Build order (sanitized)

Dependency-ordered; every step reflects the corrected end-state
configuration, not intermediate broken states encountered along the way
(see §6 for those).

### 4.1 Base OS + container engine
Standard minimal server install, container engine installed via the
vendor's official install script, current user added to the container
engine's admin group.

### 4.2 Bridge network
A dedicated bridge network isolates the stack from the host's other
network surfaces. Note: compose tooling auto-prefixes network names with
the project directory name — always verify the actual registered network
name before any external command that needs to join it explicitly.

### 4.3 Reverse proxy + internal CA (deployed first)
The proxy is deployed before any application container needs to register
a domain with it. Configuration highlights (values redacted):

```caddyfile
{
    admin off
    log {
        output file /var/log/<proxy>/access.log {
            roll_size 20mb
            roll_keep 5
        }
        format json
    }
}

<service>.lab {
    tls internal
    log
    reverse_proxy <service>:<port>
}

<admin-service>.lab {
    tls internal
    log
    basic_auth {
        <ADMIN_USER> <BCRYPT_HASH_REDACTED>
    }
    reverse_proxy <admin-service>:<port> {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
```

**Generate any basic-auth credential fresh** with the proxy's own
password-hashing tool at deploy time — never reuse or publish a real
hash. Every internal domain gets its own reverse-proxy block; a global
logging directive at the top of the config file does **not** propagate to
individual site blocks in this proxy software — each block needs its own
explicit logging directive, confirmed the hard way.

After first boot, the internal CA's root certificate must be extracted
from the running container and distributed to every client device
individually — desktop OS trust stores, mobile certificate-trust
settings (which on at least one major mobile OS require an additional
manual toggle beyond just installing the profile), and browsers that
maintain their own certificate store independent of the OS.

### 4.4 DNS
Native DNS filter + recursive resolver, deliberately left on
non-standard local ports to free the standard ports for the reverse
proxy. Local DNS records point every internal domain at the server's LAN
address — DNS records are host-only, never host:port; all port routing
is the reverse proxy's job.

### 4.5 Application services
Each service runs as its own container on the internal bridge network,
with explicit CPU and memory caps set per-container. No service publishes
a host port directly — the reverse proxy reaches every one of them by
container name over the internal network.

**Hardware-acceleration note (current hardware target):** set the media
server's transcoding backend to VA-API, never Quick Sync, and pin the
correct legacy video driver via environment variable. This is the only
combination that offloads H.264 encode on this GPU generation; anything
outside H.264 (e.g. newer codecs) will always fall back to software
transcoding regardless of setting — a hardware ceiling, not a
misconfiguration to keep chasing.

### 4.6 Monitoring
Two complementary tools, not overlapping: one answers "is a service
reachable," the other answers "why is the box or a disk struggling."
The metrics-collection agent needs a variant of its image that bundles
disk health tooling — the base image does not include it. Disk health
data collection over SATA needs one additional Linux capability; NVMe
would need a broader one (relevant only if a future hardware upgrade
introduces an NVMe boot drive).

The uptime/reachability monitor is configured to trust the internal CA
natively (root certificate mounted in, environment variable pointing at
it) rather than relying on a blanket "ignore certificate errors" toggle —
this performs genuine certificate verification instead of a bypass.

### 4.7 Admin / container management
The container-management UI's data directory is a persistent host mount.
**Complete its first-boot admin account setup within the first few
minutes** — it self-locks as an anti-hijack measure if left idle after
first start (see §6).

If the admin password is later forgotten (a distinct issue from the
first-boot lockout), the management UI vendor ships an official,
non-destructive password-reset helper container that resets the original
admin account against the same data mount — no need to wipe the data
directory or edit its database by hand.

### 4.8 Backups
One scheduled job via a systemd timer, plus external mirrors:

- **Root filesystem** — weekly, excluding standard pseudo-filesystems,
  cache, and the bulk-storage mount. Runs at low I/O/CPU priority
  (`Nice=19`, `IOSchedulingClass=idle`) with a weekly + monthly retention
  policy and automatic pruning.
- **Bulk-storage mount** — fully mirrored to two external drives, one
  kept at a trusted offsite location.

**Deferred: versioned backup of application data.** A second job covering
the bulk-storage mount's configs and databases (excluding replaceable
media) is designed but not deployed. When it is, databases are dumped
first rather than copied live, and the job runs an hour after the
root-filesystem job to avoid disk and repository-lock contention. The
backup repository also lives on the bulk-storage disk, so it guards
against mistakes, not that disk failing — the external mirrors cover that.

**Backup repository password:** stored only in an offline encrypted
vault on physically separate media, never in this document or in the
live filesystem's shell history.

---

## 5. Known hardware ceilings

| Ceiling | Current hardware | Upgrade target |
|---|---|---|
| Video encode codec support | Hardware H.264 only; newer codecs always fall back to software transcode | Broader hardware codec support expected, revalidate post-upgrade rather than assume |
| GPU engine contention under concurrent transcode | The render/copy engine saturates before the video encode engine at just two concurrent streams — an early, real finding worth designing around | Same shared-hardware-engine pattern likely applies; re-run load testing after upgrade |
| CPU instruction-set extensions | No AVX — blocks the ML-based photo features entirely | AVX2 present — ML features become viable |
| cgroup CPU oversubscription | Combined per-container CPU limits significantly exceed physical core count; scheduler arbitration under concurrent load is expected and observed, not a misconfiguration | Recompute limits against actual physical core count rather than copying forward unchanged |
| Bulk-storage HDD wear pattern | A SMART attribute tracking head-load/unload cycles was found sitting at its normalized failure threshold, traced to an aggressive vendor-firmware power-management timer (not usage-driven wear) and disabled — pending a full power cycle to take effect at the firmware level | Same physical drive if it migrates; the finding travels with the disk, not the motherboard |

---

## 6. Troubleshooting write-ups (portfolio-relevant, generalized)

These are real incidents encountered during operation, generalized enough
to be useful without exposing operational specifics.

| Issue | Root cause | Lesson |
|---|---|---|
| Non-interactive backup authentication failing while manual entry always worked | The password everyone assumed was correct (based on shell history) was never actually correct — muscle-memory autocorrect during manual, unechoed entry silently masked the real value for months | When manual entry works but every non-interactive method fails identically, capture the actual bytes being typed before investigating file/environment/encoding theories |
| Hardware video transcoding failing on every bitrate-limited request | The media server hardcoded an incompatible driver/codec path into its generated transcode command, silently overriding an already-correct environment variable | Read the actual generated command a service produces rather than trusting a dashboard setting at face value; verify a fix at the hardware-engine level, not just "the error went away" |
| Reverse proxy crash-looping after adding an authentication layer | A credential hash was wrapped in single quotes in the proxy's config file; that config format does not treat single quotes as a string delimiter, so the quote characters became part of the literal value and corrupted the hash | Know your config format's actual string-delimiter rules — an assumption borrowed from another language/format can silently corrupt a value in a way that produces a confusing downstream error |
| A container name resolution failure when joining an external one-off container to the stack's network | Compose auto-prefixes network names with the project's directory name; the network's actual registered name didn't match the name as written in the compose file | Always verify a resolved resource's real name against tooling defaults rather than assuming the name you wrote is the name that got registered |
| A forgotten admin password assumed to require wiping application state | The application's own vendor ships an official non-destructive password-reset path against the existing data mount | Check for an official recovery path before assuming state loss is required |
| A single point-in-time resource snapshot mischaracterizing system load | Transient throttling and bursty load are invisible to one instantaneous sample; two files from different capture runs can look like a contradiction when they're just measuring different moments | Time-series sampling across a full test window, with before/after diffing per interval, is necessary to attribute a performance event to a specific moment rather than "somewhere in N minutes" |

---

## 7. Open architectural decisions (as of this writing)

- **Container-socket-proxy timing** — implement ahead of any remote
  exposure of the stack, or defer until that exposure is actually being
  set up. Documented as a deliberate either/or choice, not an oversight.
- **Remote access scope** — which services join a private overlay-network
  exposure list beyond the current LAN-only posture is still being
  finalized service-by-service.
- **Versioned application-data backup** — deferred. The external
  mirrors cover disk loss but keep no history of earlier states.
- **Hardware upgrade timing** — same architecture either way; a handful
  of hardware-dependent settings (transcoding backend, AVX-gated
  features, per-service CPU caps) are the only things that change.

---

## 8. Security posture snapshot

**Current exposure model:** LAN-only, plus SSH guarded by a
brute-force-mitigation daemon scoped to SSH specifically — not a blanket
protection across every login surface. Every application-level login
(media server, password manager, container-management UI, etc.) needs
its own strong, unique credential and two-factor authentication where
supported, independent of the network-level protections above.

**Deliberate, documented trade-offs (not gaps):**
- Host DNS resolver not pointed at the internal DNS filter (§2, §3).
- The reverse proxy's connection to the container-management UI's own
  internal port has certificate verification relaxed on that one
  internal hop specifically — the client-facing connection through the
  proxy is still fully verified TLS; this only concerns the proxy's own
  backend connection to an application that terminates its own
  self-signed certificate internally.

**Standing practice:** all secrets are generated fresh on any rebuild
rather than migrated forward, with the sole exception of the backup
repository's own encryption password — regenerating that would orphan
every existing backup snapshot, so it is preserved (in an offline vault
only) rather than regenerated.

---

## Appendix: what this document deliberately omits

Per the internal sanitization pass, this public edition excludes:
real credentials and credential hashes of any kind; real LAN IP
addresses and network topology specifics beyond what's needed to explain
the architecture; real hostnames and device model/serial identifiers
where not relevant to the technical point being made; personal
identifying details; and any API key or token previously logged in
plaintext during a working session, pending confirmed rotation.

The private operational runbook this document was derived from remains
the working source of truth and is not published.
