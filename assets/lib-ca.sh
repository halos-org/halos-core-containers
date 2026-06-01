#!/bin/bash
# lib-ca.sh — Shared shell library for HaLOS device-CA + leaf cert management.
#
# Sourced by:
#   - /usr/lib/halos-core-containers/halos-manage-certs
#
# Provides:
#   - halos_ca_ensure_auto <dir>          generate/refresh auto-CA at <dir>/ca.{crt,key}
#   - halos_ca_fingerprint <crt>          print SHA256 fingerprint (lowercase hex, no colons)
#   - halos_ca_sign_leaf <ca-crt> <ca-key> <leaf-crt-out> <leaf-key-out> <san> <cn> [days]
#   - halos_ca_leaf_needs_renewal <leaf-crt>   true when missing/expired/within renew window
#   - halos_ca_sentinel_compose <hostnames_hash> <ca_fingerprint>
#   - halos_ca_sentinel_classify <stored>      → match-shape | legacy | unrecognized
#   - halos_ca_validate_pair <crt> <key>       validate cert/key suitable as device CA
#   - halos_ca_select_active <custom_dir> <auto_dir> <symlink_path>
#                                              pick custom-if-valid / else auto, update symlink
#   - halos_cockpit_install_leaf <leaf_crt> <leaf_key> <output_path>
#                                              install combined PEM override for cockpit-tls
#   - halos_ca_publish_public <src_crt> <public_dir>
#                                              copy active CA into a public-bindmount target
#   - halos_ca_publish_mobileconfig <src_crt> <public_dir> <display_host>
#                                              generate an Apple .mobileconfig carrying the CA
#
# Generated certs carry the extensions browsers + OS trust stores require:
#   CA   — basicConstraints CA:TRUE (so importing as trust anchor actually works),
#          keyUsage keyCertSign+cRLSign, subjectKeyIdentifier
#   leaf — basicConstraints CA:FALSE, keyUsage digitalSignature+keyEncipherment,
#          extendedKeyUsage serverAuth (Chrome requires this), subjectAltName
#
# notBefore on both CA and leaf is backdated 24h to absorb mild first-boot clock
# skew. For severe clock drift (dead RTC, decades-old timestamp) the CA's notAfter
# would also be implausibly early, so halos_ca_ensure_auto rotates the CA when it
# detects an expired or implausibly-aged cert; this lets a device that booted with
# a bad clock self-heal after NTP recovers.

# Tuning (constants, not env-overridable — keep the surface tight) -----------
#
# Naming convention:
#   *_VALIDITY_DAYS   — lifetime stamped into the cert at signing time
#   *_THRESHOLD_DAYS  — remaining-validity gate that triggers an action
#                       (regenerate / renew / reject / warn)

# --- Validity (lifetime at signing time) ---

HALOS_CA_VALIDITY_DAYS=7300       # 20 years

# Leaf validity. Capped at 825 days because Apple's Secure Transport rejects
# SSL server certs with longer validity (CA/B Forum baseline + Apple policy
# since 2019-07-01), regardless of whether the root is publicly trusted or
# user-installed. Affects Safari, Chrome/Brave/Edge, /usr/bin/curl, nscurl,
# and every macOS app using SecTrustEvaluate. Linux/Windows don't enforce
# this, but the 825-day ceiling is the binding constraint.
# Reference: https://support.apple.com/en-us/103769
#
# Set to 824, not 825: openssl's `-days N` with an explicit -not_before
# yields notAfter - notBefore = (N+1) days (inclusive count). Empirically
# verified — 825 produces 826-day certs that Apple rejects. The 1-day
# headroom keeps us safely at-but-not-over the ceiling.
HALOS_CA_LEAF_VALIDITY_DAYS=824

HALOS_CA_BACKDATE_HOURS=24
HALOS_CA_SUBJECT="/CN=HaLOS Device CA"

# Subject-CN prefix shared by the auto-CA's bare-legacy CN ("HaLOS Device CA")
# and its device-identifying form ("HaLOS Device CA (<hostname>)"). Used to
# classify a sentinel-less auto-CA at adoption-init time.
HALOS_CA_SUBJECT_CN_PREFIX="HaLOS Device CA"

# uid:gid the ca-download sidecar's busybox httpd drops to after binding :80
# (docker-compose `httpd -u`). The adoption sentinel is chowned to this uid by
# the cert-manager so the in-container CGI can rewrite it. 65534 = nobody.
# Keep in sync with the `-u` value in docker-compose.yml's ca-download service.
# shellcheck disable=SC2034  # consumed by halos-manage-certs, which sources this lib
HALOS_CA_DOWNLOAD_UID=65534

# --- Thresholds (remaining-validity gates for actions) ---

# Re-sign the leaf when remaining validity drops below this. Sized so
# operators have generous runway (~7% of leaf lifetime); any reboot during
# the window triggers transparent renewal. The CA stays trusted across leaf
# rotation because the same CA signs the new leaf — installed trust anchors
# do NOT need to be re-installed (the CA itself is valid for
# HALOS_CA_VALIDITY_DAYS).
HALOS_CA_LEAF_RENEW_THRESHOLD_DAYS=60

# Regenerate the auto-CA when its remaining validity drops below this.
# Despite the threshold being set well below the 20-year validity, the
# realistic trigger is NOT natural aging — that branch never fires within
# any plausible device lifetime.
#
# The actual purpose is clock-skew self-heal. Raspberry Pi hardware has no
# RTC; first boot starts with system time = whatever /etc/fake-hwclock.data
# last saved (often 1970, or the timestamp of the most recent build). If
# prestart signs the auto-CA at that point, notBefore and notAfter are both
# wrong by years. When NTP later corrects the clock, the cert appears
# already expired (or expiring soon), this check fires, and the next
# prestart regenerates with correct dates. Without this, a Pi that booted
# before NTP would ship a permanently-broken CA until manual recovery.
#
# Same mechanism also covers half-deleted CA files, disk corruption, and
# any other "cert exists on disk but is unusable" state. Operators who
# installed the auto-CA into their trust store will see it become invalid
# when this fires — accepted trade-off for the self-heal property (custom
# CAs, by contrast, are never auto-regenerated for exactly this reason).
HALOS_CA_AUTO_REGEN_THRESHOLD_DAYS=365

# Custom (operator-supplied) CA acceptance thresholds. Operators may
# deliberately ship short-lived intermediates, so REJECT is lower than the
# auto-CA regen threshold — we don't want to reject a valid 6-month CA on
# arrival. WARN gives operators a documented runway to rotate before
# hitting the REJECT cliff. Unlike the auto-CA, custom CAs are never
# auto-regenerated; operator owns rotation (silent regen would orphan the
# trust anchors they distributed to a fleet).
HALOS_CA_CUSTOM_REJECT_THRESHOLD_DAYS=30
HALOS_CA_CUSTOM_WARN_THRESHOLD_DAYS=90

