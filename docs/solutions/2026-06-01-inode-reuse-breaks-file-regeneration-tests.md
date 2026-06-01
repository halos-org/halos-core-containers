---
title: "Detect file regeneration by content hash, not inode — Linux reuses freed inode numbers"
date: 2026-06-01
repo: halos-core-containers
pr: https://github.com/halos-org/halos-core-containers/pull/182
tags: [testing, bash, openssl, inode, filesystem, ext4, overlay, ci, flaky, gotcha, knowledge]
---

# Context

The CN-refresh gate in `halos-manage-certs` forces an auto-CA regeneration by
deleting `ca.crt`/`ca.key` and re-running `halos_ca_ensure_auto`. A test asserted
the regeneration happened by comparing the file's **inode** before and after:

```bash
ca_before=$(stat -c '%i' "$ca_crt")
# ... rename + rerun ...
[ "$(stat -c '%i' "$ca_crt")" != "$ca_before" ] || fail "CA must regenerate"
```

It passed on macOS and **failed in CI**.

# Root cause

The gate does `rm ca.crt` *before* recreating it. Linux `ext4` / overlayfs
**reuses the just-freed inode number** for the next file created in the same
directory — so the regenerated `ca.crt` got the *same* inode number (e.g.
`6059049` both times), and the inequality check reported "not regenerated"
even though the bytes were entirely new. macOS APFS does not reuse the number,
so the bug was invisible locally.

The neighbouring expiry-rotation test using the same inode technique passed in
CI by accident: that path lets `ensure_auto` `mv` the new file over the existing
one (no `rm` first), so the old inode is freed only *after* the new one is
allocated — no reuse.

# Fix

Detect regeneration by **content**, not identity. For certs, fingerprint:

```bash
_ca_fp() { openssl x509 -in "$1" -noout -fingerprint -sha256; }
```

A regenerated CA has a new keypair → new fingerprint, on every filesystem.

# Takeaway

Inode equality is **not** a reliable "same file / different file" signal across
a delete + recreate — Linux reuses inode numbers, and a macOS dev box will hide
it. When a test means "the content changed", assert on the content (hash, or a
field like the subject CN), not on `stat -c '%i'`. Reproduce filesystem-
sensitive test failures in a `debian:trixie` container, not just on macOS.
