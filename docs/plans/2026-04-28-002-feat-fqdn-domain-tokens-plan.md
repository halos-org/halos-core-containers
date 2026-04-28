---
title: "feat: ${fqdn} and ${domain} template tokens in hostnames.conf"
type: feat
status: active
date: 2026-04-28
---

# feat: ${fqdn} and ${domain} template tokens in hostnames.conf

## Overview

Extend `lib-hostnames.sh` token expansion to support two new tokens in `/etc/halos/hostnames.conf`:

- `${domain}` — the device's DNS domain, resolved at prestart time.
- `${fqdn}` — shorthand for `${hostname}.${domain}`.

Resolution chain for the domain (first non-empty wins):
1. `hostname -d` — admin-set domain via `/etc/hosts` or `hostnamectl`.
2. `nmcli -t -f IP4.DOMAIN device show <dev>` iterating connected devices, first non-empty value wins.

If no domain resolves, `${fqdn}`/`${domain}` lines fail the existing DNS regex and fall through the existing fail-closed path with a `HALOS_HOSTNAMES_FALLBACK` diagnostic. `${hostname}` continues to work unchanged.

Target repo: **halos-core-containers** (under the workspace at `halos-core-containers/`).

## Problem Frame

PR #122 (merged) added admin-managed multi-hostname support with `${hostname}` expansion. On `halosdev.local`, DHCP provides `domain_name = hal` (visible via `nmcli`), but `hostname -f` returns the short name because NetworkManager doesn't push the DHCP domain into `/etc/hosts` or resolv.conf. Admins currently have to type the resolved FQDN literally into `hostnames.conf`. Tokenizing the domain lets the shipped default and admin examples track DHCP-provided values automatically while keeping the existing fail-closed validation contract.

## Requirements Trace

- R1. New `${domain}` token expands to the resolved domain string in any `hostnames.conf` line.
- R2. New `${fqdn}` token expands to `${hostname}.${domain}` in any `hostnames.conf` line.
- R3. Domain resolution prefers `hostname -d`, falls back to `nmcli` across connected devices.
- R4. Empty/unresolvable domain → entries containing `${fqdn}` or `${domain}` are rejected by existing DNS regex; existing `HALOS_HOSTNAMES_FALLBACK` diagnostic path triggers.
- R5. Resolver implementation must not hang prestart — short timeout or `command -v nmcli` guard.
- R6. Resolver is injectable for unit tests so the build host's network state is not a dependency.
- R7. Default shipped `hostnames.conf` includes `${hostname}.local` (canonical) and `${fqdn}` (DHCP/admin domain). Lines that don't resolve to valid hostnames are silently soft-dropped.
  - **Refinement during implementation (2026-04-28):** the original plan called for a third entry, bare `${hostname}` (single label), to cover routers that integrate DHCP with LAN DNS. Real-device verification on halosdev.local revealed that Authelia 4.39+ refuses to load a config with a single-label cookie `Domain=` attribute (matching RFC 6265 §5.3 step 5, where browsers ignore single-label Domain attributes). Shipping bare `${hostname}` in the default would leave SSO broken in non-obvious ways for users reaching the device by short name. Bare `${hostname}` remains valid as an admin opt-in (the loader still accepts single labels) and `prestart.sh` filters single-label entries out of the Authelia cookies block as defense-in-depth. See `docs/HOSTNAMES.md` §"Single-label hostnames — don't use them" for the full rationale.
- R8. DNS validation regex relaxed to accept single-label hostnames (e.g., bare `halosdev`) so that `${hostname}` and bare `${domain}` (single-label DHCP domains) are accepted. Two-label-or-more entries continue to validate as before.
- R9. AGENTS.md "Hostname-list contract" section reflects the new tokens and the relaxed regex.
- R10. Version bump and `debian/changelog` entry via `./run bumpversion`.

## Scope Boundaries

- **Out of scope**: any new resolver beyond `hostname -d` and `nmcli` (no `resolvectl`, no parsing `/etc/resolv.conf` directly, no DBus calls).
- **Out of scope**: runtime re-resolution on lease changes — boot/service-restart resolution only (per user confirmation).
- **Out of scope**: any change to the shipped default beyond appending a `${fqdn}` line — `${hostname}.local` stays as the first/canonical entry.
- **Out of scope**: any change to `prestart.sh`, the cert generator, the OIDC merger, or Authelia template processor — all of those consume the loader's already-expanded `HALOS_HOSTNAMES_DNS[]` array, so token expansion happening earlier in the loader is transparent to them.
- **Out of scope**: token expansion inside OIDC client snippets (the `${HALOS_DOMAIN}` placeholder there is unrelated and stays as-is).

