# Engineering Log

A dated record of how this stack was actually built — deploys, migrations,
and real troubleshooting, not just a final-state snapshot. Entries marked
🔦 have a full write-up in [`case-studies/`](../case-studies/).

Hardware and design rationale live in the [README](../README.md); this
log is the "how it happened," not the "what it looks like now."

---

## Phase 1 — Foundation (Jul 7 – 9)

- **Jul 7** — Initial Docker stack deployed behind Caddy, with an internal
  CA issuing TLS certs for every `*.lab` domain. Diagnosed and resolved a
  Portainer first-boot lockout (its anti-hijack self-lock triggers if the
  first-run admin setup isn't completed within a few minutes of first
  start).
- **Jul 8** — 🔦 [Root-caused a months-long silent backup failure](../case-studies/restic-password-xxd-diagnosis.md)
  to a mis-remembered restic password, using byte-level capture of manual
  terminal input rather than trusting the recalled value. Weekly backup
  automation deployed afterward.
- **Jul 8** — Deployed Uptime Kuma and Beszel for lightweight monitoring,
  sized against the 8GB RAM ceiling. Beszel's agent wired over a Unix
  socket instead of a network port — zero extra TCP exposure for the
  metrics pipeline.
- **Jul 9** — Direct host-port mappings removed from every service now
  that Caddy fronts all of them. Root-caused a host-DNS/Pi-hole
  resolver inconsistency and deliberately left it as-is — pointing the
  host's own resolver at its own DNS filter container would create a
  circular single point of failure.

## Phase 2 — Expansion & Hardening (Jul 11 – 13)

- **Jul 11** — SMART monitoring enabled on the metrics agent; a disk
  health attribute (`Load_Cycle_Count`) found sitting at its normalized
  failure threshold. 🔦 Full root-cause investigation (spans this date and
  Aug 4) written up in
  [`hdd-idle3-firmware-investigation.md`](../case-studies/hdd-idle3-firmware-investigation.md).
- **Jul 12** — Deployed CryptPad, Filebrowser, and Vaultwarden, each
  proxied through Caddy and given first-time security hardening.
- **Jul 12** — 🔦 [Diagnosed a hardware video-transcode failure](../case-studies/jellyfin-vaapi-qsv-troubleshooting.md)
  to a driver/codec mismatch between Quick Sync and 2013-era iGPU
  silicon. Fixed and verified at the GPU-engine level, not just "the
  error went away."
- **Jul 13** — First consolidated disaster-recovery/rebuild runbook
  drafted, covering both a same-hardware and an upgraded-hardware
  rebuild path.

## Phase 3 — Migration & Load Testing (Jul 28 – Aug 3)

- **Jul 28** — Photo-management service migrated from PhotoPrism to
  Immich (lighter-weight, no ML container given the CPU's lack of AVX).
  Bulk library import completed via CLI; admin password recovery
  performed non-destructively using the vendor's own reset path.
- **Aug 1** — Load-test plan reconciled against three newly added
  services (CryptPad, Filebrowser, Vaultwarden); CPU/RAM oversubscription
  formally quantified as a first-class risk rather than an assumption.
- **Aug 3** — 🔦 [Load-test capture tooling reworked](../case-studies/load-test-tooling-evolution.md)
  ([`capture-baseline_v4.sh`](../scripts/capture-baseline_v4.sh))
  from a single mid-window snapshot into full time-series sampling.
  First real concurrent-transcode result set surfaced an undersized CPU
  allocation on Navidrome (7.3% of the test window spent
  cgroup-throttled at realistic household load). **Note:** the script's tracked-container list still names
  `photoprism`, carried over from the test plan written before the Jul 28
  migration — see the script's header note.

## Phase 4 — Portfolio Build (Aug 4)

- **Aug 4** — 🔦 [Debugged a reverse-proxy crash-loop](../case-studies/caddyfile-quote-crashloop.md)
  caused by a stray quote corrupting a bcrypt hash in the Caddyfile.
  Reconstructed the rebuild runbook against live configuration,
  surfacing and closing four real drift discrepancies between
  documentation and the running system. Public portfolio package
  (sanitized compose file, README, architecture diagram) drafted the
  same session.


## Phase 5 — Pre-publication audit (Nov 10)

- **Nov 10** — Audited this repo's claims against the live system before
  publishing. restic's snapshot history (`snapshots --group-by paths`)
  showed only root-filesystem snapshots, which contradicted the draft
  README: the second, application-data backup job had been designed but
  never deployed. Corrected the docs to match and listed the job as
  deferred rather than describing it as running.

---

## Other write-ups

- 🔦 [Container network name resolution bug](../case-studies/docker-network-name-resolution.md) —
  Compose's automatic network-name prefixing broke an external one-off
  container join; surfaced during the Jul 28 migration work.
- 🔦 [Load-test tooling evolution (v1 → v4)](../case-studies/load-test-tooling-evolution.md) —
  how the capture methodology moved from single-snapshot sampling to
  full time-series tracking, and why several real throttling events were
  invisible until it did.
