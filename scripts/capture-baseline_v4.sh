#!/usr/bin/env bash
#
# v4 — reworked from v3's single mid-window snapshot + start/end cgroup diff
# into continuous time-series sampling across the ENTIRE window at a fixed
# interval (default 30s). Every metric (mpstat, iostat, free, sensors,
# docker stats, cgroup cpu.stat, intel_gpu_top) now produces a series of
# timestamped samples instead of one point-in-time guess.
#
# Navidrome was already in v3's CONTAINERS list but only got a crude
# start/end diff. In v4 it gets the same full 30-second-resolution
# per-interval throttling tracking as jellyfin/photoprism/cryptpad/
# filebrowser.
#
# Usage: ./capture-baseline.sh <tier-label> <window-minutes> [interval-seconds]
#   e.g. ./capture-baseline.sh tier2-average 30
#   e.g. ./capture-baseline.sh tier4-extreme 20 15   # 15s interval instead of 30s
#
# Run this ONCE the tier's real-usage scenario is already in steady state
# (stream already playing, index job already running, CryptPad doc already
# open and being edited, Filebrowser transfer already in progress, etc.) —
# this script doesn't start any load itself.
#
# The whole script blocks for ~<window-minutes> minutes. That's expected.
# Only asks for the sudo password ONCE at the start (for intel_gpu_top),
# then keeps the credential cached for the whole run via a background
# keepalive — you won't get re-prompted mid-window.
#
# NOTE (public copy): CONTAINERS below still lists `photoprism`, carried
# over from the load-test plan written before the PhotoPrism -> Immich
# migration (2026-07-28). On the current stack, replace it with
# `immich-server`. A tracked container that isn't running is recorded as
# NA in cpu-stat-raw.csv rather than aborting the run.

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <tier-label> <window-minutes> [interval-seconds, default 30]"
  echo "  e.g. $0 tier2-average 30"
  exit 1
fi

TIER="$1"
WINDOW_MIN="$2"
INTERVAL="${3:-30}"
WINDOW_SEC=$((WINDOW_MIN * 60))
# Ceiling division so mpstat/iostat/free run at least the full window,
# never slightly short of it.
SAMPLES=$(( (WINDOW_SEC + INTERVAL - 1) / INTERVAL ))
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$HOME/homelab-test-logs/${TIER}-${TS}"
mkdir -p "$OUTDIR"

# cryptpad (1.0 cpu cap) and filebrowser (0.5 cpu cap, new sdb I/O actor)
# tracked alongside jellyfin/photoprism since v3. navidrome added here too
# (was previously only end-to-end diffed, now full time series like the
# others). vaultwarden intentionally left out — 0.5 cpu cap, low-intensity
# Rust binary, not a realistic throttling candidate; add back if that
# assumption ever needs checking.
CONTAINERS=(jellyfin photoprism cryptpad filebrowser navidrome)

echo "=================================================================="
echo "Tier: $TIER   Window: ${WINDOW_MIN} min   Interval: ${INTERVAL}s   Samples: ${SAMPLES}"
echo "Output: $OUTDIR"
echo "=================================================================="

if [[ "$TIER" == *idle* ]]; then
  echo ">>> Reminder: close any open Jellyfin/Portainer/PhotoPrism/Beszel/"
  echo ">>> CryptPad dashboard or document tabs now — an open tab polls"
  echo ">>> (or, for CryptPad, holds a live WebSocket) and will show up as"
  echo ">>> nonzero 'idle' CPU that isn't really idle."
  echo
fi

# --- pre-flight RAM headroom check ---------------------------------------
echo "[preflight] RAM headroom check..."
{
  echo "Summed docker-compose mem_limit across all services: ~7104 MB (~6.94 GiB)"
  echo "Host RAM: 8 GiB — nominal headroom: ~900 MB-1 GiB for kernel/Docker/page cache."
  echo
  free -h
} | tee "$OUTDIR/preflight-ram.log"
echo

# --- sudo priming (only prompt once, for the whole window) ---------------
echo "[preflight] Priming sudo for intel_gpu_top (only asks once for the whole window)..."
sudo -v
(
  while true; do
    sudo -n true 2>/dev/null || true
    sleep 60
    kill -0 "$$" 2>/dev/null || exit
  done
) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

START_EPOCH=$(date +%s)
END_EPOCH=$((START_EPOCH + WINDOW_SEC))

echo "Window: $(date -d "@$START_EPOCH" '+%H:%M:%S') -> $(date -d "@$END_EPOCH" '+%H:%M:%S')"
echo

# --- self-sampling tools (native repeat flags, one process each) --------