# Internal -------------------------------------------------------------------

_halos_ca_not_before() {
    local epoch
    epoch=$(date -u +%s)
    epoch=$((epoch - HALOS_CA_BACKDATE_HOURS * 3600))
    # Portable across GNU and BSD date: GNU's `-d @epoch` then BSD's `-r epoch`.
    date -u -d "@${epoch}" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "${epoch}" +%Y%m%d%H%M%SZ
}

# Random 128-bit positive serial as `openssl x509 -set_serial` value. Stateless —
# avoids the .srl file `-CAcreateserial` would create alongside the CA.
_halos_ca_random_serial() {
    printf '0x%s' "$(openssl rand -hex 16)"
}

# Public ---------------------------------------------------------------------

# halos_ca_sentinel_compose <hostnames_hash> <ca_fingerprint>
# Canonical sentinel string: "<hostnames_hash>:<ca_fingerprint>". Both args
# must be lowercase hex (64 chars each); the caller is responsible.
halos_ca_sentinel_compose() {
    printf '%s:%s' "$1" "$2"
}

# halos_ca_sentinel_classify <stored>
# Echoes exactly one of:
#   match-shape  — stored is current sentinel format (64hex:64hex)
#   legacy       — stored is pre-CA-fingerprint format (64hex)
#   unrecognized — empty, corrupt, or any other content
halos_ca_sentinel_classify() {
    local stored="$1"
    if [[ "$stored" =~ ^[0-9a-f]{64}:[0-9a-f]{64}$ ]]; then
        echo "match-shape"
    elif [[ "$stored" =~ ^[0-9a-f]{64}$ ]]; then
        echo "legacy"
    else
        echo "unrecognized"
    fi
}

# halos_ca_fingerprint <crt_path>
# Prints SHA256 fingerprint as lowercase hex (no colons). Returns non-zero and
# emits nothing on stdout if the cert cannot be parsed — so callers using
# `var=$(halos_ca_fingerprint ...)` can rely on `set -e` plus `|| exit` to
# catch corruption rather than silently propagating an empty fingerprint.
halos_ca_fingerprint() {
    local crt="$1"
    if [ -z "$crt" ] || [ ! -f "$crt" ]; then
        echo "halos_ca_fingerprint: cert path required and must exist" >&2
        return 1
    fi
    local raw fp
    if ! raw=$(openssl x509 -in "$crt" -noout -fingerprint -sha256 2>/dev/null); then
        echo "halos_ca_fingerprint: openssl x509 failed parsing $crt" >&2
        return 1
    fi
    fp=$(printf '%s\n' "$raw" | sed -e 's/^.*Fingerprint=//' -e 's/://g' | tr '[:upper:]' '[:lower:]')
    if ! [[ "$fp" =~ ^[0-9a-f]{64}$ ]]; then
        echo "halos_ca_fingerprint: openssl produced unexpected output for $crt" >&2
        return 1
    fi
    printf '%s' "$fp"
}

# _halos_ca_is_healthy <crt_path> [min_remaining_days]
# Returns 0 if the cert parses, hasn't expired, and has at least
# <min_remaining_days> of validity left. <min_remaining_days> defaults to
# HALOS_CA_AUTO_REGEN_THRESHOLD_DAYS — the auto-CA regen gate, which is
# this function's original (and most frequent) call site. Other consumers
# pass an explicit threshold: custom-CA acceptance uses
# HALOS_CA_CUSTOM_REJECT_THRESHOLD_DAYS; leaf-renewal checks pass
# HALOS_CA_LEAF_RENEW_THRESHOLD_DAYS via halos_ca_leaf_needs_renewal.
_halos_ca_is_healthy() {
    local crt="$1"
    local min_remaining_days="${2:-$HALOS_CA_AUTO_REGEN_THRESHOLD_DAYS}"
    [ -f "$crt" ] || return 1
    # -checkend N: returns 0 if cert expires more than N seconds in the future.
    local horizon=$((min_remaining_days * 86400))
    openssl x509 -in "$crt" -noout -checkend "$horizon" >/dev/null 2>&1
}

# halos_ca_leaf_needs_renewal <crt_path>
# Returns 0 (true) if the leaf at <crt_path> is missing, expired, or has
# fewer than HALOS_CA_LEAF_RENEW_THRESHOLD_DAYS of validity remaining;
# returns 1 (false) when the leaf is still healthy. Used by prestart.sh
# to force a re-sign independent of the hostname/CA-fingerprint sentinel,
# so an unchanged-config device still rotates its leaf before Apple's
# 825-day ceiling expires the cert.
halos_ca_leaf_needs_renewal() {
    local crt="$1"
    [ -f "$crt" ] || return 0
    # Inverted predicate: _halos_ca_is_healthy returns 0 when there's at
    # least the requested headroom; we want "needs renewal" = "not healthy".
    if _halos_ca_is_healthy "$crt" "$HALOS_CA_LEAF_RENEW_THRESHOLD_DAYS"; then
        return 1
    fi
    return 0
}