## Context & Research

### Relevant Code and Patterns

- `halos-core-containers/assets/lib-hostnames.sh` — `_halos_expand_line` is the single substitution seam; today it handles only `${hostname}`. Add the new tokens here.
- `halos-core-containers/assets/lib-hostnames.sh` — `_halos_short_hostname` is the existing "side-effect-free helper" pattern; mirror it with a `_halos_resolve_domain` helper.
- `halos-core-containers/debian/halos-core-containers/usr/lib/halos-core-containers/lib-hostnames.sh` — packaged copy of the same file. Debian packaging duplicates `assets/` content into `debian/halos-core-containers/...`; both must be updated.
- `halos-core-containers/assets/hostnames.conf` and its packaged twin under `debian/halos-core-containers/etc/halos/` — same duplication pattern.
- `halos-core-containers/tests/test-lib-hostnames.sh` — existing bash test harness with `_reset_state` per-test isolation, `assert_eq`, `write_conf`. Tests source the lib into the test process. Resolver injection seam should fit this model: an env var (e.g., `HALOS_DOMAIN_RESOLVER`) that, when set, is invoked instead of the real chain.
- Existing fallback path (`_halos_set_fallback`) already emits `HALOS_HOSTNAMES_FALLBACK: <reason>` for invalid entries — `${fqdn}` with empty domain produces an entry like `halosdev.` which fails the DNS regex and reuses this path with no new code.

### Institutional Learnings

- PR #122 plan at `docs/plans/2026-04-28-001-feat-multi-hostname-traefik-plan.md` documents the loader contract: parsing/validation lives in `lib-hostnames.sh`, consumers read from globals only.
- `docs/solutions/` — no directly relevant prior solutions.

## Key Technical Decisions