mpstat -P ALL "$INTERVAL" "$SAMPLES" > "$OUTDIR/mpstat-timeseries.log" 2>&1 &
MPSTAT_PID=$!

iostat -x "$INTERVAL" "$SAMPLES" > "$OUTDIR/iostat-timeseries.log" 2>&1 &
IOSTAT_PID=$!

free -h -s "$INTERVAL" -c "$SAMPLES" > "$OUTDIR/free-timeseries.log" 2>&1 &
FREE_PID=$!

# intel_gpu_top self-samples internally at -s <ms>; one long-lived process
# for the whole window instead of repeated sudo calls. Entries appear
# sequentially every $INTERVAL seconds starting from launch time — there's
# no embedded per-block timestamp in plain-text mode, so correlate by
# position (block N started at START_EPOCH + N*INTERVAL).
sudo timeout "$((WINDOW_SEC + 10))" intel_gpu_top -o - -s "$((INTERVAL * 1000))" \
  > "$OUTDIR/intel_gpu_top-timeseries.log" 2>&1 &
GPU_PID=$!

# --- manual timestamped loops (no native repeat flag available) ---------

sensors_loop() {
  while [ "$(date +%s)" -lt "$END_EPOCH" ]; do
    {
      echo "=== $(date -Iseconds) ==="
      sensors 2>/dev/null || echo "(lm-sensors not available)"
    } >> "$OUTDIR/sensors-timeseries.log"
    sleep "$INTERVAL"
  done
}
sensors_loop &
SENSORS_PID=$!

docker_stats_loop() {
  echo "timestamp,container,cpu_perc,mem_usage" > "$OUTDIR/docker-stats-timeseries.csv"
  while [ "$(date +%s)" -lt "$END_EPOCH" ]; do
    ts=$(date +%s)
    docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" 2>/dev/null \
      | while IFS= read -r line; do
          echo "${ts},${line}" >> "$OUTDIR/docker-stats-timeseries.csv"
        done
    sleep "$INTERVAL"
  done
}
docker_stats_loop &
DOCKERSTATS_PID=$!

# cgroup cpu.stat — the key rework. Every interval, snapshot nr_periods/
# nr_throttled/throttled_usec per container into a raw CSV. Post-processed
# below into per-interval deltas so you can see WHICH 30-second window a
# throttling event happened in, not just "somewhere in the last 15 minutes."
cgroup_loop() {
  echo "timestamp,container,nr_periods,nr_throttled,throttled_usec" > "$OUTDIR/cpu-stat-raw.csv"
  while [ "$(date +%s)" -lt "$END_EPOCH" ]; do
    ts=$(date +%s)
    for c in "${CONTAINERS[@]}"; do
      stat=$(docker exec "$c" cat /sys/fs/cgroup/cpu.stat 2>/dev/null || true)
      if [ -z "$stat" ]; then
        echo "${ts},${c},NA,NA,NA" >> "$OUTDIR/cpu-stat-raw.csv"
        continue
      fi
      nr_periods=$(awk '/^nr_periods/{print $2}' <<< "$stat")
      nr_throttled=$(awk '/^nr_throttled/{print $2}' <<< "$stat")
      throttled_usec=$(awk '/^throttled_usec/{print $2}' <<< "$stat")
      echo "${ts},${c},${nr_periods:-NA},${nr_throttled:-NA},${throttled_usec:-NA}" >> "$OUTDIR/cpu-stat-raw.csv"
    done
    sleep "$INTERVAL"
  done
}
cgroup_loop &
CGROUP_PID=$!

echo "All samplers launched. Blocking for the full ${WINDOW_MIN}-minute window..."
echo "(mpstat/iostat/free self-sample; sensors/docker-stats/cgroup loop manually; intel_gpu_top self-samples via -s)"
echo

# Wait on the fixed-count tools first (they'll finish close to on-schedule)
wait "$MPSTAT_PID" "$IOSTAT_PID" "$FREE_PID" "$GPU_PID" 2>/dev/null || true
# Then the time-bounded loops (they check END_EPOCH themselves, should already be close to done)
wait "$SENSORS_PID" "$DOCKERSTATS_PID" "$CGROUP_PID" 2>/dev/null || true

echo "Capture window complete."
echo

