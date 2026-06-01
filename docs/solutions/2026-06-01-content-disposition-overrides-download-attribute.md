---
title: "A server Content-Disposition filename overrides the HTML download attribute"
date: 2026-06-01
repo: halos-core-containers
pr: https://github.com/halos-org/halos-core-containers/pull/186
tags: [http, content-disposition, download-attribute, browser, ca-download, frontend, verification, gotcha, knowledge]
---

# Context

The device-identifying CA work (#179) tried to give each device a distinct
download filename `halos-ca-<hostname>.crt` purely client-side: the `/ca` landing
page is served from the device, so its JS read `window.location.hostname` and set
the cert link's HTML `download` attribute to the per-device name.

It never worked. On the device, clicking download always saved `halos-ca.crt`.

# Root cause

The cert endpoint responds with a `Content-Disposition: attachment;
filename="halos-ca.crt"` header. For a same-origin download, a server-supplied
`Content-Disposition` filename **takes precedence over the HTML `download`
attribute** — the attribute is only a fallback used when the server does not
specify a name (MDN documents this explicitly). So the page's client-side name
could never win against the static server header.

The plan's assumption ("the page knows the hostname client-side, so no
server-side injection is needed") was simply wrong for any endpoint that already
sends a `Content-Disposition` filename.

# Fix

Set the device-specific filename **server-side**, from the cert's **subject CN**
— its actual identity (the name the trust store shows), not how the page was
reached (a first cut used the request `Host` header, but that names the file
after the access path, not the cert: a bare-CN or renamed-then-adopted cert
would get a wrong/ambiguous name). Because the busybox sidecar has no `openssl`,
the cert-manager computes the name and writes it to a file in the published dir;
the CGI reads it for `Content-Disposition` (validating it to a safe shape). The
landing page's JS keeps only display concerns and learns the name
**authoritatively** via a `HEAD` of the cert endpoint — so the instruction text
always shows the exact file the user saves, with no client-side re-derivation to
drift out of sync.

# How it slipped through — the verification lesson

The original change was "verified" in a browser by reading the anchor's
`download` **attribute value** (`getAttribute('download')`) — which was correctly
set to the per-device name. But the attribute value is an intermediate DOM proxy,
not the effect. The thing that matters — the **saved filename** — is decided by
the server header, which the attribute check never exercised.

Verify the user-visible effect, not a proxy for it. For a download, that means
the actual `Content-Disposition` the server sends (or the real saved file), not
the `download` attribute. The fix's own check compares the page's displayed
filename against a live `HEAD` of the cert endpoint's `Content-Disposition`, and
asserts they are equal.
