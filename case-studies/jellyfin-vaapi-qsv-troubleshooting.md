# Case Study: Hardware Transcode Failure on 2013-Era iGPU Silicon

**Date:** 2026-07-12
**Tags:** jellyfin / vaapi / gpu / hardware

## The problem

Hardware-accelerated video transcoding in Jellyfin failed on every
bitrate-limited request, regardless of source file or target quality.
Jellyfin's default hardware-acceleration setting was Intel Quick Sync
(QSV) — the "obvious" choice for an Intel iGPU — but every transcode
attempt exited immediately with `FFmpeg exited with code 251`.

## The investigation

The instinct on a driver failure like this is to check whether the
driver files themselves are intact — reinstall `intel-media-driver`,
check package versions, verify `/dev/dri` permissions. All of that
checked out. The driver *was* installed correctly. The transcode still
failed the same way.

The actual fix came from reading the literal ffmpeg command Jellyfin
generates for a QSV transcode, rather than trusting the dashboard
setting at face value. That command hardcodes `driver=iHD` — the Intel
Media Driver that Quick Sync depends on.

## The root cause

This isn't a config bug or a broken install. The CPU in question is a
2013-era Bay Trail-D part. Bay Trail's integrated GPU has **never**
supported the `iHD` driver — Quick Sync on this silicon generation is a
hardware wall, not a fixable driver mismatch. Forcing QSV in Jellyfin
will always hardcode `driver=iHD` into the generated ffmpeg command and
fail on every attempt, no matter how correctly the driver package itself
is installed.

## The fix

Switched Jellyfin's hardware-acceleration backend from Quick Sync to
**VA-API**, explicitly pinning the legacy driver this hardware generation
actually supports:

```yaml
environment:
  - LIBVA_DRIVER_NAME=i965
```

Hardware transcoding began working immediately and was verified at the
GPU-engine level (via `intel_gpu_top`) during subsequent load testing —
confirming actual VCS (video) engine utilization during a transcode, not
just the absence of an error message.

## Lesson

"The error went away" isn't the same as "the fix is correct at the
hardware level" — verify against the actual generated command and actual
engine utilization, not a UI setting or the disappearance of an error.
Also: know which driver path your specific GPU generation actually
supports before choosing an acceleration backend based on the vendor
name alone. Quick Sync and VA-API both being "Intel" doesn't mean both
are available on every Intel iGPU generation.
