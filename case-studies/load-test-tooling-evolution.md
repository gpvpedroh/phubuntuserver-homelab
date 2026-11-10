# Case Study: Load-Test Tooling Evolution — From Guessing to Measuring

**Dates:** 2026-07-11 → 2026-08-03 (v1 → v4)
**Tags:** load-testing / methodology / bash / observability

## The starting point

Rather than benchmark this hardware with synthetic tools (`stress-ng`,
`fio`), the decision from the start was to run **real workloads**:
actual Jellyfin transcodes, actual Immich/PhotoPrism imports, actual
restic backups running concurrently — because the real bottleneck on
this hardware isn't raw CPU throughput, it's contention on the **shared
GPU engines** and the **HDD serving media reads**. A synthetic tool
can't reproduce engine-level contention between a transcode and a
concurrent library scan; only real, simultaneous real workloads can.

That decision was right from v1 — what changed across four iterations
was *how* the resulting load was measured.

## v1 (Jul 11) — first tiered plan, single-point sampling

The first version defined the tiered scenario structure (idle baseline
→ average household load → peak load → extreme/stress load) but
measured each tier with effectively a single point-in-time snapshot:
run the scenario, take one reading partway through, done.

This established the right *scenarios* but the wrong *sampling model* —
a single snapshot can land anywhere in a tier's actual behavior and has
no way to distinguish "steady state" from "a brief spike I happened to
catch" or "a brief spike I happened to miss."

## v2 (Jul 12) — lessons from the first pass

Revised with per-scenario labeling and the addition of GPU render-engine
(RCS) tracking alongside video-encode-engine (VCS) tracking — a direct
result of the naive assumption ("the video encode engine will be the
transcode bottleneck") turning out to be wrong once RCS numbers were
actually looked at. Still fundamentally single-snapshot per tier,
though.

## v3 (Jul 13, superseded) → the coverage gap

By v3, more containers were being tracked (Jellyfin, PhotoPrism,
CryptPad, Filebrowser) — but Navidrome was still only measured with a
crude start/end diff rather than the same tracking given to the other
containers. This mattered: Navidrome's 0.5-core cgroup cap turned out to
be the first real breakage point under realistic multi-device load
(7.3% of a test window spent cgroup-throttled) — and a start/end diff on
its own can't show *when* within a window that throttling happened, only
that it happened at some point between two measurements.

## v4 (Aug 3) — the actual fix: continuous time-series sampling

The core rework: every metric — `mpstat`, `iostat`, `docker stats`,
cgroup `cpu.stat`, and `intel_gpu_top` — moved from a single mid-window
snapshot (plus a crude start/end diff for cgroup throttling) to
**continuous sampling at a fixed interval across the entire test
window**, producing a genuine time series instead of one guess.

Concretely, this meant:
- `mpstat`/`iostat`/`free` switched to their native repeat-count flags
  (one long-lived process instead of repeated manual invocations).
- `intel_gpu_top` runs as a single long-lived process for the whole
  window rather than repeated sudo-gated calls.
- Manual timestamped loops were added for tools with no native repeat
  flag (`sensors`, `docker stats`, cgroup `cpu.stat`), each writing a
  timestamped row per interval.
- Cgroup `cpu.stat` sampling specifically was reworked from a start/end
  diff into per-interval deltas, post-processed into a diffs CSV — so a
  throttling event can be attributed to a specific 30-second window,
  not just "somewhere in the last N minutes."
- Navidrome was brought into the same full per-interval tracking as
  every other container, closing the v3 coverage gap directly.

## Why the difference mattered in practice

This wasn't a nice-to-have refinement. Several real throttling events
were **invisible in the earlier single-snapshot captures** and only
became visible once sampling went continuous — a snapshot taken at the
wrong moment simply misses a transient spike entirely. The v4 rework is
what actually surfaced the Navidrome cgroup-cap finding with enough
precision to say *which* interval it happened in and *how much* of the
window it affected, rather than a vague "throttling occurred at some
point."

## Lesson

A single point-in-time measurement and a time series answer different
questions, even when they're nominally measuring the "same" thing. "Is
the system currently under load?" tolerates a snapshot. "Did the system
get throttled at some point during a 30-minute window, and if so, when
and for how long?" requires continuous sampling — the earlier tooling
versions were answering a question the project didn't actually need
answered, and it took watching a real throttling event get missed to
notice the mismatch.
