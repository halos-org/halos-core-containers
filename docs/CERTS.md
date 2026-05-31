# Certificates

Operator notes on TLS certificate handling in halos-core-containers.

## Where cert lifecycle lives

All CA selection, leaf signing, public-CA publish, and Cockpit cert sharing
runs in **`halos-manage-certs.service`** — a oneshot systemd unit ordered
`Before=halos-core-containers.service`. The script (installed at
`/usr/lib/halos-core-containers/halos-manage-certs`) is idempotent and runs:

1. At every `halos-core-containers.service` activation (`Requires=` + `After=`,
   so the container stack will not start if cert provisioning fails).
2. Periodically via **`halos-manage-certs.timer`** — 15 min after boot, then
   every 24 h thereafter with a 1 h randomized delay. This catches Apple's
   825-day leaf-validity ceiling on devices that run uninterrupted for
   years without a service restart.

`prestart.sh` no longer touches certs. To inspect or force a cert refresh:

```
systemctl list-timers halos-manage-certs.timer        # when the next fire is due
systemctl status halos-manage-certs.service           # last-run result
journalctl -u halos-manage-certs.service -f           # follow logs
sudo systemctl start halos-manage-certs.service       # force a refresh
```

Auxiliary failures (public-CA publish, Cockpit override install) log
`WARNING` and do not block the unit. A broken operator-supplied custom CA
in `/etc/halos/ca/` aborts the unit and therefore blocks
`halos-core-containers.service` start.

### Cockpit auto-reload on leaf change

When a timer-driven run actually rotates the leaf AND the cockpit override
was successfully reinstalled, `halos-manage-certs` calls
`systemctl reload-or-restart cockpit.socket` so `:9090` picks up the fresh
leaf immediately instead of waiting for the next natural socket activation.
The reload is gated on (a) `NEED_LEAF=true` so no-op timer fires don't
bounce `:9090`, and (b) the override-install actually succeeding so a
failed install doesn't trigger a pointless reload.

### Traefik reload on leaf change

After re-signing the leaf, `halos-manage-certs` touches
`/etc/halos/traefik-dynamic.d/tls-default.yml` (the file `prestart.sh`
generates with `defaultCertificate.certFile` / `keyFile` pointing at the
leaf paths). Traefik's file-provider watcher fires on the mtime change
and re-reads its dynamic config; re-reading the dynamic config causes
the referenced cert files to be loaded from disk. No container restart,
no connection drop on `:443`.

The reload is gated on (a) `NEED_LEAF=true` so a no-op timer fire
doesn't churn Traefik every 24 h, and (b) the dynamic-config file
already existing (first-boot ordering: `halos-manage-certs.service` runs
`Before=` `halos-core-containers.service`, so the file is absent on
initial provisioning and Traefik is not yet running — it picks up the
freshly-signed leaf on its first start instead).

### Disabling the timer

The 24-hour renewal check is safe to skip during a maintenance window or
debugging session — the cert manager still runs at every container-stack
activation via the `Requires=` chain from `halos-core-containers.service`,
so a device that reboots more than once every 60 days renews regardless.

```
sudo systemctl stop halos-manage-certs.timer       # stop until next boot
sudo systemctl disable halos-manage-certs.timer    # also disable across boots
sudo systemctl mask halos-manage-certs.timer       # belt-and-suspenders: forbid manual start
```

(`mask` is reverted with `systemctl unmask`, then `enable` + `start` if
you want the timer back on the same boot.)

## Cockpit :9090 cert sharing

Cockpit's `:9090` listener serves the same TLS leaf as Traefik, so operators see
one trust experience across both surfaces — and so the operator-installed CA
covers `:9090` too.

### Where it lives

- Combined PEM (leaf cert + leaf key) at `/etc/cockpit/ws-certs.d/99-halos.cert`,
  mode `0640`, group `cockpit-ws` (when that group exists on the host).
- The source files are unchanged at `/var/lib/container-apps/halos-core-containers/data/traefik/certs/halos.{crt,key}`.

### Why the `99-` prefix

`cockpit-tls` picks the lexicographically-last `.cert` file in
`/etc/cockpit/ws-certs.d/` at socket activation. The `99-` prefix guarantees
the HaLOS override wins over the upstream `0-self-signed.cert` that
`cockpit-certificate-ensure` generates on first boot.

