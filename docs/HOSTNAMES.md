# Hostname configuration

`/etc/halos/hostnames.conf` is the admin-managed list of every hostname this
device answers to. The list drives:

- TLS certificate Subject Alternative Names (SANs)
- Authelia session-cookie `Domain` attributes (one per multi-label entry)
- OIDC `redirect_uris` advertised to identity-provider clients
- Traefik path-only routing (the canonical entry is also the OIDC issuer)

After editing the file, restart the service:

```bash
sudo systemctl restart halos-core-containers.service
```

## Supported tokens

Three tokens are expanded at every prestart:

| Token | Source | Example |
|---|---|---|
| `${hostname}` | `hostname -s` | `halosdev` |
| `${domain}` | resolver chain (below) | `example.com` |
| `${fqdn}` | shorthand for `${hostname}.${domain}` | `halosdev.example.com` |

`${fqdn}` substitutes directly to the resolved string — it is not
recursively expanded from the literal `${hostname}.${domain}`.

## Domain resolver chain

Resolution order, first non-empty wins:

1. **`hostname -d`** — admin-set domain via `/etc/hosts` or
   `hostnamectl set-hostname`. Wins because explicit configuration beats
   auto-discovery.
2. **`nmcli -t -f IP4.DOMAIN device show`** — DHCP-provided domain
   (DHCP option 15). Wrapped in `timeout 2` so a hung NetworkManager
   cannot block prestart. Skipped if `nmcli` is not installed.

(There is also a `$HALOS_DOMAIN_RESOLVER` test injection seam, gated on
`declare -F` so a stray environment export cannot short-circuit
production resolution.)

If no domain resolves, lines using `${fqdn}` or `${domain}` are silently
skipped (logged as `HALOS_HOSTNAMES_SKIP`); other entries continue to
apply. Boot proceeds normally — the device just doesn't answer on its
DHCP-derived FQDN until the domain is set or DHCP lease changes are
followed by a service restart.

## Single-label hostnames — don't use them

The loader accepts single-label hostnames (e.g., bare `halosdev`)
because they are valid DNS labels and may be resolvable on routers
that integrate DHCP with LAN DNS. **However, single-label hostnames
break SSO in non-obvious ways and the shipped default deliberately
does not include them.**

The problem: RFC 6265 §5.3 step 5 instructs browsers to ignore Set-Cookie
headers whose `Domain` attribute is a single label, and Authelia 4.39+
refuses to start with a single-label `Domain` in its config. Where
single-label entries are honored anywhere in the stack:

- ✅ TLS cert SANs (openssl accepts single labels)
- ✅ OIDC `redirect_uris` (Authelia accepts them)
- ✅ Traefik path-only routing (the request reaches the device)
- ❌ Authelia session cookies (Authelia would crash; the `prestart.sh`
  cookie loop therefore filters single-label entries out)

The result for a user who reaches the device at `https://halosdev/`:
the page loads, login redirects through Authelia, but no session
cookie is ever scoped to `halosdev`, so subsequent requests are not
authenticated. Login appears broken in confusing ways — there is no
visible error.

**Use the FQDN form (`halosdev.<domain>`) instead.** On routers that
register DHCP clients into LAN DNS, both `halosdev` and `halosdev.<lan-domain>`
typically resolve, and the FQDN form works end-to-end. `${fqdn}` in
the shipped default covers this automatically when DHCP option 15 is
set or when an admin runs `hostnamectl set-hostname halosdev.<domain>`.

## Diagnostics

Two stable journalctl signatures, deliberately distinct so they can be
grepped apart:

| Signature | Meaning | Action |
|---|---|---|
| `HALOS_HOSTNAMES_SKIP: <reason>: <line>` | Soft-drop. A `${fqdn}`/`${domain}` line couldn't expand because no domain resolved. Other entries still apply. | Usually informational. If unexpected, check `nmcli -t -f IP4.DOMAIN device show` and `hostname -d`. |
| `HALOS_HOSTNAMES_FALLBACK: <reason>` | Hard fail. The whole file is invalid (typo, dangerous chars, cap exceeded, unreadable). Device boots in single-SAN default mode. | Fix the named line in `hostnames.conf` and restart the service. |

## DHCP trust boundary

When `${fqdn}`/`${domain}` falls through to `nmcli`, the resolved value
comes from DHCP option 15. On a hostile LAN, that value flows into:

- TLS cert SANs (self-signed; minor)
- Authelia session-cookie `Domain` attribute (significant — controls
  cookie scope)
- OIDC `redirect_uris` advertised by the device's identity provider
  (significant — the OAuth callback allow-list)

This is a deliberate trust extension. The alternative was forcing
admins to type literal hostnames, which the design explicitly rejects
in favor of zero-config FQDN access on the device's home network.
Defenses in place:

1. `hostname -d` wins over DHCP, so admins can pin the domain
   authoritatively by running `sudo hostnamectl set-hostname halosdev.example.com`.
2. `_halos_domain_safe` rejects resolved values containing whitespace,
   NUL, shell metacharacters, or anything outside the DNS label set.
3. The regex still rejects malformed DNS strings.

**Devices intended for hostile or untrusted networks should either:**
- Remove the `${fqdn}` line from `/etc/halos/hostnames.conf`, or
- Pin the domain via `hostnamectl set-hostname <fqdn>`.

## Validation queries

After deployment, three queries verify the hostname list is being
consumed correctly:

```bash
# Cert SANs — should match the expected expansion of hostnames.conf
sudo openssl x509 \
  -in /var/lib/container-apps/halos-core-containers/data/traefik/certs/halos.crt \
  -noout -ext subjectAltName

# Authelia cookies — one entry per multi-label DNS hostname
sudo grep -A1 'cookies:' \
  /var/lib/container-apps/halos-core-containers/data/authelia/configuration.yml

# OIDC redirect_uris — N entries per client where N = DNS hostname count
sudo grep redirect_uris -A4 \
  /var/lib/container-apps/halos-core-containers/data/authelia/oidc-clients.yml
```

## See also

- [SSO_SPEC.md](SSO_SPEC.md) — Authelia / OIDC architecture
- [SSO_ARCHITECTURE.md](SSO_ARCHITECTURE.md) — request-flow diagrams
- `/etc/halos/hostnames.conf` — the file itself; its header comments
  carry the same token quick-reference.
