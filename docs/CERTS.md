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
in `/etc/halos/ca/` aborts the unit — and therefore blocks
`halos-core-containers.service` start, because silently falling back to
the auto-CA would orphan trust anchors the operator distributed to a fleet.

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

The touch uses `touch -c` (no-create) so a vanishingly rare TOCTOU race
between the `[ -f ]` check and the touch never leaves an empty placeholder
that Traefik would fail to parse.

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

    https://<host>/halos-ca.crt

Plain HTTP requests to the same path are redirected to HTTPS (308). The
sidecar that serves the file returns it with:

| Header                | Value                                       |
|-----------------------|---------------------------------------------|
| `Content-Type`        | `application/x-x509-ca-cert`                |
| `Content-Disposition` | `attachment; filename="halos-ca.crt"`       |

`attachment` is the load-bearing piece: it causes browsers to open the
OS-level certificate install dialog instead of rendering the PEM as plain
text.

### Chicken-and-egg: trusting the CA before you trust the host

The first download necessarily happens before the CA is trusted. Two
acceptable paths:

1. Click through the browser's TLS warning ONCE, install the cert, restart
   the browser. Subsequent HTTPS for this device validates cleanly.
2. Fetch with `curl -k` (skip TLS check) and verify the SHA-256 fingerprint
   out-of-band over SSH before importing:

```sh
# On your workstation:
curl -k -o halos-ca.crt https://halos.local/halos-ca.crt
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
curl -sk https://halos.local/halos-ca.crt -o /tmp/halos-ca.crt
ssh halos.local 'sudo cat /var/lib/container-apps/halos-core-containers/data/halos-core-containers/certs/ca/serving-ca.crt' \
    | diff - /tmp/halos-ca.crt && echo OK

# 2. Headers are correct (Content-Type, Content-Disposition).
curl -skI https://halos.local/halos-ca.crt | grep -iE 'content-(type|disposition)'

# 3. HTTP redirects to HTTPS.
curl -sI http://halos.local/halos-ca.crt | head -1   # 308 Permanent Redirect
curl -sI http://halos.local/halos-ca.crt | grep -i ^location

# 4. After swapping the active CA (operator drops files in /etc/halos/ca/
#    and re-runs cert management), the URL serves the new bytes.
sudo systemctl start halos-manage-certs.service
sleep 5
curl -sk https://halos.local/halos-ca.crt -o /tmp/halos-ca-after.crt
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

**This is a single-device feature, not a fleet-provisioning pattern.** See
[Why this is not a fleet pattern](#why-this-is-not-a-fleet-pattern) below
before proceeding.

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
   and `/halos-ca.crt` now serves the custom CA's bytes.

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

### Why this is not a fleet pattern

The drop slot accepts `ca.key`, the CA's *private* key. If you copy the
same `ca.crt`+`ca.key` onto multiple devices to give your fleet a single
trust anchor, you have copied the private key onto every edge device. Any
one of them being compromised — physical theft, escalation through an
exposed service, a misconfigured `chmod` — burns the entire fleet's trust
anchor at once. From that point an attacker can mint a leaf for any
hostname the fleet recognises and use it to impersonate any device.

The supported pattern for fleet-wide trust is:

1. Each device generates its own auto-CA on first boot (default behaviour;
   do nothing).
2. Install each device's `ca.crt` on each operator workstation via the
   per-device download at `https://<host>/halos-ca.crt`. See the
   [user-guide page on docs.halos.fi](https://docs.halos.fi/user-guide/trust-the-device/).
3. You distribute *public* certs only; no private keys leave any device.

This scales linearly in trust-store entries on the workstation side, which
is the correct trade for not having the keys-to-the-kingdom on every edge
device.

For "we already have a corporate root CA" cases where the leaf actually
needs to chain to that root, the supported pattern is to run an
intermediate CA on a separately-managed signing host and drop the
*intermediate* `ca.crt`+`ca.key` onto a single device. Even then the
intermediate's key still lives on that device; the corporate root never
does.
