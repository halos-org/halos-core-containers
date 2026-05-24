---
title: "Bash `set -e` does NOT abort on failed command substitution inside an assignment"
date: 2026-05-24
repo: halos-core-containers
pr: https://github.com/halos-org/halos-core-containers/pull/130
tags: [bash, set-e, command-substitution, pitfall, prestart, gotcha, knowledge]
---

# Context

`prestart.sh` runs under `set -e`. The intent: any helper failure should abort the script so systemd reports a clean unit failure rather than the containers crash-looping on a half-initialized state.

The new CA work added:

```bash
CA_FINGERPRINT="$(halos_ca_fingerprint "${CA_CRT}")"
```

If the CA cert was corrupt or unreadable, `halos_ca_fingerprint` was expected to exit non-zero and `set -e` was expected to halt prestart. Neither happened — the script continued silently with `CA_FINGERPRINT=""` and produced a malformed sentinel string that triggered a re-sign loop on every subsequent boot, masking the real failure indefinitely.

# Guidance

**`set -e` does NOT trigger on a failed command substitution that is captured by a variable assignment.** This is documented bash behavior, not a bug. From the bash manual:

> If a compound command other than a subshell returns a non-zero status because a command failed while -e was being ignored, the shell does not exit.

The assignment itself succeeds (with an empty value) even when the substituted command fails. There is no way to enable abort-on-failure here without an explicit guard:

```bash
# Wrong — silent on cmd failure under set -e
var="$(cmd)"

# Right — explicit guard catches the failure
var=$(cmd) || {
    echo "cmd failed" >&2
    exit 1
}

# Also right — separate, set -e catches it
var=$(cmd)            # this still doesn't abort
test -n "$var"        # ← THIS aborts under set -e if var is empty
```

The `|| exit` pattern works because `||` examines the exit status of the rightmost command in the pipeline, which for `var=$(cmd)` is `cmd`'s exit status. `set -e` ignores this status by itself; the `||` is what makes it actionable.

# Defense-in-depth: helper-side hygiene

The caller-side guard is load-bearing, but the helper itself should also fail loudly rather than emit garbage. The original `halos_ca_fingerprint` was a pipeline:

```bash
openssl x509 -in "$crt" -noout -fingerprint -sha256 2>/dev/null \
    | sed -e 's/^.*Fingerprint=//' -e 's/://g' \
    | tr '[:upper:]' '[:lower:]'
```

Without `set -o pipefail` (which `prestart.sh` doesn't enable), a pipeline's exit status is the rightmost command's. `tr` succeeds on empty stdin, so the entire pipeline returned 0 with an empty string when `openssl` failed.

Fix at the helper:

```bash
local raw fp
if ! raw=$(openssl x509 -in "$crt" -noout -fingerprint -sha256 2>/dev/null); then
    echo "halos_ca_fingerprint: openssl x509 failed parsing $crt" >&2
    return 1
fi
fp=$(printf '%s\n' "$raw" | sed -e 's/^.*Fingerprint=//' -e 's/://g' | tr '[:upper:]' '[:lower:]')
if ! [[ "$fp" =~ ^[0-9a-f]{64}$ ]]; then
    echo "halos_ca_fingerprint: openssl produced unexpected output for $crt" >&2
    return 1
fi
printf '%s' "$fp"
```

Capture the failable step into a local var first, check it explicitly, then process. Validate the final shape before returning.

# Where this bites

Any prestart helper that wraps an external command and is consumed via `var=$(helper)` is vulnerable. Examples in this codebase that are *currently* safe but easy to break in a future refactor:

- `HOSTNAMES_HASH="$(halos_hostnames_hash)"` — the helper internally `sort | sha256sum`s the in-memory list; failure would require the binaries to be missing entirely.
- `HALOS_DOMAIN="$(halos_canonical_hostname)"` — pure-bash, can only fail if the lib was misloaded.

Neither needs the `|| exit` guard *today*, but if either is ever refactored to call out to `nmcli`, `getent`, or any other external probe, the guard becomes load-bearing. The convention is cheap; treat `var=$(helper) || exit 1` as the default shape for any helper that could fail at runtime.

# References

- Bash manual, "The Set Builtin" → `errexit` semantics
- Related: [bash-subshell-cache-priming.md](2026-04-28-bash-subshell-cache-priming.md) — separate but related bash gotcha
