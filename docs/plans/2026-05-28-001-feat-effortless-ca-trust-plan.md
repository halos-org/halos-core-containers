---
title: Effortless HaLOS CA trust on remote clients
type: feat
status: active
date: 2026-05-28
origin: https://github.com/halos-org/halos-core-containers/issues/159
---

# Effortless HaLOS CA trust on remote clients

**Target repo:** `halos-core-containers` (primary). Documentation touchpoints in `docs.halos.fi`. Sibling read-only dependency: `homarr-container-adapter` (consumes the new `webapps.d` entry without modification).

## Overview

The HaLOS device generates a per-device CA and signs its own TLS leaf. Today, the CA is downloadable at a bare `/halos-ca.crt` URL with no surrounding context. Most users skip the install or do it wrong (cert imported but not trusted for SSL), so Brave/Chromium falls into per-port click-through fatigue as soon as the dashboard cards redirect to `:4430-:4450`. This plan adds (1) a polished landing page at `/ca` with per-platform install instructions, and (2) a Homarr dashboard tile pointing at it, so the install becomes a first-class onboarding step the operator can complete in the minimum number of OS-imposed clicks.

**This plan ships in two phases.** Phase 1 delivers the broad-reach UX win — a landing page, the dashboard tile, and the URL move — using only the existing `halos-ca.crt` artifact. Per-platform installers (`.mobileconfig` for Apple, `.deb` for Debian/Ubuntu) ship in Phase 2 once Phase 1 is observed in production. Both phases live in this single plan; Phase 2 units are clearly marked and may be split into a follow-on plan when work begins.

## Problem Frame

Pre-#142, HaLOS served a self-signed leaf. Brave/Chromium grants self-signed certs a *host-wide* exception after a single click-through. Post-#142, the leaf is signed by an internal CA, and Chromium's exception model becomes *per-(host, port, leaf-fingerprint)*. Every per-app port the dashboard redirects to requires its own interstitial; icon subresources silently fail because Chromium doesn't show interstitials for subresources. The empirical regression was confirmed earlier in this session by hot-swapping the leaf back to self-signed and observing one click-through → all icons load.

The chosen path is **not** to revert. It is to make the CA install painless enough that operators actually do it. Once the CA is installed and trusted, every port shows a clean lock. Click-through users (those who decline install) retain functional dashboard navigation — they are not the target of this work, but their fallback experience must remain serviceable.

## Requirements Trace

- **R1.** Fresh Brave on macOS Sequoia reaches green lock everywhere after: download `.mobileconfig` → install via System Settings → flip the trust toggle. Landing page explains both steps with screenshots.
- **R2.** Fresh Brave/Chrome on Android reaches green lock in browser after the 6-tap Settings flow (apps will not trust the CA — Android-7+ design, documented).
- **R3.** Fresh Brave on Debian/Ubuntu reaches green lock everywhere after one `.deb` double-click + admin password. Firefox NSS quirk noted in copy.
- **R4.** Fresh Safari on iOS reaches green lock after profile install + Certificate Trust Settings toggle, same two-step shape as macOS.
- **R5.** Click-through users (no install) retain functional dashboard navigation. The regression vs. self-signed is documented as expected when declining install.
- **R6.** Dashboard tile always visible — links to `/ca` — placed in the existing card grid via `webapps.d` mechanism.
- **R7.** Landing page detects User-Agent client-side and expands the relevant OS section; other sections remain collapsible for users installing for a different device.
- **R8.** Landing page is explicit about Apple's separate trust-toggle step — no claim of "one click."
- **R9.** Artifacts (`.mobileconfig`, `.deb`, `.crt`) rotate with the active CA via a hook in `halos-manage-certs`. Idempotent on every run.
- **R10.** Existing `/halos-ca.crt` URL moves under `/ca/halos-ca.crt`. Docs updated in the same unit. Endpoint is two weeks old; churn acceptable; no redirect needed.

## Scope Boundaries