# halos_ca_ensure_auto <output_dir>
# Guarantees a healthy CA at <output_dir>/ca.{crt,key}, regenerating only when
# necessary. Three on-disk states are handled:
#   1. Both files present, cert is healthy   → no-op (return 0)
#   2. Both files present, cert is unhealthy → rotate (log loud, regenerate)
#   3. Neither file present                  → bootstrap (first boot)
#   4. Exactly one file present              → FAIL LOUD, return 1
# State (4) is treated as caller error because silently regenerating from a
# half-deleted CA would orphan any operator-installed trust anchor whose
# matching key is still present. Operators must explicitly delete both files
# (or none) for the regen escape hatch to fire.
#
# Sets HALOS_CA_AUTO_CREATED on return: "1" when this call bootstrapped or
# rotated the CA (a brand-new key/cert is now on disk), "0" when an existing
# healthy CA was reused unchanged. Read by halos_ca_adoption_init to decide a
# sentinel-less CA's initial state — a CA born this run starts "pending"
# (refresh-eligible), a pre-existing one is classified by its CN.
#
# <hostname> (optional) makes the subject CN device-identifying:
# "HaLOS Device CA (<hostname>)" so devices are distinguishable in trust stores.
# Omitted/empty yields the bare legacy CN; callers that don't care (tests) can
# keep the one-arg form. Only affects a CA this call generates — an existing
# healthy CA is reused with whatever CN it already has.
halos_ca_ensure_auto() {
    local out_dir="$1" hostname="${2:-}"
    # shellcheck disable=SC2034
    HALOS_CA_AUTO_CREATED=0
    if [ -z "$out_dir" ]; then
        echo "halos_ca_ensure_auto: output_dir required" >&2
        return 2
    fi
    mkdir -p "$out_dir"
    # Tighten directory mode regardless of whether mkdir just created it or it
    # already existed — defense-in-depth so any other files placed alongside
    # the CA key (future intermediate exports etc) are not reachable by other
    # local UIDs.
    chmod 700 "$out_dir"
    local ca_crt="${out_dir}/ca.crt"
    local ca_key="${out_dir}/ca.key"

    local crt_present=0 key_present=0
    [ -f "$ca_crt" ] && crt_present=1
    [ -f "$ca_key" ] && key_present=1

    if [ "$crt_present" -eq 1 ] && [ "$key_present" -eq 1 ]; then
        if _halos_ca_is_healthy "$ca_crt"; then
            return 0
        fi
        echo "halos_ca_ensure_auto: NOTICE: existing CA at $ca_crt is expired or implausibly aged; rotating. Any previously-distributed trust anchor will need to be reinstalled by operators." >&2
    elif [ "$crt_present" -ne "$key_present" ]; then
        echo "halos_ca_ensure_auto: partial CA state ($([ "$crt_present" -eq 1 ] && echo "ca.crt present, ca.key missing" || echo "ca.key present, ca.crt missing")). Refusing to silently regenerate — delete both files to opt into rotation." >&2
        return 1
    fi
    # else: neither present → first-boot bootstrap

    local ca_crt_new="${ca_crt}.new"
    local ca_key_new="${ca_key}.new"
    local not_before
    not_before=$(_halos_ca_not_before)

    # Device-identifying subject CN when a hostname is supplied; bare legacy CN
    # otherwise. The parenthetical form matches the .mobileconfig display string.
    local subject="$HALOS_CA_SUBJECT"
    [ -n "$hostname" ] && subject="/CN=${HALOS_CA_SUBJECT_CN_PREFIX} (${hostname})"

    # umask 077 ensures the openssl-created key file is 0600 from inception,
    # closing the race window between cert creation and chmod where another
    # local UID could open the key fd while it was world-readable.
    if ! ( umask 077 && openssl req -x509 -nodes -newkey rsa:4096 \
            -days "$HALOS_CA_VALIDITY_DAYS" \
            -not_before "$not_before" \
            -keyout "$ca_key_new" \
            -out "$ca_crt_new" \
            -subj "$subject" \
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" \
            -addext "subjectKeyIdentifier=hash" \
            >/dev/null 2>&1 ); then
        rm -f "$ca_crt_new" "$ca_key_new"
        echo "halos_ca_ensure_auto: openssl req failed generating CA" >&2
        return 1
    fi

    chmod 600 "$ca_key_new"
    chmod 644 "$ca_crt_new"
    mv "$ca_key_new" "$ca_key"
    mv "$ca_crt_new" "$ca_crt"
    # shellcheck disable=SC2034
    HALOS_CA_AUTO_CREATED=1
}

# halos_ca_validate_pair <ca_crt> <ca_key>
# Returns 0 if the pair is a valid, healthy CA suitable for signing leaves:
#   - both files parse
#   - cert has basicConstraints CA:TRUE
#   - cert has keyUsage keyCertSign
#   - cert is not expired and has plausible remaining lifetime
#   - key parses as a private key
#   - key matches cert (derived public keys agree)
# Returns 1 otherwise with a specific diagnostic on stderr. Used to gate
# operator-supplied custom CAs before treating them as the active CA.
halos_ca_validate_pair() {
    local crt="$1" key="$2"
    if [ -z "$crt" ] || [ -z "$key" ]; then
        echo "halos_ca_validate_pair: <crt> <key> both required" >&2
        return 2
    fi
    [ -f "$crt" ] || { echo "halos_ca_validate_pair: cert missing: $crt" >&2; return 1; }
    [ -f "$key" ] || { echo "halos_ca_validate_pair: key missing: $key" >&2; return 1; }

    # Parse check — discards output, just confirms the cert is well-formed.
    if ! openssl x509 -in "$crt" -noout 2>/dev/null; then
        echo "halos_ca_validate_pair: cert at $crt does not parse" >&2
        return 1
    fi
    # Scoped extension checks. `-ext <name>` emits ONLY the named extension's
    # body, not the full -text dump, so the grep can't false-positive on a
    # Subject/Issuer DN that happens to contain "CA:TRUE" or "Certificate Sign".
    # Requires OpenSSL 1.1.1+ (well below the Debian trixie baseline of 3.5).
    if ! openssl x509 -in "$crt" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE'; then
        echo "halos_ca_validate_pair: cert at $crt lacks basicConstraints CA:TRUE" >&2
        return 1
    fi
    if ! openssl x509 -in "$crt" -noout -ext keyUsage 2>/dev/null | grep -q 'Certificate Sign'; then
        echo "halos_ca_validate_pair: cert at $crt lacks keyUsage keyCertSign" >&2
        return 1
    fi
    # Hard floor: refuse certs below the custom-CA minimum remaining validity.
    if ! _halos_ca_is_healthy "$crt" "$HALOS_CA_CUSTOM_REJECT_THRESHOLD_DAYS"; then
        echo "halos_ca_validate_pair: cert at $crt is expired or has under ${HALOS_CA_CUSTOM_REJECT_THRESHOLD_DAYS}d remaining validity (hard floor for custom CAs)" >&2
        return 1
    fi
    # Soft warning: log but pass validation if remaining is below the warn
    # window. Gives operators a documented runway to rotate before the cliff.
    if ! _halos_ca_is_healthy "$crt" "$HALOS_CA_CUSTOM_WARN_THRESHOLD_DAYS"; then
        echo "halos_ca_validate_pair: WARNING: cert at $crt has under ${HALOS_CA_CUSTOM_WARN_THRESHOLD_DAYS}d remaining validity; rotate before it falls below the ${HALOS_CA_CUSTOM_REJECT_THRESHOLD_DAYS}d hard floor" >&2
    fi
    if ! openssl pkey -in "$key" -noout 2>/dev/null; then
        echo "halos_ca_validate_pair: key at $key does not parse as a private key" >&2
        return 1
    fi
    local crt_pub key_pub
    crt_pub=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null) \
        || { echo "halos_ca_validate_pair: failed to extract public key from cert $crt" >&2; return 1; }
    key_pub=$(openssl pkey -in "$key" -pubout 2>/dev/null) \
        || { echo "halos_ca_validate_pair: failed to derive public key from $key" >&2; return 1; }
    if [ "$crt_pub" != "$key_pub" ]; then
        echo "halos_ca_validate_pair: key at $key does not match cert at $crt" >&2
        return 1
    fi
}

