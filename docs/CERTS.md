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