- **Phase 1 scope** (this PR cycle): URL move, landing page UI with bare-`.crt` per-OS walkthroughs, Homarr dashboard tile, documentation update. No new artifacts; no changes to `halos-manage-certs` or `lib-ca.sh`. Five OSes covered (macOS, iOS, Android, Linux, Windows).
- **Phase 2 scope** (follow-on PR cycle, documented in this plan but not implemented yet): `.mobileconfig` artifact for Apple, `.deb` artifact for Debian/Ubuntu, landing-page enhancement to expose them. May be re-scoped into a dedicated follow-on plan when work begins.
- **Windows installer:** out of scope at any phase. Bare `.crt` is served with explicit wizard-pitfall warnings ("you MUST pick *Trusted Root Certification Authorities*").
- **Tile auto-hide when CA installed:** out of scope. Operator may use multiple clients; tile stays visible.
- **Cross-device CA sharing / fleet trust anchor:** out of scope. Each device has its own CA.
- **Custom Android companion app:** out of scope. Browser support is sufficient for the dashboard use case.
- **Device-self-trust** (the device's own desktop trusting its own CA): tracked separately in #158.
- **Browser-profile prepopulation** (Firefox NSS, Chromium policy file): out of scope.
- **Signed `.mobileconfig`:** out of scope at Phase 2. Unsigned profiles install fine with a cosmetic "Not Signed" warning; signing requires an Apple Developer ID we do not own.

## Context & Research

### Relevant Code and Patterns

- `assets/ca-download/nginx.conf` — current sidecar config. Single static `location` block. Pattern is "alias to bind-mounted file with explicit `default_type` and `Content-Disposition`". Extended in Unit 1.
- `assets/halos-manage-certs` — orchestrates CA select → publish → leaf sign → Cockpit override → Traefik touch. The new artifact-publish helpers slot in next to `halos_ca_publish_public`. Pattern is "auxiliary failure logs WARN and continues" (line 110 in current file).
- `assets/lib-ca.sh` — home of CA helpers (`halos_ca_select_active`, `halos_ca_sign_leaf`, `halos_ca_publish_public`, etc.). Pattern is "library function with explicit named arguments, internal logging via `>&2`, atomic write via `<tmp>` + `mv`". New helpers follow this shape.
- `docker-compose.yml:190-240` — Traefik routers for `/halos-ca.crt` (HTTP→HTTPS redirect + secure route). Routers fold from one path to one path-prefix in Unit 1.
- `/etc/halos/webapps.d/cockpit.toml` and `/etc/halos/webapps.d/marine-signalk-server-container.toml` — webapps.d TOML pattern. Fields: `name`, `url`, `description`, `icon_url`, `category`, `visible`, `[layout]` with `priority`/`width`/`height`/`x_offset`/`y_offset`. The CA tile mirrors this exact shape.
- `homarr-container-adapter/src/registry.rs` — reads the TOML at every adapter sync. No adapter changes required.
- `docs/CERTS.md:140-222` — current user-facing CA download narrative. Replaced/rewritten in Unit 6.

### Institutional Learnings

- `docs/solutions/2026-05-24-set-e-cmdsubst-blind-spot.md` — `set -e` does not abort on command-substitution failure inside an assignment. Any new `lib-ca.sh` helper that captures `$(...)` (e.g., `CA_DER=$(openssl x509 -outform DER -in "$CA" | base64 -w0)`) must guard with `|| exit 1` or use the documented `local var; var=$(...)` pattern with explicit status check.
- `docs/solutions/2026-05-25-openssl-text-grep-defeated-by-subject-dn.md` — `openssl x509 -text` output can be ambiguous when subject DN contains punctuation. The new helpers only need the raw DER and the fingerprint, both already extracted safely via `halos_ca_fingerprint`. Avoid `-text | grep` patterns.

### External References

- **Apple Configuration Profile Reference** — `com.apple.security.root` payload type, plist schema for embedded CA cert. Apple Developer docs.
- **Apple Support HT102390** — iOS Certificate Trust Settings toggle requirement (still current on iOS 17/18).
- **Apple Developer Forums #724327** + **mitmproxy/mitmproxy discussion #7194** — macOS Sequoia change where manually-installed profiles no longer auto-trust for SSL.
- **Debian Policy Manual §5.6.7 and §6.5** — `.deb` postinst and update-ca-certificates conventions.
- **Android 14 user-only CA store** — emteria.com user-trust install documentation.

## Key Technical Decisions

1. **Extend existing `ca-download` nginx sidecar; do not add a new container.** Single-purpose static-file sidecar already exists; adding `location` blocks and bind-mounting a `landing/` directory keeps the surface tiny.

2. **User-Agent detection is client-side JavaScript on the landing page.** Server-side `map $http_user_agent` was considered; rejected because (a) UA detection in nginx is fragile, (b) users installing for a different device need to override the auto-detected section, (c) client-side keeps the nginx config trivially auditable.

3. **`.mobileconfig` is unsigned.** Signed profiles require an Apple Developer ID (~$100/yr) that HaLOS does not have. Unsigned shows a "Not Signed" warning at install time — cosmetic, addressed in landing-page copy. Future plan unit can sign if a Developer ID becomes available.

4. **`.deb` installs the active CA to `/usr/local/share/ca-certificates/halos-ca.crt`** and runs `update-ca-certificates` in postinst. CA bytes are embedded at generation time; the `.deb` rotates with the active CA. Mirrors the device-self-trust mechanism in #158 — same install target, same trust path.

5. **Artifact generation hooks `halos_ca_publish_public`'s code path** in `halos-manage-certs`. Each artifact has its own `halos_ca_publish_<artifact>` helper, called unconditionally after the public CA PEM is published. Aux-failure pattern: log WARN, continue. The leaf and CA are the hard prerequisites; artifacts are opportunistic.

6. **URL move `/halos-ca.crt` → `/ca/halos-ca.crt`.** The endpoint is two weeks old (introduced 2026-05-12). No long-running operator scripts depend on it. `/halos-ca.crt` 404s after the move; docs note the new path. Dispenses with redirect overhead.

7. **Dashboard tile is a `webapps.d` TOML entry** shipped by the `halos-core-containers` package. No adapter changes. Tile points to `/ca` (path-only URL, multi-hostname-compatible). `[layout].priority` set in the 60-79 utility band (default 70) so the tile sits below primary apps but above the external-link band.

8. **Landing-page assets ship in `assets/ca-download/landing/`** and bind-mount into the sidecar at `/srv/landing`. Static HTML/CSS/JS plus PNG screenshots. No build step.

## Open Questions

### Resolved During Planning

- Where do the artifact generators live? → `lib-ca.sh` helpers, called from `halos-manage-certs`. Idempotent, aux-failure semantics.
- Server-side vs client-side UA detection? → Client-side JS. Simpler nginx, override-friendly.
- Redirect `/halos-ca.crt` or 404? → 404. Two-week-old endpoint, no entrenchment risk.
- Tile priority band? → 70 (utility). Above external apps, below primary.
- Sign the `.mobileconfig`? → No (this round). Cosmetic warning only.

### Deferred to Implementation

- Exact SVG content for the tile icon — implementer produces a "shield-and-arrow" or "lock-and-download" glyph; reviewed at PR time.
- Exact screenshot count and copy per OS section — implementer drafts, reviewed at PR time.
- Whether to also ship `/ca/halos-ca.pem` as a PEM alias for tools that prefer the `.pem` extension — decide during landing-page UI work.
- Whether the `.deb` should bridge Firefox NSS via `p11-kit-modules` Depends — decide during `.deb` unit (default: no Depends, document instead).
- Exact `.deb` package name (`halos-ca-trust`? `halos-device-ca`?) and versioning scheme — decide during `.deb` unit.
- Whether `/ca/` index serves `index.html` directly or via `try_files` chain — implementer picks the cleanest nginx pattern.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

### Artifact publication chain (end state after Phase 2)

```
halos-manage-certs.service / .timer
  ├─ halos_ca_select_active                    (existing)
  ├─ halos_ca_publish_public      → halos-ca.crt              (existing — only artifact in Phase 1)
  ├─ halos_ca_publish_mobileconfig→ halos-ca.mobileconfig     (Phase 2, Unit 5)
  ├─ halos_ca_publish_deb         → halos-ca_<ver>_all.deb    (Phase 2, Unit 6)
  ├─ halos_ca_sign_leaf                        (existing)
  ├─ Cockpit override                          (existing)
  └─ Traefik touch                             (existing)
```

Phase 1 ships only the existing `halos-ca.crt` publish step — `halos-manage-certs` is unchanged in Phase 1. Phase 2 adds the two new helpers. All publish helpers write into the same `PUBLIC_CA_DIR` (bind-mounted as `/srv` in the sidecar). Aux-failure on any of the new Phase 2 helpers logs WARN and continues — never aborts cert management.

### Serving topology

```
Brave / Chrome / Safari
  ↓
Traefik :443   (router: PathPrefix /ca → ca-download@docker)
  ↓
ca-download (nginx) :80
  /ca/                       → /srv/landing/index.html         (Phase 1)
  /ca/halos-ca.crt           → /srv/halos-ca.crt                (existing, URL-moved in Phase 1)
  /ca/halos-ca.mobileconfig  → /srv/halos-ca.mobileconfig       (Phase 2)
  /ca/halos-ca.deb           → /srv/halos-ca_<ver>_all.deb      (Phase 2)
  /ca/style.css, /ca/app.js  → /srv/landing/                    (Phase 1)
  /ca/screenshots/*          → /srv/landing/screenshots/        (Phase 1)
  /halos-ca.crt              → 410 Gone + Link hint              (Phase 1)
```

### Dashboard tile

```
halos-core-containers package
  ↓ installs
/etc/halos/webapps.d/halos-ca-install.toml      (visible=true, url=/ca/)
/usr/share/pixmaps/halos-ca-install.svg          (icon)
  ↓
homarr-container-adapter sync (30-min cycle or Docker event)
  ↓
Homarr dashboard renders the tile alongside other apps
```

## Implementation Units

### Phase 1 — Broad-reach UX win (ship now)

**Goal of Phase 1:** Every user on every supported OS gets a guided install experience pointing at the existing `halos-ca.crt`, surfaced from a dashboard tile. No new artifacts; pure UX layering on top of what's already shipped. Four units, all independently reviewable.

### Unit 1 — URL move + landing scaffold

- [ ] **Unit 1: URL move /halos-ca.crt → /ca + landing scaffold**

**Goal:** Move the existing `/halos-ca.crt` endpoint under `/ca/`, add a placeholder landing page at `/ca/`, and prepare the bind-mount + nginx structure that Unit 2 fills in. After this unit, the URL space is correct and a "coming soon" page renders at `/ca/`, but no real per-platform install instructions exist yet.

**Requirements:** R10, partially R6 (target URL).

**Dependencies:** None.

**Files:**
- Modify: `assets/ca-download/nginx.conf` — replace single `location = /halos-ca.crt` with a `location /ca/` prefix tree (sub-locations for `=/ca/`, `=/ca/halos-ca.crt`, `^~ /ca/`). Old `/halos-ca.crt` returns 410 Gone with a hint header pointing to `/ca/halos-ca.crt`.
- Modify: `docker-compose.yml` — Traefik router rule `Path(\`/halos-ca.crt\`)` becomes `PathPrefix(\`/ca/\`)` plus an explicit `Path(\`/halos-ca.crt\`)` router that still hits the sidecar (so the sidecar can serve the 410 itself). HTTP redirector router updated accordingly. Bind-mount adds `assets/ca-download/landing:/srv/landing:ro`.
- Create: `assets/ca-download/landing/index.html` — placeholder HTML, single H1 ("HaLOS device trust"), short paragraph, link to the bare cert at `/ca/halos-ca.crt`. Replaced in Unit 2.
- Modify: `docs/CERTS.md` — update every reference of `/halos-ca.crt` to `/ca/halos-ca.crt`. Add a short note "URL moved 2026-05-28; old path returns 410."
- Test: `tests/test-ca-download-endpoint.sh` (existing file referenced in past commits; if absent, create) — assert `/ca/halos-ca.crt` returns 200 with `Content-Type: application/x-x509-ca-cert` and `Content-Disposition: attachment`, `/ca/` returns 200 with `Content-Type: text/html`, `/halos-ca.crt` returns 410 with a `Location` or `Link` header pointing to `/ca/halos-ca.crt`.

**Approach:**
- Keep the `disable_symlinks`, `limit_except GET HEAD`, and `attachment` Content-Disposition guards from the current config — they apply to every location serving real bytes.
- The 410 for `/halos-ca.crt` is served by the sidecar itself, not Traefik, so the error body can include a Markdown link or HTML pointer. Keeps Traefik config simple.
- Healthcheck (already probes `/halos-ca.crt`) updates to `/ca/halos-ca.crt`.

**Patterns to follow:**
- Existing `location = /halos-ca.crt` block in `assets/ca-download/nginx.conf` for the cert-serving pattern.
- Existing docker-compose router definitions for ca-download for the Traefik router shape.
- `0e4ee5c feat(certs): serve /halos-ca.crt download endpoint via Traefik` commit for the rationale around public/unauth-gated serving.

**Test scenarios:**
- *Happy path:* `curl -sI https://halosdev.local/ca/halos-ca.crt` returns 200 + `Content-Type: application/x-x509-ca-cert` + `Content-Disposition: attachment; filename="halos-ca.crt"`.
- *Happy path:* `curl -s https://halosdev.local/ca/` returns 200 + `Content-Type: text/html` + body containing the H1 placeholder text.
- *Edge case:* `curl -sI https://halosdev.local/halos-ca.crt` returns 410 with a hint header (`Link: </ca/halos-ca.crt>; rel="canonical"` or similar) — confirms the move is discoverable for clients with the old URL.
- *Edge case:* `curl -sX POST https://halosdev.local/ca/halos-ca.crt` returns 405 + `Allow: GET, HEAD` — the existing read-only guard still holds on the new path.
- *Integration:* nginx container `docker healthcheck` reports `healthy` after the URL move — the healthcheck probe of the new path succeeds.

**Verification:** A reviewer fetching `https://halosdev.local/ca/` in any browser sees the placeholder page; fetching `https://halosdev.local/ca/halos-ca.crt` triggers the OS cert-install dialog (same UX as before); fetching `https://halosdev.local/halos-ca.crt` shows a clear "moved" error rather than a silent 404. `docs/CERTS.md` references the new URL throughout.

---

### Unit 2 — Landing page UI (Phase 1, bare-`.crt` only)

- [ ] **Unit 2: Landing page UI with per-OS bare-`.crt` install walkthroughs**

**Goal:** Replace the Unit 1 placeholder at `/ca/` with a polished landing page that detects the visitor's OS, expands the relevant section by default, and walks the user through the truthful install steps for the bare `halos-ca.crt`. Honest about Apple's separate trust-toggle step. Phase 2's Unit 7 later upgrades this page with installer artifacts; Phase 1 is the static, self-contained baseline.

**Requirements:** R5 (functional click-through fallback), R7 (UA detection), R8 (Apple honesty), partial R1/R2/R3/R4 (bare-`.crt` paths only).

**Dependencies:** Unit 1.

**Files:**
- Modify: `assets/ca-download/landing/index.html` — full content. Single self-contained HTML page with five OS sections (macOS, iOS, Android, Linux, Windows). Each section is a `<details>`/`<summary>` block, collapsed by default; JS expands the UA-matched one. Top-level intro paragraph names the device hostname (server-injected at request time, see Approach) and a single prominent "Download `halos-ca.crt`" button.
- Create: `assets/ca-download/landing/style.css` — page styling. Match Homarr dashboard aesthetic (dark background, HaLOS accent color); reuse logo SVG from `halos-homarr-branding` if practical.
- Create: `assets/ca-download/landing/app.js` — tiny vanilla JS (no framework). Parses `navigator.userAgent`, expands the matching `<details>` section, leaves others collapsible. Falls back to "all collapsed, pick one" if UA is unrecognized.
- Create: `assets/ca-download/landing/screenshots/` — directory with PNG screenshots per OS. Phase 1 target counts: macOS ~6 (download → Keychain Access import → System keychain pick → trust dialog → "Always Trust" → green lock), iOS ~5, Android ~6, Linux ~2 (terminal commands), Windows ~5 (the Cert Import Wizard with the "Trusted Root" pitfall). Implementer captures on a representative device.
- Modify: `assets/ca-download/nginx.conf` — serve static assets under `/ca/` (style.css, app.js, screenshots/), set `Content-Security-Policy: default-src 'self'` on the landing HTML, set long-cache headers on screenshots.
- Modify: `assets/ca-download/nginx.conf` — inject the device hostname into the landing HTML at request time via `sub_filter` (or equivalent). Hostname read from an env var passed at container start (`HALOS_DOMAIN`). Implementer picks the simplest path that does not require Lua.
- Test: `tests/test-ca-landing-page.sh` — bash test using `curl` + `grep` to assert the landing page returns 200, contains the right section IDs, links to `/ca/halos-ca.crt`, and embeds the current device hostname.

**Approach:**
- Page structure: H1 with HaLOS logo, intro paragraph naming the device hostname, prominent download button, five collapsible OS sections, footer linking to fingerprint-verification advice.
- Each OS section: numbered steps with inline screenshots. Steps reference exact UI strings ("System Settings → General → Profiles", "Settings → Security & privacy → More security settings") so the page is searchable.
- macOS section: Safari downloads the `.crt`, which Safari then offers to install via Profiles. Walk through System Settings → General → VPN & Device Management → Profile install → admin password → **then** System Settings → General → About → Certificate Trust Settings → toggle ON. Honest about the toggle being a Sequoia change; link Apple's HT102390 article.
- iOS section: mirrors macOS — Safari downloads, profile installs via Settings → General → VPN & Device Management, then trust toggle in Settings → General → About → Certificate Trust Settings.
- Android section: walk through the 6-tap install via Settings → Security & privacy → More security settings → Encryption & credentials → Install a certificate → CA certificate → pick the downloaded `.crt`. Note explicitly that apps will not trust the cert (Android-7+ design); browsers will.
- Linux section: two paths offered side-by-side — Debian/Ubuntu (`sudo cp` to `/usr/local/share/ca-certificates/`, `sudo update-ca-certificates`) and Fedora/RHEL (`sudo cp` to `/etc/pki/ca-trust/source/anchors/`, `sudo update-ca-trust`). Single-paragraph note about Firefox's NSS store with `p11-kit-modules` as the workaround.
- Windows section: walk through `.crt` double-click → Install Certificate → Local Machine or Current User → **explicitly emphasize** "Place all certificates in the following store" → Browse → **"Trusted Root Certification Authorities"** (NOT Automatic). Note Chrome/Edge honor the Windows store; Firefox needs separate import or `security.enterprise_roots.enabled=true`.
- Hostname injection: nginx `sub_filter __HALOS_HOSTNAME__ "$HALOS_DOMAIN"` with the hostname value passed via env var at container start. Same pattern other HaLOS nginx sidecars use.
- Phase 2 collaboration: this unit reserves clear DOM anchors (e.g., `<div data-installer-slot="macos">`, `<div data-installer-slot="ios">`, `<div data-installer-slot="linux">`) so Unit 7 can drop in `.mobileconfig` and `.deb` buttons without re-doing the page.

**Patterns to follow:**
- `halos-homarr-branding` for HaLOS visual identity (logo, color palette, typography).
- Existing prestart env-var propagation pattern in `prestart.sh` for hostname plumbing.
- mkcert / smallstep landing-page tone — concise, honest, screenshot-led, no marketing fluff.

**Test scenarios:**
- *Happy path:* `curl -s https://halosdev.local/ca/` returns 200 + `Content-Type: text/html` + body containing `<section id="macos">`, `<section id="ios">`, `<section id="android">`, `<section id="linux">`, `<section id="windows">`.
- *Happy path:* The HTML body contains the current device hostname at least once in the intro paragraph — sub_filter substitution works.
- *Happy path:* The HTML body links to `/ca/halos-ca.crt` from the prominent download button and from each OS section's step 1.
- *Edge case:* `curl -s https://halosdev.local/ca/style.css` returns 200 + `Content-Type: text/css`. Same for `/ca/app.js` (`application/javascript`) and one representative screenshot.
- *Edge case:* `curl -sI https://halosdev.local/ca/screenshots/macos-step-1.png` returns 200 + cache header with ≥1 day expiry.
- *Edge case:* Phase 2 anchor stubs (`data-installer-slot` attributes) exist in the HTML — Unit 7 can find and populate them without modifying the page structure.
- *Integration:* Manual smoke test in fresh Brave on macOS auto-expands the macOS section. iOS Safari, Android Chrome, Linux Brave, Windows Edge each auto-expand their respective section. (Implementer documents the UA strings tested in the test file as comments.)
- *Integration:* JS-disabled fallback: all sections render collapsed but accessible via `<summary>` click. Page remains functional without JavaScript.

**Verification:** A reviewer opening `https://halosdev.local/ca/` in a fresh Brave window on macOS sees a polished, branded page with the macOS section expanded, a prominent "Download `halos-ca.crt`" button, an honest explanation of the two Apple steps with annotated screenshots, and discoverable other-OS sections via the collapsibles. The page is readable on a phone-sized viewport.

---

### Unit 3 — Homarr dashboard CA-install tile

- [ ] **Unit 3: Homarr dashboard CA-install tile**

**Goal:** Add a `webapps.d` TOML entry that surfaces the `/ca/` landing page as a tile on the Homarr dashboard. Tile is always visible, ships with the `halos-core-containers` package, and appears on existing dashboards on the next adapter sync without operator action.

**Requirements:** R6.

**Dependencies:** Unit 1 (URL exists). Otherwise independent — can land before or after Unit 2.

**Files:**
- Create: `assets/halos-ca-install.toml` — webapps.d entry. `name = "Trust this device"`, `url = "/ca/"`, `description = "Install the device CA on your phone, laptop, or tablet for warning-free access."`, `icon_url = "/usr/share/pixmaps/halos-ca-install.svg"`, `category = "Setup"`, `visible = true`. `[layout].priority = 70`, `width = 1`, `height = 1`. No `[type]` container_name (external link).
- Create: `assets/halos-ca-install-icon.svg` — SVG icon for the tile. Visual concept: shield + arrow-down, or padlock + download glyph. Implementer drafts; reviewed at PR time.
- Modify: `debian/halos-core-containers.install` (or equivalent — verify in current debian/) — list the new `.toml` and SVG with their install destinations:
  - `assets/halos-ca-install.toml` → `/etc/halos/webapps.d/`
  - `assets/halos-ca-install-icon.svg` → `/usr/share/pixmaps/`
- Test: `tests/test-halos-ca-install-toml.sh` — assert the TOML file parses cleanly (`taplo check` or `python3 -c "import tomllib; tomllib.loads(open('...').read())"`), all required fields are present, the `icon_url` points to a path that exists in the install map.

**Approach:**
- `priority = 70` places the tile in the "utility" band — visible alongside primary apps but not above them. Picked from the memory note about priority bands (10=system, 40=primary, 60-79=utility, 80-99=external).
- The tile uses `url = "/ca/"` (path-only), so it works across every configured hostname (mDNS, VPN FQDN, etc.) — same multi-hostname pattern the other webapps.d entries use.
- No `ping_url` — the landing page is static and doesn't need health checks. Existing adapter handles missing `ping_url` (treats as no-ping, no liveness dot).
- The adapter syncs new webapps.d entries on its next cycle (~30 min worst case, or any Docker event triggers immediate re-sync). Operators upgrading the `halos-core-containers` package see the tile appear without intervention.

**Patterns to follow:**
- `/etc/halos/webapps.d/cockpit.toml` for the field shape and `[type]`-without-container_name pattern (external/native services).
- `/etc/halos/webapps.d/marine-signalk-server-container.toml` for the icon-path-via-pixmaps convention.
- `/usr/share/pixmaps/cockpit.svg` for SVG size/style baseline (typically 256×256 viewbox, single color palette).

**Test scenarios:**
- *Happy path:* `tomllib.loads(open('assets/halos-ca-install.toml').read())` succeeds and the parsed dict contains `name`, `url`, `icon_url`, `visible=True`, `[layout].priority`.
- *Happy path:* `assets/halos-ca-install-icon.svg` is a valid SVG (`xmllint --noout` succeeds, root element is `<svg>`).
- *Edge case:* `icon_url` path in the TOML matches the install destination of the SVG file in `debian/halos-core-containers.install` — no drift between the registry entry and the package's actual install map.
- *Integration:* After `dpkg -i halos-core-containers_<ver>_all.deb` on a test device, `/etc/halos/webapps.d/halos-ca-install.toml` and `/usr/share/pixmaps/halos-ca-install.svg` are present and world-readable.
- *Integration:* After the adapter's next sync (forced via `systemctl restart homarr-container-adapter` or equivalent), the Homarr dashboard renders the tile with the expected label and icon. Clicking the tile navigates to `/ca/`.

**Verification:** A reviewer on a test device with the new package installed reloads `https://halosdev.local/` and sees a "Trust this device" tile in the dashboard's utility band. Clicking it lands on the `/ca/` page. The tile renders correctly on both desktop (wide grid) and mobile (narrow grid) viewports.

---

### Unit 4 — Documentation (Phase 1)

- [ ] **Unit 4: Documentation — URL move + landing-page reference**

**Goal:** Update `docs/CERTS.md` (operator-facing technical doc) and the user-facing trust guide in `docs.halos.fi` so they describe the new `/ca/` landing page, the moved URL, and the bare-`.crt` install paths shipped in Phase 1. Phase 2 will update these again when installer artifacts ship.

**Requirements:** R10 (URL move documentation), supports R1-R4 indirectly via the landing-page link.

**Dependencies:** Units 1-3.

**Files:**
- Modify: `docs/CERTS.md` — rewrite the "CA download endpoint" section (currently §140-222). Reference `/ca/halos-ca.crt` as the new URL. Document the `/ca/` landing page as the recommended path for non-expert users. Note the URL move with a "2026-05-28" anchor for future archaeology. Mention Phase 2 installer-artifact plans briefly in a "future work" subsection so future maintainers understand the trajectory.
- Modify: `docs.halos.fi/docs/...trust-the-device.md` (or current file name — implementer locates) — update to point users at `https://<device>.local/ca/`. Drop the multi-paragraph per-platform manual instructions; replace with a single paragraph: "The device's `/ca/` page walks you through the install on macOS, iOS, Android, Linux, and Windows." Retain the operator-facing "verify the SHA-256 fingerprint over SSH" advanced procedure as an expandable subsection.
- Modify: any developer-facing README that references `/halos-ca.crt` — implementer greps `**/README.md` and `**/*.md` under the repo for old URL references and updates each.
- Test: `tests/test-docs-references.sh` (likely doesn't exist — create) — assert no `.md` file in the repo contains the bare `/halos-ca.crt` path anymore (only the new `/ca/halos-ca.crt`). Allows a single exception in `docs/CERTS.md` itself for the "URL moved" historical note.

**Approach:**
- Don't write multi-paragraph manual install instructions in `docs.halos.fi` anymore — they go stale fast and duplicate what the in-product landing page now does better. Docs link to the device, not the other way around.
- `docs/CERTS.md` stays operator-focused: cert lifecycle, rotation triggers, where things live on disk, how to verify out-of-band.
- For `docs.halos.fi`, the "trust the device" guide narrows to a single page that tells users "go to https://your-device.local/ca/" and offers the fingerprint-verification procedure as advanced material.

**Patterns to follow:**
- Existing `docs/CERTS.md` structure (operator-facing, deep technical detail).
- Existing `docs.halos.fi` MkDocs structure and user-tone (concise, action-oriented, screenshots when helpful).
- The MkDocs config validation pattern already in use — implementer runs `mkdocs build --strict` against `docs.halos.fi/` after changes.

**Test scenarios:**
- *Happy path:* `grep -rn '/halos-ca\.crt' docs/ docs.halos.fi/ README.md` returns only references to `/ca/halos-ca.crt` (or the documented historical "URL moved" line).
- *Happy path:* `mkdocs build --strict` succeeds against `docs.halos.fi/` after changes — link checks pass.
- *Integration:* Manual review of the rendered `docs.halos.fi` trust-the-device page: a user following the link can complete the install end-to-end on a real device using only the on-device landing page.

**Test expectation: limited** — most of this unit is prose changes; testing is grep-and-build rather than behavioral.

**Verification:** A reviewer reading the updated `docs/CERTS.md` understands the new URL and the landing-page architecture; a reviewer reading the updated `docs.halos.fi` trust-the-device guide can install the CA on their own device by following the link to `/ca/`.

---

### Phase 2 — Per-platform installers (follow-on)

**Goal of Phase 2:** Replace the manual bare-`.crt` install path on Apple platforms (with `.mobileconfig` profiles) and Debian/Ubuntu (with a `.deb` installer) for the cleanest possible UX on those platforms. Scheduled after Phase 1 ships and is observed in production. The units below may be re-scoped into a dedicated follow-on plan when work begins; they're documented here so the full architectural trajectory is captured in one place.

**Phase 2 status (2026-06-01).** Device testing reshaped the Apple scope and cancelled the `.deb`:

- **`.mobileconfig` is iOS/iPadOS-only, not macOS** (PR #173). On macOS (Ventura+) a manually-installed profile root is not SSL-trusted automatically, does not appear in Keychain Access, and macOS has no Certificate Trust Settings toggle — there is no path to trust it. macOS keeps the raw-`.crt` + Keychain "Always Trust" flow. The profile earns its place on iOS, where the trust toggle exists and it fixes the Files-app routing (#169, verified on a real iPad). See `developer.apple.com/forums/thread/724327`.
- **Unit 6 (`.deb` carrier) — DROPPED.** A `.deb` runs arbitrary maintainer scripts as root; the existing Linux path (`cp` to `/usr/local/share/ca-certificates/` + `update-ca-certificates`) is auditable and the operator can see exactly what it does. The transparency win outweighs the double-click convenience. Linux stays on the CLI path.
- **Artifact set is now:** `.crt` (all platforms) + `.mobileconfig` (iOS/iPadOS). No `.deb`.

### Unit 5 — `.mobileconfig` artifact

- [x] **Unit 5: Apple Configuration Profile artifact** (PR #173 — iOS/iPadOS-only; see Phase 2 status above)

**Goal:** Generate a `halos-ca.mobileconfig` next to `halos-ca.crt` on every cert publish, install it as a static asset the nginx sidecar can serve, and verify it loads on macOS/iOS as a root-CA profile.

**Requirements:** R1, R4, R9 (Apple platforms).

**Dependencies:** Phase 1 Units 1 and 2 (URL space and landing page must exist).

**Files:**
- Modify: `assets/lib-ca.sh` — new helper `halos_ca_publish_mobileconfig(active_ca_crt, public_dir)`. Reads the CA in DER, base64-encodes it, substitutes into a template, writes atomically (`<tmp>` + `mv`) to `${public_dir}/halos-ca.mobileconfig`. Aux-failure semantics: returns non-zero, caller logs WARN.
- Modify: `assets/halos-manage-certs` — invoke `halos_ca_publish_mobileconfig` immediately after `halos_ca_publish_public`. Wrap with `if ! ...; then echo WARNING... >&2; fi` mirroring the existing aux-failure idiom.
- Create: `assets/ca-download/templates/halos-ca.mobileconfig.tpl` — XML plist template with a `com.apple.security.root` payload, a single `__HALOS_CA_DER_B64__` placeholder for the CA bytes, fixed UUIDs (one for the outer Configuration payload, one for the inner Certificate payload — UUIDs are profile identifiers; static UUIDs are fine for an unsigned, single-CA profile and keep the bytes deterministic across rotations).
- Modify: `assets/ca-download/nginx.conf` — add `location = /ca/halos-ca.mobileconfig` with `default_type application/x-apple-aspen-config` and `Content-Disposition: attachment; filename="halos-ca.mobileconfig"`.
- Create: `tests/test-halos-ca-publish-mobileconfig.sh` — bats-style or pure-bash test asserting the helper produces a parseable plist with the expected payload.
- Modify: `tests/test-halos-manage-certs.sh` (existing) — extend to assert the `.mobileconfig` file appears in `PUBLIC_CA_DIR` after a successful run.

**Approach:**
- The plist template is a heredoc-style file with one substitution token. `sed s|__HALOS_CA_DER_B64__|...|` is fine; the base64 of an RSA-2048 CA cert is ~2 KB and contains no `|` or `&`.
- Use `openssl x509 -outform DER -in "$CA_CRT" | base64 -w0` to produce the substitution payload. Guard the pipeline as a single command-substitution capture with explicit `|| return 1` per the `set -e` learning (`docs/solutions/2026-05-24-set-e-cmdsubst-blind-spot.md`).
- Atomic write pattern mirrors `halos_ca_publish_public`: write to `${out}.tmp`, `mv -f` into place.
- UUIDs: hardcoded constants in the template. They identify the profile in the device's Profiles list — drift would create duplicate entries on rotation. Fixed UUIDs mean reinstalls overwrite cleanly.
- The `PayloadDisplayName` field embeds the device hostname so users see e.g. "HaLOS Device CA (halosdev.local)" in System Settings → Profiles, distinguishing devices in a fleet.

**Patterns to follow:**
- Existing `halos_ca_publish_public` in `assets/lib-ca.sh` for the atomic-write + aux-failure shape.
- Existing `halos-manage-certs` invocation of `halos_ca_publish_public` (line 110 in current file) for the WARN-and-continue caller pattern.
- Apple Configuration Profile Reference for the `com.apple.security.root` schema.

**Test scenarios:**
- *Happy path:* After running `halos_ca_publish_mobileconfig`, the output file is a valid plist (`plutil -lint` succeeds or, in CI, a simple grep for `<plist version=` + DER decoding round-trip succeeds).
- *Happy path:* The DER payload extracted from the `.mobileconfig` is byte-identical to the input CA's DER bytes (round-trip).
- *Edge case:* Helper called with a missing CA file returns non-zero, does not create a partial output file, does not delete a pre-existing valid output file (preserve-on-failure).
- *Edge case:* Hostname embedded in the `PayloadDisplayName` matches `halos_canonical_hostname` output (sentinel against fleet-misidentification).
- *Integration:* After a full `halos-manage-certs` run, `${PUBLIC_CA_DIR}/halos-ca.mobileconfig` exists, mtime matches the CA publish step, and the file is readable by the nginx sidecar (mode 0644).
- *Integration:* `curl -sI https://halosdev.local/ca/halos-ca.mobileconfig` returns 200 with `Content-Type: application/x-apple-aspen-config` and `Content-Disposition: attachment`.

**Verification:** A reviewer downloading the file on a Mac (`curl -O https://halosdev.local/ca/halos-ca.mobileconfig`) and double-clicking it sees the standard System Settings → Profiles install sheet, with `HaLOS Device CA (halosdev.local)` as the profile display name and the expected CA cert under "More Details." Install completes without errors. iOS download via Safari produces the same install sheet under Settings → General → VPN & Device Management.

---

### Unit 6 — `.deb` installer artifact

- [~] **Unit 6: Debian/Ubuntu `.deb` installer artifact — DROPPED** (a `.deb` runs arbitrary root maintainer scripts; the transparent `cp` + `update-ca-certificates` CLI path is preferred. See Phase 2 status above.)

**Goal:** Generate a tiny `.deb` whose postinst drops the active CA into `/usr/local/share/ca-certificates/halos-ca.crt` and runs `update-ca-certificates`, rotating alongside the CA via `halos-manage-certs`. Same trust mechanism #158 uses on the device itself, packaged for remote Linux clients.

**Requirements:** R3, R9 (Debian/Ubuntu).

**Dependencies:** Phase 1 Units 1 and 2.

**Files:**
- Modify: `assets/lib-ca.sh` — new helper `halos_ca_publish_deb(active_ca_crt, public_dir)`. Assembles a tar tree, runs `dpkg-deb -b`, writes atomically to `${public_dir}/halos-ca_<ver>_all.deb`.
- Modify: `assets/halos-manage-certs` — invoke the helper after the `.mobileconfig` step. Same aux-failure semantics.
- Create: `assets/ca-download/deb-template/DEBIAN/control` — package metadata. Package name `halos-device-ca-trust`. Architecture `all`. Section `admin`. Description references HaLOS device CA.
- Create: `assets/ca-download/deb-template/DEBIAN/postinst` — calls `update-ca-certificates`. Idempotent. Standard `set -e` + `case "$1"` action handling.
- Create: `assets/ca-download/deb-template/DEBIAN/postrm` — removes the cert and re-runs `update-ca-certificates` on `remove`/`purge`. Standard symmetric pattern.
- Create: `assets/ca-download/deb-template/usr/local/share/ca-certificates/.gitkeep` — placeholder so the directory ships in the template; the CA bytes are written here at build time by the helper.
- Modify: `assets/ca-download/nginx.conf` — add `location = /ca/halos-ca.deb` (or the versioned name; see Approach) with `default_type application/vnd.debian.binary-package` and `Content-Disposition: attachment`.
- Create: `tests/test-halos-ca-publish-deb.sh` — test asserting the generated `.deb` is well-formed (`dpkg-deb -I` succeeds), contains the expected files, and survives `lintian` cleanly.

**Approach:**
- Versioning: package version is the HaLOS-core-containers `VERSION` file value plus an internal counter on CA fingerprint change. Implementer picks the simplest scheme that ensures `dpkg --install` always replaces the installed copy when the embedded CA rotates — likely `<core-version>+ca<short-fingerprint>`. Decide during implementation.
- File served at the URL: stable name `/ca/halos-ca.deb` (symlink or alias inside the bind-mount) so the landing page can hardcode the download URL. The actual generated file is the versioned name; nginx serves via `alias` with the canonical name.
- The helper writes the CA bytes into the staging tree, runs `dpkg-deb --root-owner-group -b <stagedir> <output>`. `--root-owner-group` is the modern equivalent of `fakeroot` for files owned by `root:root` — avoids the `fakeroot` dependency on the device.
- Aux-failure: if `dpkg-deb` is not installed (it isn't always present on minimal Debian images), the helper logs a single WARN line and continues. Eventually we may want to make `dpkg-deb` a hard dependency of `halos-core-containers`, but **deferred** for this round — see the open question on the issue.

**Patterns to follow:**
- `assets/halos-manage-certs:217-224` — Cockpit-install aux-failure pattern (try, log WARN on failure, continue).
- Existing `debian/postinst` in `halos-core-containers` for the action-dispatch pattern (`case "$1" in configure) ... ;; esac`).
- Standard Debian `update-ca-certificates` integration documented in Debian Policy §5.6.7.

**Test scenarios:**
- *Happy path:* `halos_ca_publish_deb` produces a file at `${public_dir}/halos-ca_<ver>_all.deb` that `dpkg-deb -I` parses and reports the expected `Package`, `Architecture`, `Version` fields.
- *Happy path:* `dpkg-deb -c` lists `/usr/local/share/ca-certificates/halos-ca.crt` in the package contents, sized to the active CA's PEM bytes.
- *Edge case:* `lintian` run against the generated `.deb` reports no errors (warnings acceptable, errors not).
- *Edge case:* If `dpkg-deb` is not available, the helper returns non-zero, logs a single WARN line to stderr, and does not create a partial output file. `halos-manage-certs` continues past the failure (does not abort).
- *Edge case:* Subsequent invocations with the same CA produce byte-identical output (deterministic build).
- *Integration:* After install on a Debian/Ubuntu test VM (`dpkg -i halos-ca.deb`), `/etc/ssl/certs/halos-ca.pem` symlink exists and points to the installed cert via `update-ca-certificates`'s expected output. `curl https://halosdev.local/ca/halos-ca.crt` succeeds without `-k`.

**Verification:** A reviewer SSHing to a Debian 12+ or Ubuntu 22+ test VM, downloading the `.deb` from `/ca/halos-ca.deb`, double-clicking (or `apt install ./halos-ca.deb`), and re-loading `https://halosdev.local/` in Brave/Chrome on that VM sees a green lock with zero further action. `apt remove halos-device-ca-trust` cleanly removes the cert and trust state.

---

### Unit 7 — Landing page enhancement (Phase 2)

- [x] **Unit 7: Landing page enhancement — Apple flows** (PR #173; iOS leads with the profile, macOS stays on the raw `.crt`. The Debian `.deb` portion is moot — Unit 6 dropped.)

**Goal:** Update the Phase 1 landing page to add `.mobileconfig` download buttons on the macOS and iOS sections and a `.deb` download button on the Linux section's Debian/Ubuntu subsection. The bare-`.crt` paths are demoted to "Advanced" subsections (preserved, not removed). Other OS sections (Android, Windows, Linux non-Debian) remain Phase-1 unchanged.

**Requirements:** R1, R3, R4 (the installer-led targets).

**Dependencies:** Phase 1 Unit 2 (landing page exists with the `data-installer-slot` anchors), Phase 2 Units 5 and 6 (artifacts exist).

**Files:**
- Modify: `assets/ca-download/landing/index.html` — populate the `data-installer-slot="macos"`, `="ios"`, `="linux"` anchor stubs with installer download buttons + step instructions. Demote the bare-`.crt` walkthroughs on those platforms to "Advanced" expandable subsections.
- Modify: `assets/ca-download/landing/screenshots/` — replace or supplement Phase 1 screenshots: macOS profile-install sheet (System Settings → Profiles), iOS profile-install screen (Settings → VPN & Device Management), Debian/Ubuntu `.deb` double-click → Software Install dialog. Phase 1 Keychain Access / CLI screenshots move into the "Advanced" subsections where the bare-`.crt` path still applies.
- Modify: `tests/test-ca-landing-page.sh` — extend with assertions that the landing page links to `/ca/halos-ca.mobileconfig` and `/ca/halos-ca.deb` and that the per-platform anchor slots are populated.

**Approach:**
- macOS section: profile-based path becomes the primary recommendation. Two steps: download `.mobileconfig` → install via Profiles → flip the trust toggle. Bare-`.crt` + Keychain Access stays in "Advanced" for users on older macOS where Profiles behavior differs.
- iOS section: profile-based path is primary (was already implicit in Phase 1 because Safari wraps `.crt` as a profile anyway, but Phase 2 supplies a named profile with `PayloadDisplayName = HaLOS Device CA (halosdev.local)` instead of just the CA's CN — meaningful for fleet operators).
- Linux Debian/Ubuntu subsection: `.deb` button at the top, single-line "double-click to install" copy. Manual `cp` + `update-ca-certificates` steps preserved below for users who want to inspect what they install or who run a non-Debian distro.
- Don't remove the bare-`.crt` download link entirely — keep it for users using curl, scripted setups, or fingerprint-verification flows.
- Other sections (Android, Windows, Linux Fedora/RHEL) are intentionally unchanged: no installer artifact for those platforms in this scope.

**Patterns to follow:**
- Phase 1 Unit 2's `data-installer-slot` DOM anchor convention (this unit's primary job is filling those slots).
- Phase 1 Unit 2's screenshot conventions (size, format, naming, lazy-load attribute).

**Test scenarios:**
- *Happy path:* `curl -s https://halosdev.local/ca/` returns 200 + body containing `href="/ca/halos-ca.mobileconfig"` and `href="/ca/halos-ca.deb"`.
- *Happy path:* The macOS section's primary install path text references "Profile" / "System Settings → Profiles"; the bare-`.crt` Keychain Access steps are still discoverable inside an "Advanced" `<details>` subsection.
- *Edge case:* If the `.mobileconfig` or `.deb` artifact is missing from `PUBLIC_CA_DIR` at request time (e.g., Phase 2 partially deployed, or `dpkg-deb` unavailable on a minimal device), the landing page still renders and the corresponding download button gracefully degrades (button disabled with a tooltip, or section falls back to the Phase 1 Advanced path). Implementer picks degradation strategy.
- *Integration:* Manual smoke test on Mac: download `.mobileconfig` via the new primary button → profile installs → trust toggle → green lock everywhere. Bare-`.crt` flow still works via the Advanced subsection.
- *Integration:* Manual smoke test on Debian: download `.deb` → double-click → install → green lock everywhere.

**Verification:** A reviewer opening `https://halosdev.local/ca/` on macOS sees the profile-based install path as the primary recommendation, completes it in fewer clicks than Phase 1, and observes green lock everywhere on the dashboard. The bare-`.crt` Keychain Access path remains accessible for users who want it. Same shape verified on iOS and Debian.

## System-Wide Impact

```mermaid
graph LR
  A[halos-manage-certs.service] --> B[lib-ca.sh helpers]
  B --> C[PUBLIC_CA_DIR/]
  C --> D[ca-download sidecar]
  D --> E[/ca/ landing page]
  D --> F[/ca/halos-ca.crt]
  D --> G[/ca/halos-ca.mobileconfig]
  D --> H[/ca/halos-ca.deb]
  I[halos-core-containers package] --> J[webapps.d/halos-ca-install.toml]
  J --> K[homarr-container-adapter sync]
  K --> L[Homarr dashboard tile]
  L --> E
  M[docs/CERTS.md] --> F
  N[docs.halos.fi/trust] --> E
```

- **Interaction graph:** Phase 1 does not touch `halos-manage-certs` — the cert publish chain is unchanged, still writing only `halos-ca.crt`. Phase 2 adds two new publish helpers (`.mobileconfig`, `.deb`) with aux-failure semantics that log WARN and continue — never abort cert management.
- **Error propagation:** Each Phase 2 publish helper is failure-isolated. A bad `dpkg-deb` invocation does not block the `.mobileconfig` publish, and neither blocks the leaf signing. Mirrors the existing `halos_cockpit_install_leaf` aux-failure pattern.
- **State lifecycle risks:** `PUBLIC_CA_DIR` is written by one publisher in Phase 1, three in Phase 2. All use atomic `<tmp>` + `mv` — no risk of nginx serving a half-written file. On rotation in Phase 2, all three artifacts update; clients downloading mid-rotation get either the old or new version, never a mix.
- **API surface parity:** External "API" here is the set of public URLs (`/ca/`, `/ca/halos-ca.crt` in Phase 1; plus `/ca/halos-ca.mobileconfig`, `/ca/halos-ca.deb` in Phase 2) and the `webapps.d` schema (unchanged — we use existing fields). All URLs documented in `docs/CERTS.md`. `/halos-ca.crt` is a removed URL after Phase 1 Unit 1 — operators with cached references see 410 with a `Link` hint.
- **Integration coverage:** Phase 1 integration tests: (a) landing page renders correctly on all 5 target OSes, (b) Homarr dashboard tile appears after adapter sync. Phase 2 adds: (c) macOS profile-install round-trip, (d) Debian `.deb` install round-trip. None can be fully automated in CI; document the manual procedure in each unit's verification block.
- **Unchanged invariants:** The cert-management state machine in `halos-manage-certs` (sentinel comparison, leaf-needs-renewal check, Traefik touch on rotation) is not modified at any point. The leaf-signing path is not modified. The Cockpit override mechanism is not modified. The Phase 2 helpers are pure additions to the publish step.

## Risks & Dependencies

| Risk | Phase | Mitigation |
|------|-------|------------|
| Landing page accumulates screenshots that diverge from current macOS/iOS/Android UI | 1 | Document the screenshot refresh procedure in `docs/CERTS.md`. Plan a periodic refresh task; out of scope for individual PRs. |
| `webapps.d` TOML schema drift in homarr-container-adapter | 1 | Adapter is in a sibling repo; schema change would break the tile. Mitigation: pin to current schema fields (`name`, `url`, `icon_url`, `[layout]`) — all supported since 2026-04 (well established). |
| Inadequate install rate even with the landing page | 1 | Iterate on copy and screenshots in follow-up PRs based on observed usage. The Phase 2 installer-artifact path is the next-tier mitigation. |
| macOS Sequoia/iOS trust-toggle behavior changes again | 1 + 2 | Landing page links to Apple's support article as the source of truth; doc stays correct if the toggle step is removed in a future macOS update. Re-verify install flow each macOS major release. |
| Brave/Chrome policy change disables manually-installed CAs entirely | 1 + 2 | Out of our control. If it happens, the regression returns; we'd need to revisit via real public-CA (Let's Encrypt) workflow. Out of scope. |
| `dpkg-deb` unavailable on minimal Debian device images | 2 | Aux-failure semantics: `.deb` generation skipped with WARN; rest of the flow unaffected. Operators on minimal images still have `.crt` + `.mobileconfig`. Decide in Unit 6 whether to add `dpkg-dev` to `halos-core-containers`'s `Depends`. |
| Hostname embedded in `.mobileconfig` becomes stale (operator renames device) | 2 | `halos-manage-certs` re-runs on every boot and timer fire. Sentinel-driven re-publish picks up hostname changes within 24h or one reboot. If immediacy matters, operators can `systemctl restart halos-manage-certs.service`. |

## Documentation / Operational Notes

- **Release notes call-out:** This PR moves a public-URL endpoint. The HaLOS `AGENTS.md` requires release-notes call-outs for canonical-URL changes. Add a "Release notes" heading to the PR description listing the URL move from `/halos-ca.crt` to `/ca/halos-ca.crt`.
- **Authelia/OIDC impact:** None — the `/ca/` endpoint is public by design (chicken-and-egg), inheriting the existing `/halos-ca.crt` unauth posture.
- **Monitoring:** The existing ca-download container healthcheck updates to probe `/ca/halos-ca.crt` (Unit 1). No new monitoring required.
- **Rollout:** No flags needed. New artifacts appear at the next `halos-manage-certs` run after the package upgrade. Existing operators with the old `/halos-ca.crt` cached get 410 with a hint header.
- **VERSION bump:** Per HaLOS AGENTS.md, VERSION bumps are per release cycle, not per PR. CI auto-increments `+N` on tag. This work spans multiple PRs; only bump VERSION when opening the next release cycle.

## Sources & References

- **Umbrella issue:** [halos-org/halos-core-containers#159](https://github.com/halos-org/halos-core-containers/issues/159)
- **Related (independent):** [halos-org/halos-core-containers#158](https://github.com/halos-org/halos-core-containers/issues/158) — device-self-trust
- **Origin PRs (context for the regression):** #142 (extract cert management), #136 (`/halos-ca.crt` endpoint), #138 (endpoint bugfix), #148 (Traefik leaf-reload)
- **Apple Configuration Profile Reference** — `com.apple.security.root` payload schema
- **Apple Support [HT102390](https://support.apple.com/en-us/102390)** — iOS Certificate Trust Settings
- **Apple Developer Forums [#724327](https://developer.apple.com/forums/thread/724327)**, **mitmproxy [#7194](https://github.com/mitmproxy/mitmproxy/discussions/7194)** — macOS Sequoia trust-toggle change
- **Debian Policy Manual §5.6.7, §6.5** — postinst conventions
- **`docs/solutions/2026-05-24-set-e-cmdsubst-blind-spot.md`** — bash `set -e` + command substitution learning
- **`docs/solutions/2026-05-25-openssl-text-grep-defeated-by-subject-dn.md`** — openssl parsing learning
- **Internal exploration findings** captured in this session: webapps.d schema, ca-download sidecar shape, artifact publish chain, Homarr-adapter sync behavior
