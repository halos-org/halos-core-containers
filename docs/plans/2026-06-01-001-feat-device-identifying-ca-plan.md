---
title: Device-identifying auto-CA (hostname in CN, filename, and /ca instructions)
type: feat
status: active
date: 2026-06-01
origin: https://github.com/halos-org/halos-core-containers/issues/159
---

# Device-identifying auto-CA

**Target repo:** `halos-core-containers`. New unit on the open epic #159 (effortless CA trust). The `.mobileconfig` carrier merged as #173; the `.deb` carrier (old Unit 6) was dropped.

## Overview

Each HaLOS device generates its own auto-CA, but the CA's subject is the constant `/CN=HaLOS Device CA` and the published file is always `halos-ca.crt`. Across a fleet, every device's CA is therefore indistinguishable — in OS trust stores (Keychain Access, the iOS Profiles list, the Windows store) and in the Downloads folder. The pain is worst not at install but at **management**: an operator trying to delete a stale device's CA sees several identical `HaLOS Device CA` rows with no way to tell them apart.

This plan makes the auto-CA device-identifying by reflecting the device hostname/fqdn in (a) the CA's subject CN, (b) the downloaded filename, and (c) the `/ca` landing-page instructions. The CN change is gated by an **adoption** model so it never orphans an already-installed CA.

## Problem Frame

The auto-CA is deliberately long-lived (20 y) and is **not** regenerated on hostname change, because regenerating orphans every trust anchor an operator already installed. So we cannot simply bake the current hostname into the CN and re-issue on rename. The insight that unlocks this: regenerating the auto-CA is *free of orphan risk* until the CA has been downloaded at least once — before first download, nothing is installed anywhere to orphan. So the CN can be kept fresh by regenerating while **unadopted**, and frozen permanently at **first external download**.

The filename and the on-page instructions are simpler: the `/ca` page is served from the very device being accessed, so client-side JavaScript already knows the hostname via `window.location.hostname` and can set a device-specific download filename and name the device in the steps — with no server-side hostname injection and no URL-path change.

## Requirements Trace