The upstream cert stays in place as the safety-net floor. If `99-halos.cert`
is ever absent (manual removal, install-order race), Cockpit falls back to the
upstream-generated self-signed cert and `:9090` stays reachable.

### How to revert to upstream-generated self-signed

```
sudo rm /etc/cockpit/ws-certs.d/99-halos.cert
sudo systemctl restart cockpit
```

Note: the next `halos-manage-certs.service` activation (next reboot, next
`systemctl start halos-manage-certs`, or next timer fire) will re-create
`99-halos.cert`. To make the revert persistent you would need to disable the
service or remove the call site from `halos-manage-certs` — but that defeats
the purpose of the feature. The intended revert path is "remove the
override, restart cockpit, verify expected behavior" for diagnosis only.

### Picking up a new cert

`cockpit-tls` reads certs at socket activation. To apply a freshly-written
`99-halos.cert` immediately:

```
sudo systemctl restart cockpit
```

Without an explicit restart, the new cert is picked up the next time
`cockpit.socket` activates. Existing connected sessions keep the old cert
until disconnect.

### Two key copies on disk

The leaf private key now exists in two places:

- Source: `/var/lib/container-apps/halos-core-containers/data/traefik/certs/halos.key`
  (mode `0600`, owned by root)
- Combined PEM copy: `/etc/cockpit/ws-certs.d/99-halos.cert` (mode `0640`,
  group `cockpit-ws`)

Both files are on the same filesystem and both have group-or-stricter
read-only permissions. The marginal exposure (cockpit-ws group read on the
second copy) is acceptable: the group exists specifically so cockpit-tls can
read its private key.

## CA download endpoint

The active CA is published at:

    https://<host>/ca/halos-ca.crt

(Moved 2026-05-28 from the bare `/halos-ca.crt`, which now returns `410 Gone`
with a `Link: </ca/halos-ca.crt>; rel="canonical"` hint. The `/ca/` prefix is
shared with the trust-install landing page at `https://<host>/ca/`.)

Plain HTTP requests to the same path are redirected to HTTPS (308). The
sidecar that serves the file returns it with:

| Header                | Value                                       |
|-----------------------|---------------------------------------------|
| `Content-Type`        | `application/x-x509-ca-cert`                |
| `Content-Disposition` | `attachment; filename="halos-ca.crt"`       |

`attachment` is the load-bearing piece: it causes browsers to open the
OS-level certificate install dialog instead of rendering the PEM as plain
text.

### Trust-install landing page

`https://<host>/ca/` serves a self-contained walkthrough
(`assets/ca-download/landing/index.html`) that guides the operator through
installing the `.crt` per platform: macOS, iOS/iPadOS, Android, Linux, and
Windows. Client-side User-Agent detection auto-expands the section matching
the visitor's OS; with JavaScript off, the sections stay collapsed but remain
accessible — clicking any heading expands it. The page
states up front that installing the certificate and trusting it are separate
steps on every platform — Apple's *Certificate Trust Settings* toggle,
macOS *Always Trust*, Android's browser-only trust, and the Firefox NSS
store all need an explicit trust action beyond the install.

The page's generic download button points at `/ca/halos-ca.crt`. The iOS/iPadOS
section leads with the Apple configuration profile below; macOS, Android, Linux,
and Windows use the raw `.crt`. The Debian/Ubuntu `.deb` carrier is tracked
separately and will slot into the Linux section as it lands.