# halos_ca_select_active <custom_dir> <auto_dir> <symlink_path> [hostname]
# Picks the active device CA: operator-supplied custom (when present + valid)
# wins; otherwise the auto-CA at <auto_dir> is ensured and used. Updates
# <symlink_path> to point at the active cert (atomic via `ln -sfn`).
#
# [hostname] is threaded to the auto branch only, so a freshly generated
# auto-CA carries a device-identifying CN. Custom CAs are never touched — the
# operator owns their CN.
#
# Sets globals on success:
#   HALOS_CA_ACTIVE_CRT   path to active CA cert
#   HALOS_CA_ACTIVE_KEY   path to active CA key (matched to cert)
#   HALOS_CA_ACTIVE_MODE  "custom" or "auto"
#
# Returns:
#   0 — success
#   1 — custom CA present but partial / invalid (operator must fix or remove;
#       NO silent fallback to auto)
#   non-zero — auto-CA generation failure propagated from halos_ca_ensure_auto
#
# The fail-loud-on-broken-custom policy is deliberate: operators capable of
# dropping a custom CA can SSH to diagnose, and silent fallback would
# invalidate their installed trust anchor without warning.
halos_ca_select_active() {
    local custom_dir="$1" auto_dir="$2" symlink_path="$3" hostname="${4:-}"
    if [ -z "$custom_dir" ] || [ -z "$auto_dir" ] || [ -z "$symlink_path" ]; then
        echo "halos_ca_select_active: <custom_dir> <auto_dir> <symlink_path> all required" >&2
        return 2
    fi

    local custom_crt="${custom_dir}/ca.crt"
    local custom_key="${custom_dir}/ca.key"
    local crt_present=0 key_present=0
    [ -f "$custom_crt" ] && crt_present=1
    [ -f "$custom_key" ] && key_present=1

    # Decide active CA into LOCAL vars first; only promote to HALOS_CA_ACTIVE_*
    # globals after the symlink update succeeds. Keeps the invariant "globals
    # set ⇒ on-disk symlink agrees" — a failed ln/mv leaves both unchanged.
    local active_crt active_key active_mode
    if [ "$crt_present" -eq 1 ] || [ "$key_present" -eq 1 ]; then
        # Operator installed a custom CA. Both files must be present AND the
        # pair must validate; otherwise fail loud rather than fall back.
        if [ "$crt_present" -ne 1 ] || [ "$key_present" -ne 1 ]; then
            echo "halos_ca_select_active: partial custom CA at $custom_dir (expected both ca.crt and ca.key). Refusing to fall back to auto-CA — fix or remove the partial files." >&2
            return 1
        fi
        # Defense-in-depth: re-tighten the drop slot to 0700 on every prestart
        # so an operator who widened it (e.g., debugging) doesn't leave the
        # private key world-traversable indefinitely. Mirrors what
        # halos_ca_ensure_auto does for the auto-CA directory. Tolerate
        # failure (returns true) so a read-only dir doesn't block startup.
        chmod 0700 "$custom_dir" 2>/dev/null || true
        if ! halos_ca_validate_pair "$custom_crt" "$custom_key"; then
            echo "halos_ca_select_active: custom CA at $custom_dir failed validation; refusing to fall back to auto-CA. Fix or remove the broken files." >&2
            return 1
        fi
        active_crt="$custom_crt"
        active_key="$custom_key"
        active_mode="custom"
    else
        halos_ca_ensure_auto "$auto_dir" "$hostname" || return $?
        active_crt="${auto_dir}/ca.crt"
        active_key="${auto_dir}/ca.key"
        active_mode="auto"
    fi

    # Atomic symlink replacement on the same filesystem: create the new
    # symlink at a sibling temp path, then rename(2) over the target. Plain
    # `ln -sfn` is unlink(target) + symlink(target), which leaves a brief
    # window where the target does not exist — a future consumer reading
    # serving-ca.crt could ENOENT. mv -Tf (GNU mv: --no-target-directory)
    # uses rename(2) for the swap. mv is GNU on Debian targets; macOS dev
    # falls back to ln -sfn via the `||` short-circuit below since BSD mv
    # lacks -T (the non-atomic path is acceptable for local dev/tests).
    mkdir -p "$(dirname "$symlink_path")"
    local tmp_link="${symlink_path}.new"
    ln -sfn "$active_crt" "$tmp_link" || return 1
    if ! mv -Tf "$tmp_link" "$symlink_path" 2>/dev/null; then
        # BSD mv (macOS) lacks -T; fall back to non-atomic update for dev/test
        # parity. Production target is GNU mv on Debian where mv -T succeeds.
        rm -f "$tmp_link"
        ln -sfn "$active_crt" "$symlink_path" || return 1
    fi

    # Symlink committed — now publish to the caller via globals.
    # HALOS_CA_ACTIVE_{CRT,KEY,MODE} are read by callers (prestart.sh) — match
    # the lib-hostnames.sh convention of exposing parsed state via globals.
    # shellcheck disable=SC2034
    HALOS_CA_ACTIVE_CRT="$active_crt"
    # shellcheck disable=SC2034
    HALOS_CA_ACTIVE_KEY="$active_key"
    # shellcheck disable=SC2034
    HALOS_CA_ACTIVE_MODE="$active_mode"
}

