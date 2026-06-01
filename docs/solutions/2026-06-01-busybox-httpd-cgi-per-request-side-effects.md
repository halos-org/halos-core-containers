---
title: "Use busybox httpd + CGI when a static-file sidecar must run a per-request side effect"
date: 2026-06-01
repo: halos-core-containers
pr: https://github.com/halos-org/halos-core-containers/pull/181
tags: [docker, busybox, httpd, cgi, nginx, sidecar, ca-download, pattern, gotcha, knowledge]
---

# Context

The `ca-download` sidecar serves the device CA and its `.mobileconfig`. The
device-identifying-CA feature (#176) needed it to record *first download* (to
freeze the CA's CN). Stock `nginx:1.27-alpine` cannot run a deliberate
per-request side effect — its only request-driven file write is `access_log`,
the implicit-logging anti-pattern. We swapped nginx → `busybox httpd` + CGI so
the cert/profile endpoints are shell scripts that emit the response and then
write an explicit adoption sentinel. (~50 MB image → ~4 MB, and it stays in the
repo's shell idiom.)

# Pattern

`httpd.conf` routes by suffix to a `/bin/sh` interpreter; the matched docroot
file is the CGI:

```
*.crt:/bin/sh
*.mobileconfig:/bin/sh
```

Run with `httpd -f -p 80 -u 65534:65534 -h /www -c /etc/httpd.conf`. A CGI emits
`Status: NNN`, headers, a blank line, then the body (plain `\n` line endings are
fine), and does its side effect last.

Verified on `busybox:1.37` (digest `9532d8c3…`): CGI custom `Status:` (302/410/
503) and arbitrary headers honored; `-u` drops to nobody after binding `:80`;
`/dir` → `/dir/` is a native 302 with a **relative** `Location` (safe behind
Traefik TLS — an absolute `http://` would downgrade the client).

# Traps that cost time

1. **CGI stdout is buffered by httpd.** A "flush body, then act" design does
   **not** protect against premature firing for any payload that fits one socket
   buffer (~64 KB): the body flushes in a single write that completes before any
   client disconnect is observable, so the side effect runs even if the client
   aborted mid-transfer. A broken-pipe SIGPIPE can abort the side effect only for
   payloads *larger* than the buffer (every real cert is smaller). Don't claim a
   "client confirmed receipt" guarantee for small responses; design the side
   effect to be safe under premature firing.

2. **Nested read-only bind mounts fail.** Mounting a file at `/www/ca/x` when
   `/www/ca` is itself a `:ro` bind mount errors with *"read-only file system"*
   (Docker can't create the mountpoint in the ro parent). busybox httpd has no
   `alias`/rewrite, so the docroot tree must mirror the URL space exactly —
   assemble **one** docroot directory and mount it once, rather than overlaying
   CGI files into a separately-mounted asset dir.

3. **`debian/rules` installs non-`.sh` files mode 0644.** CGIs named `*.crt` /
   `*.mobileconfig` ship non-executable — which works **only** because busybox
   runs them via the `/bin/sh` interpreter rule (the exec bit is not needed).
   Confirmed empirically; don't rely on the tracked +x bit surviving packaging.

4. **A single-file bind mount is inode-pinned at container start.** Every writer
   (the in-container CGI *and* the host cert-manager) must write the file **in
   place** (`printf > f`, truncate+rewrite), never tmp+mv — an inode swap
   desyncs the container's view. The mount source must exist as a regular file
   before `compose up`, or Docker creates a directory there.

# Takeaway

Reach for `busybox httpd` + CGI when a file-serving sidecar needs an explicit
per-request action. Keep the docroot a single self-contained tree, write
bind-mounted single files in place, and treat the side effect as fire-on-serve
(not fire-on-receipt) for sub-buffer payloads.
