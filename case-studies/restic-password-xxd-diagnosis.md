# Case Study: Root-Causing a Silent, Months-Long Backup Failure

**Date:** 2026-07-08 · **Tags:** backup / restic / diagnostics

## Problem
Every non-interactive restic auth method (`--password-file`,
`--password-command`, environment variable) failed against the repository.
Typing the password interactively always worked.

What made it silent: no backup schedule existed yet. Every snapshot from
December 2025 onward was a manual, interactive run, so the wrong stored
value never had to work — and nothing alerted, because there was nothing
automated to fail. The repository's own history still shows it: the
retention policy kept a manual snapshot from March 2026, then nothing until
automation finally went live in July.

## Investigation
Manual entry worked, so the repository and restic were healthy. Three
different automated paths failing identically pointed at the one thing
they share: the password value they were given.

| Hypothesis | Outcome |
|---|---|
| File encoding / trailing newline | Ruled out |
| File permissions | Ruled out |
| restic version quirk | Ruled out |
| The stored value is not what I actually type | Confirmed |

I stopped trusting the remembered value and captured the bytes my hands
actually produce:

```bash
read -s -p "test: " pw; echo -n "$pw" | xxd
```

`-s` keeps the input off screen and `echo -n` avoids adding a trailing
newline (`0a`) to the bytes being inspected. A slightly more robust
version for next time:

```bash
read -rsp "Password: " pw; echo
printf '%s' "$pw" | xxd
unset pw
```

`-r` stops backslashes being interpreted, `printf '%s'` is more portable
than `echo -n`, and `unset` clears the value from the shell afterward.
Illustration with fake values:

```
typed (works):   7333 6372 6574 21     s3cret!
in my notes:     7333 6372 3374        s3cr3t
```

## Root cause
The value in my notes and password file (originally copied from shell
history) differed from the value I actually type by one character and one
symbol. Muscle memory had the correct password; the documentation had the
wrong one. Unechoed prompts show no typos, so nothing ever surfaced it.

## Fix
Replaced the stored value with the byte-verified one. All three automated
paths authenticated. Verified end-to-end by triggering the new systemd
unit once by hand (`systemctl start restic-backup.service`) and confirming
a fresh snapshot appeared in `restic snapshots`. Weekly systemd timer
deployed afterward (`Nice=19`, `IOSchedulingClass=idle`, `Persistent=true`).

## Lesson
When manual works and every automated path fails the same way, the bug is
in the shared input, not the plumbing. Capture the bytes before testing
more theories.

## Follow-up
The password was rotated afterward with `restic key passwd`, which
re-wraps the repository's master key under a new password. Existing
snapshots were unaffected and nothing had to be re-uploaded.