# halos_ca_sign_leaf <ca_crt> <ca_key> <leaf_crt_out> <leaf_key_out> <san> <cn> [days]
# Generates a fresh leaf key + cert signed by the given CA.
# SAN format: openssl-compatible list, e.g. "DNS:device.local,DNS:device.lan,IP:10.0.0.5".
# Writes leaf_key first then leaf_crt (atomic on Linux); Traefik tolerates the
# brief key-without-matching-cert window better than the inverse.
#
# [days] defaults to HALOS_CA_LEAF_VALIDITY_DAYS (824), capped to stay under
# Apple Secure Transport's 825-day SSL cert ceiling. Callers that need a
# different validity (tests, future tooling) may pass an explicit value, but
# anything above 825 will be rejected by macOS/iOS clients regardless of
# trust-anchor source. See the HALOS_CA_LEAF_VALIDITY_DAYS comment above.
#
# Failure semantics: on any openssl error, leaves the pre-existing leaf_crt /
# leaf_key untouched, cleans up .new files, returns non-zero. The CALLER is
# responsible for invalidating any cert-tracking sentinel BEFORE invoking this
# function (so a failed sign won't be silently skipped on next boot due to a
# stale "everything matches" sentinel).
halos_ca_sign_leaf() {
    local ca_crt="$1" ca_key="$2" leaf_crt="$3" leaf_key="$4" san="$5" cn="$6"
    local days="${7:-$HALOS_CA_LEAF_VALIDITY_DAYS}"

    if [ -z "$ca_crt" ] || [ -z "$ca_key" ] || [ -z "$leaf_crt" ] || \
       [ -z "$leaf_key" ] || [ -z "$san" ] || [ -z "$cn" ]; then
        echo "halos_ca_sign_leaf: <ca_crt> <ca_key> <leaf_crt> <leaf_key> <san> <cn> all required" >&2
        return 2
    fi
    if [ ! -f "$ca_crt" ] || [ ! -f "$ca_key" ]; then
        echo "halos_ca_sign_leaf: CA cert/key missing ($ca_crt, $ca_key)" >&2
        return 1
    fi

    # Compute timestamp + serial before allocating tempfiles so a date(1) /
    # openssl-rand failure under set -e can't leak csr_tmp / ext_tmp.
    local not_before serial
    not_before=$(_halos_ca_not_before)
    serial=$(_halos_ca_random_serial)

    local leaf_key_new="${leaf_key}.new"
    local leaf_crt_new="${leaf_crt}.new"
    local csr_tmp ext_tmp
    csr_tmp="$(mktemp)"
    ext_tmp="$(mktemp)"
    local rc=0

    # umask 077: openssl req creates leaf_key_new with mode 0600 from
    # inception, closing the same race window as the CA path above.
    if ! ( umask 077 && openssl req -nodes -newkey rsa:2048 \
            -keyout "$leaf_key_new" \
            -out "$csr_tmp" \
            -subj "/CN=${cn}" \
            >/dev/null 2>&1 ); then
        echo "halos_ca_sign_leaf: openssl req failed generating leaf key/CSR" >&2
        rc=1
    fi

    if [ "$rc" -eq 0 ]; then
        cat > "$ext_tmp" << EOF
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
subjectAltName = ${san}
EOF
        # Random 128-bit serial via -set_serial — stateless, avoids the .srl
        # sidecar file that -CAcreateserial would create alongside the CA cert
        # (which has no clean recovery path if corrupted).
        if ! openssl x509 -req \
                -in "$csr_tmp" \
                -CA "$ca_crt" -CAkey "$ca_key" -set_serial "$serial" \
                -out "$leaf_crt_new" \
                -days "$days" \
                -not_before "$not_before" \
                -extfile "$ext_tmp" \
                -sha256 \
                >/dev/null 2>&1; then
            echo "halos_ca_sign_leaf: openssl x509 -req failed signing leaf" >&2
            rc=1
        fi
    fi

    rm -f "$csr_tmp" "$ext_tmp"

    if [ "$rc" -ne 0 ]; then
        rm -f "$leaf_key_new" "$leaf_crt_new"
        return "$rc"
    fi

    chmod 600 "$leaf_key_new"
    chmod 644 "$leaf_crt_new"
    mv "$leaf_key_new" "$leaf_key"
    mv "$leaf_crt_new" "$leaf_crt"
}

# halos_cockpit_install_leaf <leaf_crt> <leaf_key> <output_path>
# Writes the concatenated PEM (leaf cert + leaf key) to <output_path>, atomically
# via a .new sibling + mv. Installed at /etc/cockpit/ws-certs.d/99-halos.cert by
# prestart so cockpit-tls (which picks the lex-last *.cert file at socket
# activation) serves the same leaf as Traefik. The upstream 0-self-signed.cert
# generated by cockpit-certificate-ensure stays in place as the safety-net
# floor — removing the 99- override reverts to upstream-generated self-signed.
#
# Validation: parses the resulting file as a cert + a private key and confirms
# the key matches the cert via -pubout comparison. Cannot reuse
# halos_ca_validate_pair because that one requires CA:TRUE, which a leaf lacks.
#
# Permissions: mode 0640, group cockpit-ws when that group exists on the host
# (so cockpit-tls running under the cockpit-ws group can read the key). When
# the group is absent (cockpit-ws not installed yet, install-order variance),
# logs a NOTICE and leaves ownership as root:root.
#
# Failure semantics: on any validation failure leaves the pre-existing
# <output_path> untouched, removes the .new sibling, returns non-zero.
#
# Return codes:
#   0 — success
#   1 — runtime failure (missing source files, parse/key-match failure, write error)
#   2 — caller bug (missing args)
halos_cockpit_install_leaf() {
    local leaf_crt="$1" leaf_key="$2" out_path="$3"
    if [ -z "$leaf_crt" ] || [ -z "$leaf_key" ] || [ -z "$out_path" ]; then
        echo "halos_cockpit_install_leaf: <leaf_crt> <leaf_key> <output_path> all required" >&2
        return 2
    fi
    if [ ! -f "$leaf_crt" ]; then
        echo "halos_cockpit_install_leaf: leaf cert missing: $leaf_crt" >&2
        return 1
    fi
    if [ ! -f "$leaf_key" ]; then
        echo "halos_cockpit_install_leaf: leaf key missing: $leaf_key" >&2
        return 1
    fi

    # PID-suffixed stage name so concurrent prestart invocations (e.g., a manual
    # `bash prestart.sh` overlapping with a systemd run) don't trample each
    # other's in-flight `.new` file. The mv into out_path is still atomic per
    # caller, and per-call cleanup catches our own debris.
    local out_new="${out_path}.new.$$"
    # Defense-in-depth against a pre-existing symlink at the stage path: rm
    # before the cat redirection so `>` does not follow a symlink and write
    # the leaf private key to an attacker-chosen target. rm -f unlinks
    # symlinks without following them.
    rm -f "$out_new"

    # umask 077 so the temp file containing the private key is never world-
    # readable, even briefly between creation and the final chmod 0640.
    if ! ( umask 077 && cat "$leaf_crt" "$leaf_key" > "$out_new" ); then
        rm -f "$out_new"
        echo "halos_cockpit_install_leaf: failed to write combined PEM to $out_new" >&2
        return 1
    fi

    # Validate the freshly-written file (not the inputs) so corrupt-concat
    # and short-write tearing are caught alongside parse/key-match failures.
    # Mirrors the halos_ca_validate_pair key-match technique (inlined here
    # because that helper additionally demands CA:TRUE, which fails on a leaf).
    if ! openssl x509 -in "$out_new" -noout 2>/dev/null; then
        rm -f "$out_new"
        echo "halos_cockpit_install_leaf: combined PEM does not parse as a certificate" >&2
        return 1
    fi
    if ! openssl pkey -in "$out_new" -noout 2>/dev/null; then
        rm -f "$out_new"
        echo "halos_cockpit_install_leaf: combined PEM does not parse as a private key" >&2
        return 1
    fi
    local crt_pub key_pub
    crt_pub=$(openssl x509 -in "$out_new" -noout -pubkey 2>/dev/null) || {
        rm -f "$out_new"
        echo "halos_cockpit_install_leaf: failed to extract public key from combined PEM cert" >&2
        return 1
    }
    key_pub=$(openssl pkey -in "$out_new" -pubout 2>/dev/null) || {
        rm -f "$out_new"
        echo "halos_cockpit_install_leaf: failed to derive public key from combined PEM key" >&2
        return 1
    }
    if [ "$crt_pub" != "$key_pub" ]; then
        rm -f "$out_new"
        echo "halos_cockpit_install_leaf: leaf key at $leaf_key does not match leaf cert at $leaf_crt" >&2
        return 1
    fi

    if ! chmod 0640 "$out_new"; then
        rm -f "$out_new"
        echo "halos_cockpit_install_leaf: chmod 0640 failed on $out_new" >&2
        return 1
    fi
    # Ownership: cockpit-tls runs under the cockpit-ws group on Debian/cockpit
    # packages. If that group exists, chown to root:cockpit-ws so cockpit-tls
    # can read the key. If not (cockpit-ws not installed, install-order race),
    # leave as root:root and log a NOTICE — cockpit-tls will pick this up on
    # the next socket activation after the cockpit-ws package install, but the
    # ownership won't auto-correct until the next prestart re-writes the file.
    if getent group cockpit-ws >/dev/null 2>&1; then
        # Treat chown failure as a hard error: the file is about to land with
        # mode 0640 root:root, which cockpit-tls (running as cockpit-ws GID)
        # cannot read. Silent success here was the original failure mode —
        # operators saw "installed" in logs while cockpit served the upstream
        # self-signed cert. Fail-loud surfaces the diagnostic instead.
        if ! chown root:cockpit-ws "$out_new"; then
            rm -f "$out_new"
            echo "halos_cockpit_install_leaf: chown root:cockpit-ws failed on $out_new despite the cockpit-ws group existing — cockpit-tls would be unable to read the key. Aborting install; previous override (if any) is preserved." >&2
            return 1
        fi
    else
        echo "halos_cockpit_install_leaf: NOTICE: cockpit-ws group not found; leaving $out_path as root:root (cockpit-tls may be unable to read the key until the next prestart after cockpit-ws is installed)" >&2
    fi

    # Refuse to install over a pre-existing directory at out_path: plain `mv`
    # in that case would move out_new INTO the directory (as <dir>/<basename>),
    # silently succeed, and leave out_path itself an unreadable-as-cert dir.
    # cockpit-tls would fall back to upstream self-signed with no clear log.
    if [ -d "$out_path" ]; then
        rm -f "$out_new"
        echo "halos_cockpit_install_leaf: refusing to install over directory at $out_path" >&2
        return 1
    fi
    if ! mv "$out_new" "$out_path"; then
        rm -f "$out_new"
        echo "halos_cockpit_install_leaf: failed to mv $out_new to $out_path; previous override (if any) is preserved" >&2
        return 1
    fi
}

