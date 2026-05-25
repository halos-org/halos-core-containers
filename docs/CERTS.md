# Certificates

Operator notes on TLS certificate handling in halos-core-containers.

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

Note: the next prestart run will re-create `99-halos.cert`. To make the revert
persistent, you would also need to remove the call site from prestart.sh — but
that defeats the purpose of the feature. The intended revert path is "remove
the override, restart cockpit, verify expected behavior" for diagnosis only.

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

Plain HTTP requests to the same path are redirected to HTTPS (301). The
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
`halos-core-containers.service` prestart copies the new cert to the public
location and the URL serves the new bytes. Already-installed copies on
operator workstations are NOT re-pushed — operators re-download and re-install
on each machine that needs to trust the new CA.

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
curl -sI http://halos.local/halos-ca.crt | head -1   # 301 Moved Permanently
curl -sI http://halos.local/halos-ca.crt | grep -i ^location

# 4. After swapping the active CA (operator drops files in /etc/halos/ca/
#    and restarts halos-core-containers.service), the URL serves the new bytes.
sudo systemctl restart halos-core-containers.service
sleep 5
curl -sk https://halos.local/halos-ca.crt -o /tmp/halos-ca-after.crt
diff /tmp/halos-ca.crt /tmp/halos-ca-after.crt   # expect a diff

# 5. Anything else under the same hostname is unaffected (homarr still wins
#    the catch-all path).
curl -skI https://halos.local/ | head -1
```