**Why the profile is iOS-only, not macOS.** On macOS (Ventura and later) a root
delivered by a manually-installed configuration profile is *not* trusted for SSL
automatically, the cert does not appear in Keychain Access, and macOS has no
iOS-style *Certificate Trust Settings* toggle — so there is no way to grant the
profile-delivered root SSL trust. The raw `.crt` installed into the System
keychain, where the operator sets *Always Trust*, is the only working macOS path.
iOS is different: it exposes *Settings → General → About → Certificate Trust
Settings*, and the profile avoids the Files-app routing that breaks the raw-`.crt`
download there (see issue #169). References:
[Apple Developer Forums 724327](https://developer.apple.com/forums/thread/724327).

### Apple configuration profile (`.mobileconfig`)

`halos-manage-certs` generates `halos-ca.mobileconfig` next to `halos-ca.crt`
on every run (helper `halos_ca_publish_mobileconfig` in `lib-ca.sh`, aux-failure
semantics — a generation failure logs WARN and never blocks cert management).
The sidecar serves it at:

    https://<host>/ca/halos-ca.mobileconfig

| Header         | Value                              |
|----------------|------------------------------------|
| `Content-Type` | `application/x-apple-aspen-config` |

Unlike the `.crt`, the profile is served **without** `Content-Disposition:
attachment`. On iOS Safari `attachment` routes the file to the Files app and
the profile installer never fires (#169); serving the aspen MIME inline makes
Safari show the *Profile Downloaded* install prompt. The landing-page link is a
plain anchor with no `download` attribute for the same reason.

The profile carries a single `com.apple.security.root` payload with the active
CA's DER bytes, named `HaLOS Device CA (<hostname>)` so devices are
distinguishable in a fleet's Profiles list. It is **unsigned** (signing needs an
Apple Developer ID we don't own) — installs fine with a cosmetic "Not Verified"
notice. Profile identifiers and UUIDs are fixed constants, so a CA rotation
replaces the existing profile instead of stacking a duplicate.

Install is **not** trust: macOS Sequoia / iOS 17-18 still require a separate
trust action after install (Keychain Access "Always Trust" on macOS, *Settings →
General → About → Certificate Trust Settings* on iOS). The landing page is
explicit about this.

A dashboard tile (`assets/ca-download-tile.toml`, installed to
`/etc/halos/webapps.d/ca-download.toml`) surfaces this page on the Homarr
board via `homarr-container-adapter`. It is an external link (no health
check) and always visible.

### Chicken-and-egg: trusting the CA before you trust the host

The first download necessarily happens before the CA is trusted. Two
acceptable paths:

1. Click through the browser's TLS warning ONCE, install the cert, restart
   the browser. Subsequent HTTPS for this device validates cleanly.
2. Fetch with `curl -k` (skip TLS check) and verify the SHA-256 fingerprint
   out-of-band over SSH before importing:

```sh
# On your workstation:
curl -k -o halos-ca.crt https://halos.local/ca/halos-ca.crt
openssl x509 -in halos-ca.crt -noout -fingerprint -sha256

# Over SSH to the device:
ssh halos.local 'sudo openssl x509 \
    -in /var/lib/container-apps/halos-core-containers/data/halos-core-containers/certs/ca/serving-ca.crt \
    -noout -fingerprint -sha256'
```

Fingerprints must match exactly. **Every `-sk` command below assumes you
have already verified the fingerprint by this procedure — without that
verification, all `-sk` results are meaningless on an untrusted network.**

### After swapping in a custom CA

When an operator drops a custom CA at `/etc/halos/ca/ca.{crt,key}`, the next
`halos-manage-certs.service` activation copies the new cert to the public
location and the URL serves the new bytes. Triggers: next reboot, next
`systemctl start halos-manage-certs`, or next timer fire (#140).
Already-installed copies on operator workstations are NOT re-pushed —
operators re-download and re-install on each machine that needs to trust
the new CA.

### Test commands

A fresh device should pass all of these (run from a workstation that can
reach `https://halos.local`, AFTER verifying the fingerprint per the
chicken-and-egg procedure above):

```sh
# 1. The CA is served and matches the on-device serving-ca.crt.
curl -sk https://halos.local/ca/halos-ca.crt -o /tmp/halos-ca.crt
ssh halos.local 'sudo cat /var/lib/container-apps/halos-core-containers/data/halos-core-containers/certs/ca/serving-ca.crt' \
    | diff - /tmp/halos-ca.crt && echo OK

# 2. Headers are correct (Content-Type, Content-Disposition).
curl -skI https://halos.local/ca/halos-ca.crt | grep -iE 'content-(type|disposition)'

# 3. HTTP redirects to HTTPS.
curl -sI http://halos.local/ca/halos-ca.crt | head -1   # 308 Permanent Redirect
curl -sI http://halos.local/ca/halos-ca.crt | grep -i ^location

# 4. After swapping the active CA (operator drops files in /etc/halos/ca/
#    and re-runs cert management), the URL serves the new bytes.
sudo systemctl start halos-manage-certs.service
sleep 5
curl -sk https://halos.local/ca/halos-ca.crt -o /tmp/halos-ca-after.crt
diff /tmp/halos-ca.crt /tmp/halos-ca-after.crt   # expect a diff

# 5. Anything else under the same hostname is unaffected (homarr still wins
#    the catch-all path).
curl -skI https://halos.local/ | head -1
```

## Installing a custom CA

Advanced operators who already maintain an internal CA can have HaLOS sign
its leaf from that CA instead of the device's auto-generated one. The leaf
will then chain to a trust anchor the operator already has installed on
their workstations.

### Drop slot

| Path | Mode | Notes |
|---|---|---|
| `/etc/halos/ca/ca.crt` | `0644` | CA certificate, PEM. Must have `CA:TRUE` in `basicConstraints` and `keyCertSign` in `keyUsage`. |
| `/etc/halos/ca/ca.key` | `0600`, owned by `root` | CA private key, PEM. Must match the public key inside `ca.crt`. |

Both files must be present. The drop slot is checked on every
`halos-manage-certs.service` run.

### Steps to install

1. Place both files at the paths above with the correct permissions.
2. Run `sudo systemctl start halos-manage-certs.service`.
3. Inspect the journal for the loud failure cases below; on success, the
   active CA mode switches from `auto` to `custom`, the leaf is re-signed,
   and `/ca/halos-ca.crt` now serves the custom CA's bytes.

```
sudo systemctl start halos-manage-certs.service
journalctl -u halos-manage-certs.service -b -n 30
```

### Validation behaviour

The validator checks `CA:TRUE`, `keyCertSign`, key-matches-cert, and date
parsing. If any check fails, the service exits non-zero (visible via
`systemctl status` and `dpkg -l`) and leaves the previous active CA
unchanged — fix the dropped files and re-run.

Common failure modes:

- `CA:TRUE` missing — most "self-signed cert" tutorials produce non-CA
  certificates. The CA you drop here must be a real CA, not a leaf.
- `ca.key` doesn't match `ca.crt` — copy-paste error, wrong file.
- `ca.crt` already expired or `notBefore` in the future — RTC drift on
  first boot, or you grabbed an old cert.

### Reverting to the auto-CA

Remove the drop-slot files and re-run the service:

```
sudo rm /etc/halos/ca/ca.crt /etc/halos/ca/ca.key
sudo systemctl start halos-manage-certs.service
```

The auto-CA at `/var/lib/container-apps/halos-core-containers/data/halos-core-containers/certs/ca/ca.crt`
is preserved across mode switches; reverting just re-points
`serving-ca.crt` back at it and re-signs the leaf with the auto-CA.

## Same-origin asset serving on :443 (cert-exception friction)

Until a device's CA is installed, every TLS surface the user touches needs a
manual cert exception. Browsers key those exceptions by **`(host, port)`**
(Chromium also folds in the leaf fingerprint; Safari is per-`(host, port)`
even against the prior self-signed default). So each distinct port a user is
sent to costs one more click-through, and multi-hostname access
(`<host>.local` *and* the DHCP-domain FQDN) multiplies the count again.

This bites the Homarr dashboard. Each Signal K plugin card renders an icon
via a path-only URL such as
`/signalk-server/@signalk/app-dock/app-icon.svg`. By default that path
matches the auto-generated `redirect-signalk-server-https@file` router
(priority 100, `PathPrefix(/signalk-server/)`) and gets 307-redirected to
`https://<host>:4430/...` — the per-app port. Crossing from `:443` to
`:4430` is a new `(host, port)` pair, so the dashboard renders with broken
icons until the user manually visits `:4430` and clicks through the warning,
once per app port they ever encounter.

**Fix:** static images are not navigation and don't need origin isolation
from the dashboard. `assets/traefik/dynamic/signalk-server-icons.yml`
defines a higher-priority (200) router that catches image extensions under
`/signalk-server/`, strips the prefix, and proxies them to the Signal K
backend on `:443` directly. Served same-origin with the dashboard, they're
covered by the cert exception the user already granted for the dashboard —
no extra click-through.

**Why only images.** The scope is deliberately narrow (svg, png, ico, jpg,
jpeg, gif, avif, webp, case-insensitive). HTML, JS, and CSS are excluded: a
Signal K plugin SPA loaded under a `/signalk-server/...` prefix on the
dashboard origin would silently break, because webapps assume `/` as their
root and embed absolute paths. Navigation to a plugin therefore stays on the
existing redirect-to-`:4430` path so each plugin keeps a clean `/`-rooted
origin — accepting the one cert exception per app port for *navigation*
while eliminating it for *icons*. (The proper long-term fix is to install
the device CA; see the CA download endpoint above. This router only removes
the friction for the icon case in the meantime.)

The router also wires `strip-hsts@file` so it does not re-introduce the HSTS
leak the per-app routers were patched to strip.