- **Resolver chain order**: `hostname -d` first, `nmcli` second. Admin-set domain (via `hostnamectl` or `/etc/hosts`) is authoritative; auto-discovery only fills the gap. No `resolvectl` (not preinstalled).
- **Resolver lives in a single helper** `_halos_resolve_domain`, called once per `halos_load_hostnames` invocation and cached in a global (e.g., `HALOS_HOSTNAMES_DOMAIN_CACHE`) for the duration of the parse pass. Avoids re-running `nmcli` per line.
- **Resolver injection seam**: `HALOS_DOMAIN_RESOLVER` env var. If set, it names a shell function or command that produces the domain string on stdout; the helper invokes it instead of the real chain. Tests set this; production leaves it unset. Document the seam in a comment in `lib-hostnames.sh`.
- **nmcli timeout/guard**: `command -v nmcli >/dev/null` first; if absent, skip. When invoked, use `nmcli -t -f IP4.DOMAIN device show` (no per-device argument — emits all devices in one call, terse output). Wrap in a `timeout 2s` if `timeout(1)` is available; otherwise rely on nmcli's own behavior. Stderr suppressed.
- **nmcli output parsing**: `IP4.DOMAIN[N]:value` lines, one per device-domain pair. Take the first non-empty value. Skip `--` placeholders nmcli emits for empty fields.
- **Token expansion order in `_halos_expand_line`**: expand `${fqdn}` first (it's the compound token), then `${domain}`, then `${hostname}` last. This ensures `${fqdn}` doesn't leave a stray `${hostname}.${domain}` literal that would then re-expand. (`${fqdn}` substitutes the already-resolved `<short>.<domain>` string directly, not the literal `${hostname}.${domain}`, to keep substitution non-recursive.)
- **DNS regex relaxed to allow single-label**: change the trailing `(\.<label>)+` to `(\.<label>)*` in `HALOS_HOSTNAMES_DNS_RE` so a single label like `halosdev` is valid. SOHO/router DHCP+DNS integrations (UniFi, OpenWrt, pfSense, Fritz!Box, etc.) make bare hostnames resolvable on the LAN, and Authelia per-host cookies + OIDC `redirect_uris` work on single-label hosts. Defense-in-depth `_halos_has_dangerous_chars` still rejects metacharacters, so the relaxation is regex-only.
- **Empty-domain behavior — soft drop**: `_halos_resolve_domain` echoes empty when nothing resolves. To make `${fqdn}` safe in the shipped default, the loader distinguishes two failure classes:
  - **Soft failure** (expansion-induced): the original line contained `${fqdn}` or `${domain}` *and* the resolved domain was empty. The line is silently skipped with a `HALOS_HOSTNAMES_SKIP` journal note (informational, not a fallback). Other entries continue to be parsed normally.
  - **Hard failure** (literal-invalid): the expanded line fails validation for any other reason — admin typo, dangerous chars, cap exceeded. Existing fail-closed `HALOS_HOSTNAMES_FALLBACK` path triggers, all entries discarded, single-SAN default.
  This narrow relaxation is the only loader semantic change. It's scoped: only `${fqdn}`/`${domain}` lines with empty-domain resolution take the soft path; everything else stays fail-closed.
- **Default `hostnames.conf` adds two active lines**: `${hostname}.local` (canonical, mDNS), then `${hostname}` (LAN DNS via DHCP-DNS-integrating routers), then `${fqdn}` (DHCP/admin domain). Each covers a different resolution mechanism so the right one wins on whatever LAN the device is plugged into.

## Open Questions

### Resolved During Planning

- **Should `${fqdn}` re-expand from `${hostname}.${domain}` or substitute directly?** → Substitute directly (resolver returns `<short>.<domain>`), avoids token-recursion edge cases.
- **Should the resolver run per-line or once?** → Once per `halos_load_hostnames` call, cached on the loader's state.
- **Should empty-domain emit a special diagnostic?** → Yes — soft-drop with `HALOS_HOSTNAMES_SKIP: <expansion>` journal line. Distinct from `HALOS_HOSTNAMES_FALLBACK` so admins can grep for the difference.
- **Default `hostnames.conf` content?** → Two active lines: `${hostname}.local` (canonical) followed by `${fqdn}` (additional). Plus commented examples for `${domain}` and literal IP/VPN cases.

### Deferred to Implementation

- Exact name of the cache global / resolver function — pick at implementation time consistent with existing `HALOS_HOSTNAMES_*` and `_halos_*` naming.
- Whether to invoke `nmcli` via `timeout(1)` or rely on nmcli's own connection timeout — confirm on halosdev.local during verification; if nmcli is fast in practice, no `timeout` wrapper.

## Implementation Units

- [ ] **Unit 1: Add domain resolver helper to lib-hostnames.sh**

**Goal:** Introduce `_halos_resolve_domain` and a cache global. Resolver chain: `hostname -d`, then `nmcli`. Honors `HALOS_DOMAIN_RESOLVER` injection seam.

**Requirements:** R3, R5, R6

**Dependencies:** none

**Files:**
- Modify: `halos-core-containers/assets/lib-hostnames.sh`
- Modify: `halos-core-containers/debian/halos-core-containers/usr/lib/halos-core-containers/lib-hostnames.sh` (packaged twin — keep identical)
- Test: `halos-core-containers/tests/test-lib-hostnames.sh`

**Approach:**
- Add `_halos_resolve_domain` next to `_halos_short_hostname`. Logic: if `HALOS_DOMAIN_RESOLVER` is set and is a defined function/command, invoke it and return its stdout trimmed; else try `hostname -d 2>/dev/null` (trim, return if non-empty); else if `command -v nmcli` is available, run `nmcli -t -f IP4.DOMAIN device show 2>/dev/null` and pick the first non-empty value after the colon, skipping `--`; else return empty.
- Cache on first call into a global (e.g., `HALOS_HOSTNAMES_DOMAIN_CACHE`); reset alongside other globals at the top of `halos_load_hostnames`.
- Add a comment block above the helper documenting the injection seam contract.

**Patterns to follow:**
- `_halos_short_hostname` (return value via stdout, no globals mutated).
- `halos_load_hostnames` global-reset block at the function top — extend it to clear the new cache.

**Test scenarios:**
- Happy path: `HALOS_DOMAIN_RESOLVER` set to a function returning `example.com` → helper returns `example.com`.
- Happy path: resolver injected to return empty string → helper returns empty.
- Edge case: resolver returns trailing whitespace → helper trims to bare value.
- Integration: cache cleared on `halos_load_hostnames` re-entry — change resolver mid-test and confirm second load picks up the new value.

**Verification:**
- `_halos_resolve_domain` returns the resolver's value when injection seam is set.
- Function returns empty string (not error) when no domain resolves.
- The real `hostname -d` and `nmcli` paths are exercised manually on halosdev.local during Unit 4 verification.

- [ ] **Unit 2: Token expansion, single-label regex relaxation, and soft-drop semantics**

**Goal:** Expand `${fqdn}` and `${domain}` in `_halos_expand_line`. Relax `HALOS_HOSTNAMES_DNS_RE` to accept single-label hostnames. Amend `halos_load_hostnames` to soft-drop entries whose expansion would be invalid solely because the resolved domain was empty. Existing hard-fail behavior preserved for every other invalid case.

**Requirements:** R1, R2, R4, R8

**Dependencies:** Unit 1

**Files:**
- Modify: `halos-core-containers/assets/lib-hostnames.sh` (also packaged twin)
- Test: `halos-core-containers/tests/test-lib-hostnames.sh`

**Approach:**
- Relax `HALOS_HOSTNAMES_DNS_RE` from `(\.<label>)+` to `(\.<label>)*` so single-label hostnames pass. Defense-in-depth `_halos_has_dangerous_chars` is unchanged and still blocks shell metacharacters.
- In `_halos_expand_line`, compute fqdn as `<short>.<domain>` (or `<short>.` if domain empty), then substitute `${fqdn}` first, `${domain}` second, `${hostname}` last. Single-pass, non-recursive.
- Track per-line whether the original (pre-expansion) line contained `${fqdn}` or `${domain}` and whether the resolved domain was empty. If both, mark this line as `expansion_empty` and have `halos_load_hostnames` skip it via the soft-drop path: emit `HALOS_HOSTNAMES_SKIP: domain unresolved, dropping line: <original>` and `continue` (do not set `had_invalid`).
- All other validation failures keep their current behavior — set `had_invalid=1` → whole-file fallback.
- Document the regex relaxation, the soft-drop rule, and the rationale in comments at each touch point.

**Patterns to follow:**
- Existing `${hostname}` substitution one-liner.
- Existing `_halos_set_fallback` diagnostic format — mirror for `_halos_log "HALOS_HOSTNAMES_SKIP: ..."`.

**Test scenarios:**
- Happy path (single-label): bare `${hostname}` line with hostname `halosdev` → `halosdev` passes the relaxed DNS regex, accepted as DNS.
- Happy path (single-label): literal `halosdev` line → accepted as DNS (regression coverage for the regex relaxation).
- Happy path: `${fqdn}` with resolver returning `example.com` and hostname `halosdev` → `halosdev.example.com` accepted, classified as DNS.
- Happy path: `${hostname}.${domain}` with resolver returning `example.com` → expands identically to `${fqdn}` form.
- Happy path: bare `${domain}` with resolver returning `example.com` → entry is `example.com`, accepted as DNS.
- Happy path: bare `${domain}` with resolver returning `hal` (single label) → entry is `hal`, accepted as DNS under the relaxed regex (covers the halosdev.local DHCP case).
- Happy path (soft drop): config contains `${hostname}.local`, `${hostname}`, and `${fqdn}` with empty resolver → `${fqdn}` soft-dropped with `HALOS_HOSTNAMES_SKIP`; the other two accepted; `HALOS_HOSTNAMES_FALLBACK=0`; canonical = `<short>.local`.
- Edge case (soft drop, only-fqdn): config contains only `${fqdn}` with empty resolver → soft-dropped → zero valid DNS entries → existing "no valid DNS entries" fallback path triggers (with single-SAN default).
- Edge case: `${fqdn}` with admin-typo neighbor `bad..name` → typo triggers hard fallback regardless of fqdn outcome (existing semantics preserved).
- Edge case: bare `${domain}` line with empty resolver → soft-dropped (same path as `${fqdn}`).
- Integration: full `halos_load_hostnames` parse with `${hostname}.local`, `${hostname}`, `${fqdn}`, and a literal IP, resolver returning `example.com` — `HALOS_HOSTNAMES_DNS[]` = [`<short>.local`, `<short>`, `<short>.example.com`]; canonical = `<short>.local`; IPs preserved.

**Verification:**
- All new test scenarios pass; existing 18 tests still pass (the regex relaxation must not regress any prior happy-path or fallback test — verify each one explicitly).
- `HALOS_HOSTNAMES_SKIP` and `HALOS_HOSTNAMES_FALLBACK` are distinguishable in journal output.

- [ ] **Unit 3: Update default hostnames.conf with `${hostname}` and `${fqdn}` active entries**

**Goal:** Ship three active entries — `${hostname}.local` (canonical, mDNS), `${hostname}` (LAN DNS via DHCP-DNS routers), `${fqdn}` (DHCP/admin domain) — so the device answers on whichever resolution path the LAN supports without admin action. Document `${domain}` as a commented example.

**Requirements:** R7

**Dependencies:** Unit 2

**Files:**
- Modify: `halos-core-containers/assets/hostnames.conf`
- Modify: `halos-core-containers/debian/halos-core-containers/etc/halos/hostnames.conf` (packaged twin — Debian conffile)

**Approach:**
- Active section in this order: `${hostname}.local`, `${hostname}`, `${fqdn}`.
- Update header comments to explain: (a) the three supported tokens, (b) the resolver chain (`hostname -d` → `nmcli`), (c) that the relaxed DNS regex accepts single-label hostnames, (d) that `${fqdn}` and `${domain}` are silently soft-dropped when no domain resolves.
- Add commented examples for `${domain}` alone, literal VPN/DNS aliases, and raw IP entries.
- **Conffile-upgrade caveat**: this is a Debian conffile, so existing devices that have the old default will see a `dpkg` conffile prompt on upgrade if untouched. Document in the changelog that admins should accept the new conffile or merge in the new active lines manually.

**Patterns to follow:**
- Existing comment style and `# Examples:` block in `hostnames.conf`.

**Test scenarios:**
- Test expectation: none — content/documentation change, behavior covered by Unit 2 tests.

**Verification:**
- Fresh install on halosdev.local (DHCP `domain_name = hal`) results in cert SANs `halosdev.local`, `halosdev`, `halosdev.hal` with no admin action.
- Fresh install on a device with no DHCP domain results in cert SANs `halosdev.local` and `halosdev` (`${fqdn}` soft-dropped, `HALOS_HOSTNAMES_SKIP` in journal, no fallback).

- [ ] **Unit 4: Update AGENTS.md hostname-list contract section**

**Goal:** Document the new tokens and the resolver chain so future agents extending the loader know the contract.

**Requirements:** R8

**Dependencies:** Unit 2

**Files:**
- Modify: `halos-core-containers/AGENTS.md`

**Approach:**
- Extend the "Hostname-list contract" section: list the three supported tokens (`${hostname}`, `${domain}`, `${fqdn}`), the resolver order (`hostname -d` then `nmcli`), and the empty-domain fail-closed behavior.
- Note the `HALOS_DOMAIN_RESOLVER` injection seam explicitly so future test additions follow the established pattern.

**Test scenarios:**
- Test expectation: none — documentation change.

**Verification:**
- Section reads coherently and references match the implementation.

- [ ] **Unit 5: Version bump and changelog**

**Goal:** Cut a new package version reflecting the change.

**Requirements:** R9

**Dependencies:** Units 1–4

**Files:**
- Modify: `halos-core-containers/VERSION`
- Modify: `halos-core-containers/debian/changelog`

**Approach:**
- Run `./run bumpversion patch` from the repo root after all other changes are committed and tree is clean (memory rule: never `--allow-dirty`).
- If the `check-hostnames` lefthook hits a known false positive on `debian/changelog`, use `LEFTHOOK=0 git commit` to complete the bumpversion's auto-commit per the workspace memory pattern.

**Test scenarios:**
- Test expectation: none — version metadata.

**Verification:**
- `dpkg-parsechangelog` (or `head -1 debian/changelog`) reports the new version with correct RFC 2822 date.
- CI version-bump-check passes on the PR.

## System-Wide Impact

- **Interaction graph:** Loader-internal change. `prestart.sh`, `reload-oidc-clients`, the cert generator, the Authelia template processor, and the OIDC merger all consume `HALOS_HOSTNAMES_DNS[]` post-expansion, so they see the resolved values transparently. No consumer-side changes.
- **Error propagation:** Empty domain → entry rejected by DNS regex → existing `HALOS_HOSTNAMES_FALLBACK` path → device boots in single-SAN default mode. Same failure mode as any other malformed entry today.
- **State lifecycle risks:** The cert hash (`halos_hostnames_hash`) is computed over the post-expansion list, so adding `${fqdn}` to `hostnames.conf` on a deployed device will trigger one cert regen — same one-shot behavior as PR #122's upgrade path. Verified mentally; first install with `${fqdn}` configured will generate cert with `halosdev.<domain>` SAN.
- **API surface parity:** None — internal loader extension.
- **Integration coverage:** The full prestart cert-generation + OIDC merger + Authelia template flow is not unit-tested today (called out as a known gap in PR #122). Verify those flows manually on halosdev.local: cert SANs include `halosdev.hal`, Authelia cookies include the new domain, OIDC redirect_uris expand to include the FQDN.
- **Unchanged invariants:** `${hostname}` token continues to behave exactly as today. Default install behavior (no `hostnames.conf` edits) is unchanged. The `${HALOS_DOMAIN}` placeholder in OIDC client snippets is a separate substitution layer in `halos_expand_oidc_redirect_uri` and is not affected by this change.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `nmcli` hang on a misconfigured device blocks prestart | `command -v nmcli` guard + fail-tolerant invocation; consider `timeout 2s` wrapper. Verify on halosdev.local that the call returns promptly. |
| DHCP-provided domain is a single label (e.g., `hal`) | Single-label entries are now accepted by the relaxed DNS regex; bare `${domain}` returning `hal` validates as DNS and produces a `hal` SAN. `${fqdn}` produces `halosdev.hal` which is also valid. |
| Single-label regex relaxation could let admin typos through (e.g., `mispelled`) | Expansion-induced empties soft-drop, but admin-typed single labels validate as legit. This is acceptable: a typo'd single-label hostname produces a SAN nobody resolves, which is harmless. The dangerous-chars defense-in-depth is unchanged. |
| Conffile prompt on upgrade if admin already edited `hostnames.conf` | Standard Debian conffile behavior. Changelog entry calls out the new `${fqdn}` line so admins can merge it in. Devices that haven't been edited get the new default automatically. |
| Soft-drop relaxation weakens the fail-closed contract | Scoped narrowly: only `${fqdn}`/`${domain}` lines with empty domain take the soft path. All other validation failures still hard-fail. Distinct journal signature (`HALOS_HOSTNAMES_SKIP` vs `HALOS_HOSTNAMES_FALLBACK`) keeps observability clean. |
| Resolver returns a stale value if DHCP lease changes after prestart | Out of scope per user confirmation (HaLOS devices don't migrate networks). Documented in `hostnames.conf` comments that admins should `systemctl restart halos-core-containers.service` after intentional network changes. |
| Test injection seam diverges from real resolver behavior | Resolver helper is small (≤20 lines); manual verification on halosdev.local closes the gap that mocks can't cover. |
| Packaged-twin file drift between `assets/` and `debian/halos-core-containers/` copies | Both files updated in the same commit; existing packaging convention. Add a quick `diff` check during verification. |

## Documentation / Operational Notes

- Conffile comment update doubles as user-facing documentation.
- AGENTS.md update is the developer-facing reference.
- No external docs site changes required.
- Real-device verification target: `halosdev.local` — after deploy, edit `/etc/halos/hostnames.conf` to include `${fqdn}` line, restart `halos-core-containers.service`, confirm:
  - `journalctl -u halos-core-containers.service` shows no `HALOS_HOSTNAMES_FALLBACK` line.
  - `openssl x509 -in /var/lib/container-apps/halos-core-containers/data/traefik/certs/halos.crt -noout -ext subjectAltName` lists `halosdev.hal` (and the original `halosdev.local`).
  - Authelia configuration.yml shows a cookie entry for `hal`.

## Sources & References

- Related PR: halos-org/halos-core-containers#122 (multi-hostname Traefik support, merged 2026-04-28)
- Related plan: `docs/plans/2026-04-28-001-feat-multi-hostname-traefik-plan.md`
- Loader: `halos-core-containers/assets/lib-hostnames.sh`
- Loader tests: `halos-core-containers/tests/test-lib-hostnames.sh`
- Repo AGENTS.md hostname-list contract section: `halos-core-containers/AGENTS.md`