# --- post-process cgroup raw samples into per-interval diffs -------------
echo "[postprocess] Computing per-interval throttling deltas..."
{
  echo "timestamp,container,nr_periods,nr_throttled,throttled_usec,delta_nr_throttled,delta_throttled_usec"
  awk -F, '
    NR==1 { next }  # skip header
    {
      ts=$1; c=$2; np=$3; nt=$4; tu=$5
      if (nt == "NA" || tu == "NA") {
        print ts","c","np","nt","tu",NA,NA"
        delete last_nt[c]; delete last_tu[c]
        next
      }
      if (c in last_nt) {
        dnt = nt - last_nt[c]
        dtu = tu - last_tu[c]
      } else {
        dnt = 0
        dtu = 0
      }
      print ts","c","np","nt","tu","dnt","dtu
      last_nt[c] = nt
      last_tu[c] = tu
    }
  ' "$OUTDIR/cpu-stat-raw.csv"
} > "$OUTDIR/cpu-stat-diffs.csv"

# --- summary: total throttling over the whole window, per container -----
echo "[postprocess] Whole-window throttling summary (first sample vs. last sample):"
{
  echo "Whole-window cgroup throttling summary — $TIER (${WINDOW_MIN} min, ${INTERVAL}s interval)"
  echo "=========================================================================="
  for c in "${CONTAINERS[@]}"; do
    first_nt=$(awk -F, -v c="$c" '$2==c && $4!="NA" {print $4; exit}' "$OUTDIR/cpu-stat-raw.csv")
    first_tu=$(awk -F, -v c="$c" '$2==c && $5!="NA" {print $5; exit}' "$OUTDIR/cpu-stat-raw.csv")
    last_nt=$(awk -F, -v c="$c" '$2==c && $4!="NA" {v=$4} END{print v}' "$OUTDIR/cpu-stat-raw.csv")
    last_tu=$(awk -F, -v c="$c" '$2==c && $5!="NA" {v=$5} END{print v}' "$OUTDIR/cpu-stat-raw.csv")
    echo
    echo "--- $c ---"
    if [ -z "${first_nt:-}" ] || [ -z "${last_nt:-}" ]; then
      echo "  (container not running for some/all of the window — see cpu-stat-raw.csv)"
      continue
    fi
    delta_nt=$(( last_nt - first_nt ))
    delta_tu=$(( last_tu - first_tu ))
    delta_ms=$(( delta_tu / 1000 ))
    echo "  nr_throttled:   $first_nt -> $last_nt   (whole-window delta: $delta_nt periods)"
    echo "  throttled_usec: $first_tu -> $last_tu   (whole-window delta: ${delta_tu}us = ${delta_ms}ms)"
    if [ "$delta_nt" -gt 0 ]; then
      echo "  >>> Check cpu-stat-diffs.csv for $c to see WHICH interval(s) it happened in."
    else
      echo "  No throttling detected for $c across the whole window."
    fi
  done
} | tee "$OUTDIR/cpu-stat-summary.log"

echo
echo "=================================================================="
echo "Done. All files saved under: $OUTDIR"
echo
echo "Time-series files (one row per ${INTERVAL}s sample):"
echo "  cpu-stat-raw.csv       — cumulative nr_periods/nr_throttled/throttled_usec per container per sample"
echo "  cpu-stat-diffs.csv     — same, PLUS delta since the previous sample (the key new output)"
echo "  cpu-stat-summary.log   — whole-window first-vs-last summary per container"
echo "  docker-stats-timeseries.csv — CPU%/MemUsage per container per sample"
echo "  mpstat-timeseries.log  — one mpstat block per sample (native repeat)"
echo "  iostat-timeseries.log  — one iostat block per sample (native repeat, discard first block)"
echo "  free-timeseries.log    — one free -h block per sample (native repeat)"
echo "  sensors-timeseries.log — timestamped sensors dump per sample"
echo "  intel_gpu_top-timeseries.log — continuous VCS/RCS samples for the whole window"
echo "  preflight-ram.log"
echo
echo "Containers tracked in cgroup diffs: ${CONTAINERS[*]}"
echo "(Navidrome now gets the same 30s-resolution treatment as the others.)"
echo
echo "Remember to also note manually (no command for these):"
echo "  - Beszel dashboard graphs for this window (beszel.lab)"
echo "  - Uptime Kuma response times for this window (uptime.lab)"
echo "  - Jellyfin Active Devices dashboard — confirm actual Play Method"
echo "    (Direct Play vs. Direct Stream vs. Transcode), not just what it looks like"
echo "  - Navidrome: direct-play or transcode, and target codec if transcoding"
echo "  - PhotoPrism: did indexing visibly slow or stall under combined load?"
echo "  - CryptPad: any visible input lag/save delay in the editor during the window?"
echo "  - Filebrowser: if a transfer was running, did its throughput visibly drop?"
echo "=================================================================="
