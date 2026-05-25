#!/bin/bash
# lib-ca.sh — Shared shell library for HaLOS device-CA + leaf cert management.
#
# Sourced by:
#   - halos-core-containers/prestart.sh
#
# Provides:
#   - halos_ca_ensure_auto <dir>          generate/refresh auto-CA at <dir>/ca.{crt,key}
#   - halos_ca_fingerprint <crt>          print SHA256 fingerprint (lowercase hex, no colons)
#   - halos_ca_sign_leaf <ca-crt> <ca-key> <leaf-crt-out> <leaf-key-out> <san> <cn> [days]
#   - halos_ca_sentinel_compose <hostnames_hash> <ca_fingerprint>
#   - halos_ca_sentinel_classify <stored>      → match-shape | legacy | unrecognized
#   - halos_ca_validate_pair <crt> <key>       validate cert/key suitable as device CA
#   - halos_ca_select_active <custom_dir> <auto_dir> <symlink_path>
#                                              pick custom-if-valid / else auto, update symlink
#   - halos_cockpit_install_leaf <leaf_crt> <leaf_key> <output_path>
#                                              install combined PEM override for cockpit-tls
#   - halos_ca_publish_public <src_crt> <public_dir>
#                                              copy active CA into a public-bindmount target
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

HALOS_CA_DAYS=7300            # 20 years
HALOS_CA_LEAF_DAYS=3650       # 10 years
HALOS_CA_BACKDATE_HOURS=24
HALOS_CA_SUBJECT="/CN=HaLOS Device CA"

# Auto-CA rotation trigger: rotate the device-generated CA when its remaining
# validity drops below this many days. Set well below the 20y validity, so
# the realistic trigger is clock skew / corruption — not natural aging.
HALOS_CA_AUTO_ROTATE_DAYS=365

# Custom (operator-supplied) CA acceptance thresholds:
#   - hard floor: refuse to use a custom CA with less than this many days
#     remaining. Lower than the auto-rotate threshold because operators
#     deliberately choose short-lived intermediates in some deployments
#     and we don't want to refuse a valid 6-month CA out of the box.
#   - warn window: emit a loud WARNING in prestart logs when remaining
#     validity is below this, even if still above the hard floor. Gives
#     operators a documented runway to rotate before the hard cliff.
HALOS_CA_CUSTOM_MIN_DAYS=30
HALOS_CA_CUSTOM_WARN_DAYS=90

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

# _halos_ca_is_healthy <crt_path> [min_days]
# Returns 0 if the cert parses, hasn't expired, and has at least <min_days>
# of validity left. <min_days> defaults to HALOS_CA_AUTO_ROTATE_DAYS for
# backwards compatibility with the auto-CA rotation call site; consumers
# checking custom-CA acceptance pass HALOS_CA_CUSTOM_MIN_DAYS explicitly.
_halos_ca_is_healthy() {
    local crt="$1"
    local min_days="${2:-$HALOS_CA_AUTO_ROTATE_DAYS}"
    [ -f "$crt" ] || return 1
    # -checkend N: returns 0 if cert expires more than N seconds in the future.
    local horizon=$((min_days * 86400))
    openssl x509 -in "$crt" -noout -checkend "$horizon" >/dev/null 2>&1
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
halos_ca_ensure_auto() {
    local out_dir="$1"
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

    # umask 077 ensures the openssl-created key file is 0600 from inception,
    # closing the race window between cert creation and chmod where another
    # local UID could open the key fd while it was world-readable.
    if ! ( umask 077 && openssl req -x509 -nodes -newkey rsa:4096 \
            -days "$HALOS_CA_DAYS" \
            -not_before "$not_before" \
            -keyout "$ca_key_new" \
            -out "$ca_crt_new" \
            -subj "$HALOS_CA_SUBJECT" \
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
    if ! _halos_ca_is_healthy "$crt" "$HALOS_CA_CUSTOM_MIN_DAYS"; then
        echo "halos_ca_validate_pair: cert at $crt is expired or has under ${HALOS_CA_CUSTOM_MIN_DAYS}d remaining validity (hard floor for custom CAs)" >&2
        return 1
    fi
    # Soft warning: log but pass validation if remaining is below the warn
    # window. Gives operators a documented runway to rotate before the cliff.
    if ! _halos_ca_is_healthy "$crt" "$HALOS_CA_CUSTOM_WARN_DAYS"; then
        echo "halos_ca_validate_pair: WARNING: cert at $crt has under ${HALOS_CA_CUSTOM_WARN_DAYS}d remaining validity; rotate before it falls below the ${HALOS_CA_CUSTOM_MIN_DAYS}d hard floor" >&2
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

# halos_ca_select_active <custom_dir> <auto_dir> <symlink_path>
# Picks the active device CA: operator-supplied custom (when present + valid)
# wins; otherwise the auto-CA at <auto_dir> is ensured and used. Updates
# <symlink_path> to point at the active cert (atomic via `ln -sfn`).
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
    local custom_dir="$1" auto_dir="$2" symlink_path="$3"
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
        halos_ca_ensure_auto "$auto_dir" || return $?
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
# Failure semantics: on any openssl error, leaves the pre-existing leaf_crt /
# leaf_key untouched, cleans up .new files, returns non-zero. The CALLER is
# responsible for invalidating any cert-tracking sentinel BEFORE invoking this
# function (so a failed sign won't be silently skipped on next boot due to a
# stale "everything matches" sentinel).
halos_ca_sign_leaf() {
    local ca_crt="$1" ca_key="$2" leaf_crt="$3" leaf_key="$4" san="$5" cn="$6"
    local days="${7:-$HALOS_CA_LEAF_DAYS}"

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