# halos_ca_publish_public <src_crt> <public_dir>
# Atomically refresh a world-readable copy of <src_crt> at
# <public_dir>/halos-ca.crt, mode 0644. Used by prestart to publish the active
# CA into a bind-mount target the ca-download sidecar serves over HTTP.
#
# Why a copy and not a direct mount of the serving-ca.crt symlink:
#   1. The symlink's absolute target (e.g. /etc/halos/ca/ca.crt when a custom
#      CA is in use) does not exist inside the sidecar's mount namespace —
#      Docker resolves the symlink at mount time on the host.
#   2. The custom-CA directory ALSO holds ca.key. Mounting that directory into
#      a public-facing sidecar (even read-only) would expose the operator's
#      private key. We copy only the certificate.
#
# Mode 0644 is intentional: this file is a public trust anchor, world-readable
# is correct.
#
# Failure semantics: on any failure leaves the pre-existing public copy (if
# any) untouched, removes the .new sibling, returns non-zero.
#
# Return codes:
#   0 — success
#   1 — runtime failure (missing source, write/chmod/mv error, parse fail)
#   2 — caller bug (missing args)
halos_ca_publish_public() {
    local src_crt="$1" public_dir="$2"
    if [ -z "$src_crt" ] || [ -z "$public_dir" ]; then
        echo "halos_ca_publish_public: <src_crt> <public_dir> both required" >&2
        return 2
    fi
    if [ ! -f "$src_crt" ]; then
        echo "halos_ca_publish_public: source cert missing: $src_crt" >&2
        return 1
    fi

    if ! mkdir -p "$public_dir"; then
        echo "halos_ca_publish_public: failed to mkdir $public_dir" >&2
        return 1
    fi
    # Defense-in-depth: re-tighten the dir mode on every call so an operator
    # who narrowed it (e.g., debugging) doesn't break the bind-mount.
    chmod 0755 "$public_dir" 2>/dev/null || true

    local public_file="${public_dir}/halos-ca.crt"
    # PID-suffixed stage filename so concurrent prestart invocations don't
    # collide on the same staging path. The mv into public_file is still
    # atomic per caller.
    local public_new="${public_file}.new.$$"
    # rm before cp so `>` inside cp doesn't follow a pre-existing symlink at
    # the stage path. (cp itself doesn't follow target symlinks by default
    # for overwrite, but the per-pid name minimizes the surface anyway.)
    rm -f "$public_new"

    if ! cp "$src_crt" "$public_new"; then
        rm -f "$public_new"
        echo "halos_ca_publish_public: failed to cp $src_crt to $public_new" >&2
        return 1
    fi
    # Verify the copy parses as an X.509 cert. Catches truncation, EIO mid-
    # cp, and the case where src_crt drifted to something that isn't a cert.
    if ! openssl x509 -in "$public_new" -noout 2>/dev/null; then
        rm -f "$public_new"
        echo "halos_ca_publish_public: copied file at $public_new does not parse as an X.509 certificate" >&2
        return 1
    fi
    if ! chmod 0644 "$public_new"; then
        rm -f "$public_new"
        echo "halos_ca_publish_public: chmod 0644 failed on $public_new" >&2
        return 1
    fi
    # Refuse to install over a pre-existing directory at public_file (plain
    # mv would silently move INTO the directory).
    if [ -d "$public_file" ]; then
        rm -f "$public_new"
        echo "halos_ca_publish_public: refusing to install over directory at $public_file" >&2
        return 1
    fi
    if ! mv "$public_new" "$public_file"; then
        rm -f "$public_new"
        echo "halos_ca_publish_public: failed to mv $public_new to $public_file; previous copy (if any) is preserved" >&2
        return 1
    fi
}