- **R1.** The auto-CA subject CN reflects the device hostname (`HaLOS Device CA (<fqdn>)`), so devices are distinguishable in trust stores for both install and deletion. (see origin: #159)
- **R2.** The downloaded certificate filename reflects the hostname, so multiple devices' files are distinguishable in a Downloads folder.
- **R3.** The `/ca` instructions name the device and stay correct for **both** older certs (generic CN) and new certs (hostname CN).
- **R4.** CN-refresh regeneration never orphans an installed CA: it is permitted only while the CA is unadopted (never externally downloaded) and is frozen at first download. Pre-feature CAs are treated as already adopted.
- **R5.** The cert-serving health signal is preserved — a broken cert bind-mount still marks the sidecar unhealthy — even though the healthcheck is no longer what marks the CA "downloaded".
- **R6.** The existing expiry / clock-skew self-heal CA regeneration is unaffected by the adoption gate.
- **R7.** Operator-supplied custom CAs are untouched (the operator owns their CN).
- **R8.** An operator escape hatch exists to force a CN refresh on an already-adopted device, with the re-trust cost documented.

## Scope Boundaries

- **Custom CAs unchanged.** Only the auto-CA gains a hostname CN.
- **URL path `/ca/halos-ca.crt` is stable.** Only the *saved* filename (Content-Disposition / `download` attribute) becomes device-specific; the path the tile, docs, and routing use does not move.
- **Post-adoption rename does not rewrite the CN.** Accepted residual — cosmetic only; TLS keeps working via the leaf's SANs.
- **No remote-address gating.** Moving the healthcheck off the cert path removes the only internal hitter, so no source-IP logic is needed.
- **No per-download analytics.** The adoption marker is one-bit ("has ever been downloaded"), not a request log we mine.
- **No change to the leaf, Cockpit override, or Traefik reload paths.** CA regeneration re-signs the leaf through the existing sentinel mechanism; nothing else in the cert state machine changes.

## Context & Research

### Relevant Code and Patterns

- `assets/lib-ca.sh` — `halos_ca_ensure_auto` (CA generation; currently uses the constant `HALOS_CA_SUBJECT`), `halos_ca_select_active` (auto/custom selection + serving symlink), `halos_ca_publish_mobileconfig` (already embeds `HaLOS Device CA (<hostname>)` in `PayloadDisplayName` — reuse this exact string format), atomic `<tmp>`+`mv` writes, aux-failure WARN-and-continue, explicit return codes 0/1/2.
- `assets/halos-manage-certs` — resolves `HALOS_DOMAIN` via `halos_canonical_hostname`; owns `AUTO_CA_DIR`, `PUBLIC_CA_DIR`, and the leaf sentinel (`.domain`, `<hostnames-hash>:<ca-fingerprint>`). The sentinel already includes the CA fingerprint, so any CA regeneration triggers a leaf re-sign automatically.
- `assets/ca-download/nginx.conf` — exact-match `location = /ca/halos-ca.crt` and `= /ca/halos-ca.mobileconfig` (alias to `/srv/...`), global `access_log off`. Landing index served from a *separate* bind-mount (`/srv-landing`) than the cert (`/srv`).
- `docker-compose.yml` — `ca-download` service: read-only mounts only; healthcheck currently probes `/ca/halos-ca.crt` (deliberately, to catch a missing cert — see the inline comment).
- `assets/ca-download/landing/index.html` — self-contained page; existing inline JS already reads `navigator.userAgent` to auto-expand the matching OS section.
- `docs/CERTS.md` — operator-facing cert lifecycle doc.
- `docs/solutions/2026-05-24-set-e-cmdsubst-blind-spot.md` — guard `$(...)` captures with explicit status checks.
- `docs/solutions/2026-05-31-deploy-downgrade-evicts-dependent-packages.md` / issue #174 — on-device test method: deploy a devtest-versioned local build *above* the installed version with a simulate-and-abort-on-removal guard, or the CI `trixie-unstable` artifact — never a plain `./run build`.

### External References

None required — internal shell/nginx work with strong local patterns. Apple/macOS trust behavior was already researched for #173 and does not bear on this unit.

## Key Technical Decisions

1. **CN format `HaLOS Device CA (<canonical-hostname>)`**, reusing the `.mobileconfig` `PayloadDisplayName` string verbatim. Hostname source is `halos_canonical_hostname` — the same value the leaf CN and the profile already use.

2. **Adoption model with a `cn-pending` creation marker.** When *this version* creates a new auto-CA, it stamps the CN with the current hostname **and** writes a `cn-pending` marker (recording the hostname baked into the CN) in the CA directory. CN-refresh regeneration fires only when `cn-pending` is present, no `adopted` sentinel exists, and the resolved hostname differs from the marker's hostname. **Absence of `cn-pending` ⇒ treat as adopted (frozen).** This is what makes migration safe: a CA created by the old version has no `cn-pending` marker, so it is never refresh-regenerated and its installed copies are never orphaned (R4).

3. **Adoption = first external download, detected at the sidecar.** Nginx records hits on `/ca/halos-ca.crt` and `/ca/halos-ca.mobileconfig` to a marker file in a **new, single-purpose, writable** bind-mount (the cert/public mount stays read-only). `halos-manage-certs` reads the marker each run and **promotes** it to a persistent `adopted` sentinel in the CA directory (and clears `cn-pending`). The persistent sentinel — not the nginx marker — is the durable source of truth, closing the rotation/recreate-gap race where a download between cert-manager runs could otherwise be lost (R4). **Within a run, promotion runs before the CN-refresh gate**, so a cert downloaded during the rename window freezes at the CN the user actually installed rather than being regenerated out from under them.

4. **Health-probe carve-out.** Move the Docker healthcheck off `/ca/halos-ca.crt` onto a dedicated internal nginx location (`= /healthz/cert`) that aliases the published cert with `access_log off`, so it verifies the `/srv` cert mount is served (a broken mount → non-2xx → unhealthy) **without** counting as a download. Because the healthcheck was the only internal hitter of the cert path, every remaining hit there is a genuine external download — so no remote-address gating is needed (R5).

5. **CN-refresh regen is a distinct trigger** from the existing expiry/clock-skew self-heal regen (`HALOS_CA_AUTO_REGEN_THRESHOLD_DAYS`). The self-heal path is untouched and still fires regardless of adoption; CN-refresh is an additional, adoption-gated path (R6).

6. **Escape hatch reuses the existing "delete the CA to opt into rotation" ergonomics.** `halos_ca_ensure_auto` already bootstraps a fresh CA when both `ca.crt` and `ca.key` are absent. Deleting them now produces a hostname CN + a fresh `cn-pending` marker. No new code — just documentation of the re-trust cost (R8).

7. **Filename + instructions are client-side.** The landing page sets the download anchor's `download` attribute to a sanitized `halos-ca-<hostname>.crt` and fills the device name into the steps from `window.location.hostname`. The URL path is unchanged. Instructions reference the stable `HaLOS Device CA` prefix (a trust-store search still finds it) and show the device name as *context*, so the copy is correct for both old and new CNs (R2, R3).

## Open Questions

### Resolved During Planning

- **How is "downloaded" made durable across nginx log rotation and container recreation?** → The cert-manager promotes the transient nginx marker to a persistent `adopted` sentinel in the CA dir on the first run that observes it; the sentinel is the source of truth thereafter.
- **How do we avoid orphaning existing devices on upgrade?** → `cn-pending`-absent ⇒ assume adopted (frozen). Only CAs created by this version are CN-refresh-eligible.
- **Does the healthcheck pollute the adoption signal?** → No — it moves to a marker-free `/healthz/cert` location.
- **Server-side hostname injection for the filename?** → Not needed; `window.location.hostname` is the device hostname as accessed.

### Deferred to Implementation

- Exact marker / sentinel filenames and on-disk format (e.g. plain hostname line vs. key=value). Impl detail; keep atomic `<tmp>`+`mv` writes.
- Whether to truncate the nginx download log on promotion (housekeeping; not required for correctness).
- The precise nginx directive for `/healthz/cert` (alias + `access_log off` vs `try_files`) — pick the simplest that returns non-2xx when the cert file is absent.
- Hostname sanitization for the `download` filename (dots are fine; handle access via raw IPv4/IPv6 — strip/replace `:` and surrounding brackets) and the fallback when `location.hostname` is an IP literal.
- Whether the `cn-pending` marker stores the hostname or the cert-manager re-derives the CA's CN-hostname via `openssl x509 -subject` for the comparison — decide for the cheapest reliable compare.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

Per-auto-CA adoption lifecycle:

```
created by THIS version
   ├─ CN = "HaLOS Device CA (<hostname-at-creation>)"
   └─ write cn-pending(hostname)
        │
        │  each halos-manage-certs run, while cn-pending present AND no adopted sentinel:
        │     resolved hostname != cn-pending hostname  ──► regenerate CA (new CN), rewrite cn-pending
        │                                                    (leaf re-signs via sentinel mismatch)
        │
        ▼
external download of /ca/halos-ca.crt or .mobileconfig
   └─ nginx appends to the download marker (writable state mount)
        │  next halos-manage-certs run:
        ▼
promote: write adopted sentinel, clear cn-pending  ──►  FROZEN (CN never refreshed again)

created by OLD version (no cn-pending)  ──►  treated as adopted from the start  ──►  FROZEN
```

Serving topology delta (sidecar):

```
/ca/halos-ca.crt           → /srv/halos-ca.crt          + download marker  (external only)
/ca/halos-ca.mobileconfig  → /srv/halos-ca.mobileconfig + download marker  (external only)
/healthz/cert  (internal)  → /srv/halos-ca.crt          access_log off     (healthcheck target)
new writable mount: <data>/certs/state  →  /srv-state   (download marker lives here)
```

## Implementation Units

- [ ] **Unit 1: Adoption signal — health carve-out, scoped download marker, sentinel promotion**

**Goal:** Establish a durable "this CA has been externally downloaded" signal without the healthcheck triggering it. After this unit the `adopted` sentinel appears on first external cert/profile download; nothing consumes it yet.

**Requirements:** R4 (detection half), R5.

**Dependencies:** None.

**Files:**
- Modify: `assets/ca-download/nginx.conf` — add `location = /healthz/cert` (alias the published cert, `access_log off`); add a scoped `access_log` to the new state mount on the two public cert/profile locations only.
- Modify: `docker-compose.yml` — retarget the `ca-download` healthcheck to `/healthz/cert`; add a single-purpose writable mount (host `${CONTAINER_DATA_ROOT}/${PACKAGE_NAME}/certs/state` → container `/srv-state`). Keep `/srv` read-only.
- Modify: `assets/halos-manage-certs` — after CA selection, read the download marker; if present and the active CA is the auto-CA, write a persistent `adopted` sentinel in `AUTO_CA_DIR` (atomic). Aux-failure semantics (WARN, continue).
- Modify: `assets/lib-ca.sh` — small helper(s) for "is the CA adopted?" and "promote to adopted", following the atomic-write + return-code conventions.
- Test: `tests/test-ca-download-endpoint.sh` (marker written on external GET of cert + profile; `/healthz/cert` returns 200 when the cert is present and is NOT logged to the marker), `tests/test-halos-manage-certs.sh` (a seeded download marker promotes to an `adopted` sentinel on the next run; idempotent).

**Approach:**
- The health location aliases the same published cert so a missing `/srv` mount still fails the probe (preserves the current behavior's intent); it carries `access_log off` so it can never count as adoption.
- The download marker is append-only; the persistent `adopted` sentinel in the CA dir is the durable truth, so marker rotation/clearing is safe afterwards.
- Promotion runs unconditionally and cheaply each cert-manage run; it is a no-op once the sentinel exists.

**Patterns to follow:** `halos_ca_publish_public` (atomic `<tmp>`+`mv`, aux-failure), the existing healthcheck-comment rationale in `docker-compose.yml`, the read-only-mount posture of the sidecar.

**Test scenarios:**
- Happy path: external GET of `/ca/halos-ca.crt` writes a marker entry; a subsequent cert-manage run creates the `adopted` sentinel.
- Happy path: GET `/ca/halos-ca.mobileconfig` also marks adoption.
- Edge case: `/healthz/cert` returns 200 with the cert present and leaves the marker empty (probe does not adopt).
- Edge case: cert absent from `/srv` → `/healthz/cert` returns non-2xx (probe fails → unhealthy), confirming the preserved health signal.
- Edge case: promotion is idempotent — a second run with the sentinel already present is a no-op and does not error.
- Integration: a Docker healthcheck cycle (loopback probe of `/healthz/cert`) does not create a marker entry.

**Verification:** On a test device, fetching the cert externally and then running `halos-manage-certs` leaves an `adopted` sentinel; the sidecar healthcheck reports healthy via `/healthz/cert`; breaking the `/srv` cert mount flips the container unhealthy.

---

- [ ] **Unit 2: Hostname CN + unadopted-refresh regeneration**

**Goal:** New auto-CAs carry `HaLOS Device CA (<hostname>)`; while unadopted, a hostname change refreshes the CN by regenerating the CA; once adopted (or for pre-feature CAs) the CN is frozen.

**Requirements:** R1, R4 (policy half), R6, R7, R8.

**Dependencies:** Unit 1 (consumes the `adopted` sentinel).

**Files:**
- Modify: `assets/lib-ca.sh` — `halos_ca_ensure_auto` accepts the hostname and uses it in the CN on creation, and writes the `cn-pending` marker; `halos_ca_select_active` threads the hostname through to the auto branch only. Custom-CA branch unchanged.
- Modify: `assets/halos-manage-certs` — pass `HALOS_DOMAIN` into selection; add the CN-refresh gate (regenerate the auto-CA when `cn-pending` present, no `adopted` sentinel, and resolved hostname differs from the marker's); extend promotion (Unit 1) to also clear `cn-pending`.
- Test: `tests/test-lib-ca.sh` (CN embeds hostname on creation; `cn-pending` written; custom CA untouched), `tests/test-halos-manage-certs.sh` (unadopted hostname change refreshes CN + re-signs leaf; adopted CA is frozen; pre-feature CA with no `cn-pending` is frozen; self-heal/expiry regen still fires independent of adoption).

**Approach:**
- The CN-refresh gate is a new branch distinct from the expiry/skew path; both can lead to regeneration but for different reasons, and only the CN-refresh branch is adoption-gated.
- Regeneration reuses the existing delete-then-bootstrap behavior of `halos_ca_ensure_auto`; the leaf re-signs because the sentinel's CA-fingerprint component changes.
- Migration safety rests entirely on "no `cn-pending` ⇒ frozen": pre-feature CAs are never touched.

**Patterns to follow:** existing `HALOS_CA_SUBJECT` usage and the `halos_ca_ensure_auto` partial-state / rotation guards; the sentinel-invalidation-before-resign ordering in `halos-manage-certs`; `set -e` cmd-subst guards.

**Test scenarios:**
- Happy path: fresh auto-CA's subject CN is `HaLOS Device CA (<hostname>)` and a `cn-pending` marker exists.
- Happy path: unadopted device renamed → next run regenerates the CA with the new CN and re-signs the leaf; `cn-pending` updated.
- Edge case: unadopted device, hostname unchanged → no regeneration (no churn).
- Edge case: adopted CA (sentinel present) renamed → CN unchanged, no regeneration.
- Edge case: pre-feature CA (no `cn-pending`, generic CN) → never regenerated regardless of hostname.
- Error/independence: expiry/clock-skew regen still fires for an adopted CA (self-heal unaffected), picking up the current hostname in the new CN.
- Edge case: custom CA active → CN untouched, no `cn-pending`, no refresh logic runs.

**Verification:** On a fresh test device, the auto-CA CN names the device; renaming before any download updates the CN on the next cert-manage run; after downloading the cert once, a rename no longer changes the CN. Deleting `ca.crt`+`ca.key` (escape hatch) yields a new hostname CN.

---

- [ ] **Unit 3: Device-specific download filename and on-page device name**

**Goal:** The `/ca` page offers the cert as `halos-ca-<hostname>.crt` and names the device in the install steps, correct for both old and new CNs.

**Requirements:** R2, R3.

**Dependencies:** None (client-side; independent of Units 1–2).

**Files:**
- Modify: `assets/ca-download/landing/index.html` — extend the inline JS to read `window.location.hostname`, set the cert download anchor(s)' `download` attribute to a sanitized `halos-ca-<hostname>.crt`, and fill the device name into the intro and the per-OS steps. Keep the stable `HaLOS Device CA` prefix in trust-store-search wording.
- Test: `tests/test_landing_content.py` (download anchors carry a `download` attribute / placeholder; the cert link path is still `/ca/halos-ca.crt`; the "search for HaLOS Device CA" wording is present so old CNs still match).

**Approach:**
- Pure client-side; no nginx or server change. The URL path stays `/ca/halos-ca.crt`; only the suggested save name changes.
- Because the page can't know whether a given device's cert has the new or old CN, instructions anchor on the stable prefix and present the hostname as context ("…it will show your device name, `<hostname>`, in parentheses").
- Sanitize the hostname for filesystem-safe filenames; fall back gracefully when accessed by raw IP.

**Patterns to follow:** the existing inline UA-detection script in `index.html`; the section-aware content guards already in `tests/test_landing_content.py`.

**Test scenarios:**
- Happy path: the macOS/Windows/Android/Linux download anchors target `/ca/halos-ca.crt` and carry a `download` attribute (static guard for the attribute's presence; the hostname value is set at runtime).
- Edge case: instructions retain the `HaLOS Device CA` search term so a generic-CN cert is still findable.
- Edge case (manual/JS): accessed via `https://<ip>/ca/`, the filename degrades to a safe default rather than embedding `:` or brackets.

**Test expectation: limited** — most behavior is runtime DOM from `location.hostname`; static guards cover the structural invariants, the rest is manual device verification.

**Verification:** Opening `/ca/` on the device, the download saves as `halos-ca-<hostname>.crt` and the steps name the device; the cert URL is unchanged.

---

- [ ] **Unit 4: Documentation**

**Goal:** Document the CN-identity model, the adoption-freeze, the regen-trigger separation, and the escape hatch.

**Requirements:** R3, R8 (operator-facing).

**Dependencies:** Units 1–3.

**Files:**
- Modify: `docs/CERTS.md` — describe the hostname CN, the "free to regenerate until first download, then frozen" adoption model, that pre-feature CAs stay frozen (generic CN), the separation from expiry/skew self-heal, and the delete-the-CA escape hatch with its re-trust cost.

**Approach:** Operator-focused; explain *why* the CN can go stale after adoption (the orphan-avoidance invariant) and how to force a refresh.

**Patterns to follow:** existing `docs/CERTS.md` structure and tone.

**Test scenarios:** Test expectation: none — prose only.

**Verification:** A reviewer reading `docs/CERTS.md` understands when the CN reflects the hostname, why it freezes, and how to force a refresh.

## System-Wide Impact

- **Interaction graph:** `halos-manage-certs` ↔ `lib-ca.sh` helpers ↔ `AUTO_CA_DIR` (`cn-pending`, `adopted` sentinels) ↔ `ca-download` sidecar (download marker via the new writable mount). CA regeneration re-signs the leaf through the existing sentinel; Cockpit/Traefik reloads fire as they already do on leaf change.
- **Error propagation:** marker read, sentinel promotion, and CN-refresh are aux-failure (WARN, continue) — they never block leaf provisioning or the container stack.
- **State lifecycle risks:** the `cn-pending → adopted` transition is one-way and idempotent; all sentinel writes are atomic `<tmp>`+`mv`. The durable `adopted` sentinel closes the marker-rotation race.
- **API surface parity:** the public URL set is unchanged (`/ca/halos-ca.crt`, `/ca/halos-ca.mobileconfig`, `/ca/`); `/healthz/cert` is internal-only and not Traefik-routed.
- **Unchanged invariants:** the URL path, custom-CA handling, leaf signing, the existing expiry/clock-skew self-heal regen, and the sentinel format are all unchanged. A CN-refresh regen changes the CA fingerprint, which the sentinel already treats as a leaf re-sign trigger — expected.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Migration regen orphans existing installed CAs | `cn-pending`-absent ⇒ frozen; only this-version CAs are refresh-eligible |
| Hostname flaps pre-adoption → repeated regen | Bounded (pre-adoption, no orphan); the sticky-domain layer in `lib-hostnames` dampens flapping |
| New writable mount weakens the sidecar's read-only posture | Single-purpose marker only; cert/public mount stays read-only; nothing sensitive in the state dir |
| Health location accidentally counted as a download | Distinct location with `access_log off`; only the two public cert/profile locations log to the marker |
| Raw IP / IPv6 access yields a bad filename | Sanitize the hostname; fall back to a safe default |
| On-device testing re-triggers the deploy-downgrade trap | Use a devtest build above the installed version with a simulate-and-abort-on-removal guard, or the CI `trixie-unstable` artifact (#174) |

## Documentation / Operational Notes

- **Release notes:** new behavior is the hostname-bearing auto-CA CN on fresh devices and a device-specific download filename. Existing devices are unaffected until their CA is regenerated. No URL or OIDC/hostname-semantics change.
- **On-device verification:** deploy a devtest-versioned local build (above the installed version) with the simulate-and-abort-on-removal guard, or the CI `trixie-unstable` package — never a plain `./run build` deploy (#174).
- **VERSION:** per `AGENTS.md`, do not bump unless `VERSION` equals the latest stable tag and this opens the next cycle; CI walks the `+N` revision otherwise.

## Sources & References

- **Epic:** [halos-org/halos-core-containers#159](https://github.com/halos-org/halos-core-containers/issues/159)
- **Predecessor:** #173 (`.mobileconfig` carrier — established the `HaLOS Device CA (<hostname>)` display string and the read-only sidecar shape)
- **Related:** #174 (harden local build/deploy), `docs/solutions/2026-05-31-deploy-downgrade-evicts-dependent-packages.md`, `docs/solutions/2026-05-24-set-e-cmdsubst-blind-spot.md`
- **Prior plan:** `docs/plans/2026-05-28-001-feat-effortless-ca-trust-plan.md`
