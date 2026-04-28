---
title: "Authelia 4.39+ rejects single-label cookie Domain attributes (RFC 6265 §5.3 step 5)"
date: 2026-04-28
repo: halos-core-containers
pr: https://github.com/halos-org/halos-core-containers/pull/123
tags: [authelia, sso, cookies, rfc-6265, hostnames, multi-host, integration-issue]
---

# Problem

Authelia container crash-loops at startup with a config-validation error after `/etc/halos/hostnames.conf` was extended to register additional hostnames the device should answer to. The failing log line:

```
Configuration: session: domain config #2 (domain 'halosdev'): option 'domain'
is not a valid cookie domain: must have at least a single period or be an ip address
```

Symptom path: prestart succeeds, systemd reports `halos-core-containers.service` as `active`, but the Authelia container restarts indefinitely. Failure surfaces only in `docker logs authelia`, not in the systemd unit's stderr — easy to misread as a transient health-check race.

# Root Cause

RFC 6265 §5.3 step 5 instructs user agents to **ignore** any `Set-Cookie` whose `Domain` attribute is a single label (e.g., `Domain=halosdev`). Authelia 4.39+ enforces this at config-load time rather than letting browsers silently drop the cookies later. The same rule extends to IP-literal domains (already known and filtered in PR #122).

Why this is worse than a startup error: even if Authelia accepted the config, the browser would discard the cookie. The user experience would be:

1. Navigate to `https://halosdev/`
2. Get redirected through Authelia
3. Authelia issues a `Set-Cookie` with `Domain=halosdev`
4. Browser drops it per RFC 6265
5. Subsequent request has no session cookie → redirect-loop or re-prompt

There's no visible error — login appears broken in confusing ways.

# What Didn't Work

**Assuming the loader's syntactic validation was sufficient.** `lib-hostnames.sh` accepts single-label hostnames by design (the relaxed DNS regex covers SOHO routers like UniFi, OpenWrt, pfSense, Fritz!Box that integrate DHCP with LAN DNS so a bare `halosdev` is resolvable). The unit test suite all passed; the bug surfaced only at the consumer layer.

**Shipping bare `${hostname}` in the default conffile.** The original PR #123 plan called for `${hostname}.local` + `${hostname}` + `${fqdn}` as three active default lines. Real-device verification on `halosdev.local` was the first step that exercised the full loader → prestart → Authelia chain.

# Solution

Four-part fix. Each is necessary; missing any one re-introduces the failure.

**1. Don't ship single-label hostnames as defaults.** `assets/hostnames.conf` ships `${hostname}.local` + `${fqdn}` only. Single-label remains an admin opt-in.

**2. Filter single-label entries from the Authelia cookie loop in `prestart.sh`** (mirrors the existing IP exclusion):

```bash
while IFS= read -r host; do
    [ -z "$host" ] && continue
    # Skip single-label hostnames — Authelia rejects them as cookie domains.
    case "$host" in
        *.*) ;;
        *) continue ;;
    esac
    cookies_block+="    - domain: '${host}'"$'\n'
    cookies_block+="      authelia_url: 'https://${host}/sso'"$'\n'
    cookies_block+="      default_redirection_url: 'https://${host}'"$'\n'
done < <(halos_dns_hostnames)
```

**3. Synthesize a fallback cookie entry when the filter empties the block.** Without this, an admin who pins only single-label entries produces an empty `cookies:` YAML block, and Authelia rejects with a different (less obvious) error:

```bash
cookies_block="${cookies_block%$'\n'}"
if [ -z "$cookies_block" ]; then
    local _fallback_canonical
    _fallback_canonical="$(_halos_short_hostname).local"
    echo "WARN: hostnames.conf produced no multi-label DNS entries for Authelia cookies; falling back to ${_fallback_canonical}" >&2
    cookies_block+="    - domain: '${_fallback_canonical}'"$'\n'
    cookies_block+="      authelia_url: 'https://${_fallback_canonical}/sso'"$'\n'
    cookies_block+="      default_redirection_url: 'https://${_fallback_canonical}'"
fi
```

**4. Deduplicate the DNS list** (case-insensitive). On a SOHO LAN where DHCP option 15 = `local`, `${fqdn}` expands to `<short>.local`, exactly colliding with `${hostname}.local`. Authelia 4.39+ rejects duplicate cookie-domain entries the same way it rejects single-label ones. Dedup happens in `halos_load_hostnames` after parsing, preserving first occurrence.

# Why This Works

Each defense covers a class of input the others miss:

| Defense | Catches |
|---|---|
| Default conffile is multi-label only | Fresh installs |
| Single-label filter in cookie loop | Admin opt-in single-label entries |
| Empty-cookies fallback | Pathological all-single-label admin configs |
| Dedup | Token-expansion collisions with admin-typed literals |

Single-label entries remain valid as **cert SANs** (openssl accepts them), **OIDC `redirect_uris`** (Authelia accepts them there), and **Traefik path-only routing targets** — they only fail as cookie `Domain` attributes. The fix preserves the bare-hostname access path for all the cases where it works; only the SSO session-cookie scope is excluded.

# Prevention

- **Verify on a real device before shipping new hostname-aware features.** Unit tests exercising the loader cannot catch consumer-layer config-validation errors that fire only when the rendered Authelia/Traefik config is fed to the running daemon. Add a build-time `authelia validate-config` step if/when the container CLI exposes one.
- **Mirror the same defenses for any future cookie-domain-consuming feature** (e.g., a separate identity provider, a future Cockpit auth integration). The pattern is: filter single-label + filter IPs + dedup + fallback.
- **Document the foot-gun for admins.** `docs/HOSTNAMES.md` §"Single-label hostnames — don't use them" calls this out explicitly so admins reading the conffile know why bare-hostname entries break SSO without warning.

# Related

- PR halos-org/halos-core-containers#123 — feat: `${fqdn}` and `${domain}` template tokens
- PR halos-org/halos-core-containers#122 — multi-hostname Traefik support (added the original IP exclusion this fix mirrors)
- RFC 6265 §5.3 step 5 — cookie Domain attribute validation
- Authelia 4.39 session schema — `must have at least a single period or be an ip address`