# _halos_ca_subject_cn <crt_path>
# Print the subject CN of <crt_path> (empty on parse failure). RFC2253 name
# format renders a lone CN as "CN=<value>" with no spacing, so the trailing
# capture stops at the first RDN separator.
_halos_ca_subject_cn() {
    local crt="$1" subject
    [ -f "$crt" ] || return 1
    # Capture openssl separately so its failure propagates — a pipe into sed
    # would mask it behind sed's always-zero exit.
    subject="$(openssl x509 -in "$crt" -noout -subject -nameopt RFC2253 2>/dev/null)" || return 1
    printf '%s\n' "$subject" | sed -n 's/.*CN=\([^,]*\).*/\1/p'
}

# halos_ca_cn_hostname <crt_path>
# Print the hostname embedded in a device-identifying CN
# "HaLOS Device CA (<hostname>)". Prints nothing for a bare legacy CN or any
# other subject — so a bare-CN CA always "differs" from a real hostname, which
# is what lets a reset/Unit-1-era pending CA upgrade to a device CN on refresh.
halos_ca_cn_hostname() {
    local crt="$1" cn
    cn="$(_halos_ca_subject_cn "$crt")" || return 0
    if [[ "$cn" == "$HALOS_CA_SUBJECT_CN_PREFIX ("?*")" ]]; then
        cn="${cn#"$HALOS_CA_SUBJECT_CN_PREFIX ("}"
        printf '%s' "${cn%)}"
    fi
}

# halos_ca_adoption_init <adoption_file> <auto_ca_crt> <auto_created>
# Ensure the adoption sentinel exists with a correct initial value, so the
# ca-download sidecar's bind mount of this single file always finds a regular
# file (a missing mount source makes Docker create a directory there). Existing
# sentinels are preserved untouched — the value is load-bearing state, written
# once and thereafter only flipped pending→adopted by a real download.
#
# Initial value when the sentinel is absent:
#   - <auto_created>=1 (the CA was just bootstrapped/rotated this run) → "pending"
#   - else, classify the auto-CA by CN:
#       bare legacy CN "HaLOS Device CA"            → "adopted"  (never orphan
#                                                      a pre-feature trust anchor)
#       device-identifying "HaLOS Device CA (...)"  → "pending"
#       anything else / no auto-CA (custom mode)    → "adopted"  (fail-safe)
#
# Created mode 0644. The caller chowns it to HALOS_CA_DOWNLOAD_UID so the
# in-container CGI can rewrite it.
halos_ca_adoption_init() {
    local adoption_file="$1" auto_ca_crt="$2" auto_created="${3:-0}"
    if [ -z "$adoption_file" ]; then
        echo "halos_ca_adoption_init: <adoption_file> required" >&2
        return 2
    fi
    # Preserve an existing regular-file sentinel verbatim (only a download may
    # change it). A non-regular file at the path — e.g. a directory Docker
    # created when a `compose up` beat the cert-manager — is removed and
    # recreated, since the whole purpose here is to guarantee a regular file
    # exists before the sidecar binds it (otherwise the bind fails and the
    # cert-manager would abort on the write below, never recovering).
    if [ -f "$adoption_file" ]; then
        return 0
    elif [ -e "$adoption_file" ]; then
        if ! rm -rf "$adoption_file"; then
            echo "halos_ca_adoption_init: $adoption_file exists and is not a regular file, and could not be removed" >&2
            return 1
        fi
    fi

    local value="adopted"
    if [ "$auto_created" = "1" ]; then
        value="pending"
    elif [ -n "$auto_ca_crt" ] && [ -f "$auto_ca_crt" ]; then
        local cn
        cn="$(_halos_ca_subject_cn "$auto_ca_crt")"
        if [ "$cn" = "$HALOS_CA_SUBJECT_CN_PREFIX" ]; then
            value="adopted"
        elif [[ "$cn" == "$HALOS_CA_SUBJECT_CN_PREFIX ("?*")" ]]; then
            # ?* requires at least one char between the parens, so a malformed
            # empty-hostname CN "HaLOS Device CA ()" falls through to adopted.
            value="pending"
        fi
    fi

    if ! mkdir -p "$(dirname "$adoption_file")"; then
        echo "halos_ca_adoption_init: failed to mkdir for $adoption_file" >&2
        return 1
    fi
    if ! printf '%s' "$value" > "$adoption_file"; then
        echo "halos_ca_adoption_init: failed to write $adoption_file" >&2
        return 1
    fi
    chmod 0644 "$adoption_file" 2>/dev/null || true
}

# halos_ca_is_adopted <adoption_file>
# Return 0 (adopted / frozen) unless the sentinel reads exactly "pending", in
# which case return 1 (refresh-eligible). A missing or unrecognized value is
# treated as adopted — fail safe, so a corrupt sentinel never triggers a
# CN-refresh that could orphan an installed anchor.
halos_ca_is_adopted() {
    local adoption_file="$1"
    local cur
    cur="$(cat "$adoption_file" 2>/dev/null)" || return 0
    [ "$cur" = "pending" ] && return 1
    return 0
}

# _halos_uuid_from_hex <>=32-hex-chars>
# Format the first 32 hex chars of the input into the 8-4-4-4-12 UUID shape
# (uppercase). Apple only requires PayloadUUID to be a unique UUID-shaped
# string, not an RFC-4122-versioned one.
_halos_uuid_from_hex() {
    local h="$1"
    printf '%s-%s-%s-%s-%s' \
        "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}" \
        | tr '[:lower:]' '[:upper:]'
}

# halos_ca_publish_mobileconfig <src_ca_crt> <public_dir> <display_host>
# Generate an unsigned Apple Configuration Profile that carries the active CA
# as a trusted-root payload, written atomically to
# <public_dir>/halos-ca.mobileconfig (mode 0644). The ca-download sidecar
# serves it at /ca/halos-ca.mobileconfig so iOS/iPadOS users install via the OS
# profile installer instead of the raw-.crt download, which iOS routes to the
# Files app (#169). It is not used on macOS — a profile-delivered root is not
# added to Keychain Access there and has no SSL-trust UI, so macOS uses the .crt.
#
# <display_host> is embedded in PayloadDisplayName ("HaLOS Device CA (<host>)")
# so the profile is distinguishable per-device in a fleet's Profiles list. The
# caller passes the canonical hostname; this library stays free of any
# lib-hostnames dependency.
#
# The profile is UNSIGNED: signing needs an Apple Developer ID we do not own.
# Unsigned profiles install fine with a cosmetic "Not Signed" warning. Install
# is NOT trust: macOS Sequoia / iOS 17-18 still require a separate trust action
# (Keychain Access "Always Trust" / Settings -> Certificate Trust Settings).
#
# The plist template lives inline (heredoc) rather than as a separate asset
# file: lib-ca.sh installs to /usr/lib/<pkg>/ while assets/ trees install into
# the container-app data dir, so an external template would couple this helper
# to a second install path. Mirrors the inline leaf-ext heredoc in
# halos_ca_sign_leaf.
#
# Profile UUIDs and identifiers are derived from the CA's SHA-256 fingerprint,
# not fixed constants. Apple keys a profile's identity on its
# PayloadUUID/PayloadIdentifier: a globally fixed value would mean installing a
# second HaLOS device's profile silently REPLACES the first device's CA on the
# same Apple device (fleet trust loss). The per-device CA fingerprint makes each
# device's profile unique while staying stable for a given CA, so reinstalls of
# the same device's profile still overwrite cleanly. A CA rotation yields a new
# profile rather than an in-place replacement — acceptable, since operators must
# re-trust on rotation anyway.
#
# Failure semantics: on any failure leaves the pre-existing output (if any)
# untouched, removes the .new sibling, returns non-zero.
#
# Return codes:
#   0 — success
#   1 — runtime failure (missing source, DER conversion/parse error, write error)
#   2 — caller bug (missing args)
halos_ca_publish_mobileconfig() {
    local src_crt="$1" public_dir="$2" display_host="$3"
    if [ -z "$src_crt" ] || [ -z "$public_dir" ] || [ -z "$display_host" ]; then
        echo "halos_ca_publish_mobileconfig: <src_crt> <public_dir> <display_host> all required" >&2
        return 2
    fi
    if [ ! -f "$src_crt" ]; then
        echo "halos_ca_publish_mobileconfig: source cert missing: $src_crt" >&2
        return 1
    fi

    if ! mkdir -p "$public_dir"; then
        echo "halos_ca_publish_mobileconfig: failed to mkdir $public_dir" >&2
        return 1
    fi
    chmod 0755 "$public_dir" 2>/dev/null || true

    # Convert the CA to DER via a tempfile (not a pipe) so a conversion failure
    # is caught by openssl's exit status rather than swallowed mid-pipeline,
    # then base64-flatten. Guard every capture explicitly: this library is not
    # under `set -e`, and even when it is, command-substitution failures in an
    # assignment do not abort (see docs/solutions/2026-05-24-set-e-cmdsubst-blind-spot.md).
    local der_tmp
    der_tmp="$(mktemp)" || {
        echo "halos_ca_publish_mobileconfig: mktemp failed" >&2
        return 1
    }
    if ! openssl x509 -in "$src_crt" -outform DER -out "$der_tmp" 2>/dev/null; then
        rm -f "$der_tmp"
        echo "halos_ca_publish_mobileconfig: failed to convert $src_crt to DER (not a certificate?)" >&2
        return 1
    fi
    # Re-parse the DER as a sanity gate before embedding — catches a truncated
    # or non-cert source that somehow produced output bytes.
    if ! openssl x509 -inform DER -in "$der_tmp" -noout 2>/dev/null; then
        rm -f "$der_tmp"
        echo "halos_ca_publish_mobileconfig: DER conversion of $src_crt did not re-parse as a certificate" >&2
        return 1
    fi
    # Capture base64 directly (not through a pipe) so its exit status is the
    # one tested — a piped `| tr` would mask a base64 read failure behind tr's
    # success and let truncated bytes through. Flatten newlines as a separate
    # step. der_tmp is removed on every path past this point.
    local der_b64
    if ! der_b64="$(base64 < "$der_tmp")"; then
        rm -f "$der_tmp"
        echo "halos_ca_publish_mobileconfig: base64 of CA DER failed" >&2
        return 1
    fi
    rm -f "$der_tmp"
    der_b64="$(printf '%s' "$der_b64" | tr -d '\n')"
    if [ -z "$der_b64" ]; then
        echo "halos_ca_publish_mobileconfig: base64 of CA DER was empty" >&2
        return 1
    fi

    # Per-device profile identity, derived from the CA fingerprint (see header).
    local fp
    if ! fp="$(halos_ca_fingerprint "$src_crt")"; then
        echo "halos_ca_publish_mobileconfig: failed to fingerprint $src_crt" >&2
        return 1
    fi
    local outer_uuid cert_uuid outer_id cert_id
    outer_uuid="$(_halos_uuid_from_hex "${fp:0:32}")"
    cert_uuid="$(_halos_uuid_from_hex "${fp:32:32}")"
    outer_id="fi.halos.ca-trust.${fp:0:12}"
    cert_id="fi.halos.ca-trust.root.${fp:0:12}"

    local out_file="${public_dir}/halos-ca.mobileconfig"
    local out_new="${out_file}.new.$$"
    rm -f "$out_new"

    # PayloadType com.apple.security.root adds the CA to the trusted roots and
    # surfaces the iOS Certificate Trust Settings entry. PayloadRemovalDisallowed
    # false so users can remove it. No outer signature (unsigned profile).
    if ! ( umask 022 && cat > "$out_new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.security.root</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>PayloadIdentifier</key>
			<string>${cert_id}</string>
			<key>PayloadUUID</key>
			<string>${cert_uuid}</string>
			<key>PayloadDisplayName</key>
			<string>HaLOS Device CA (${display_host})</string>
			<key>PayloadCertificateFileName</key>
			<string>halos-ca.crt</string>
			<key>PayloadContent</key>
			<data>${der_b64}</data>
		</dict>
	</array>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
	<key>PayloadIdentifier</key>
	<string>${outer_id}</string>
	<key>PayloadUUID</key>
	<string>${outer_uuid}</string>
	<key>PayloadDisplayName</key>
	<string>HaLOS Device CA (${display_host})</string>
	<key>PayloadDescription</key>
	<string>Installs this HaLOS device's certificate authority so its web services validate without warnings. Trusting the CA for SSL is a separate step after install.</string>
	<key>PayloadRemovalDisallowed</key>
	<false/>
</dict>
</plist>
EOF
    ); then
        rm -f "$out_new"
        echo "halos_ca_publish_mobileconfig: failed to write $out_new" >&2
        return 1
    fi

    if ! chmod 0644 "$out_new"; then
        rm -f "$out_new"
        echo "halos_ca_publish_mobileconfig: chmod 0644 failed on $out_new" >&2
        return 1
    fi
    if [ -d "$out_file" ]; then
        rm -f "$out_new"
        echo "halos_ca_publish_mobileconfig: refusing to install over directory at $out_file" >&2
        return 1
    fi
    if ! mv "$out_new" "$out_file"; then
        rm -f "$out_new"
        echo "halos_ca_publish_mobileconfig: failed to mv $out_new to $out_file; previous copy (if any) is preserved" >&2
        return 1
    fi
}
