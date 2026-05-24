#!/bin/bash
# lib-ca.sh — Shared shell library for HaLOS device-CA + leaf cert management.
#
# Sourced by:
#   - halos-core-containers/prestart.sh
#
# Provides three primitives:
#   - halos_ca_ensure_auto <dir>          generate auto-CA at <dir>/ca.{crt,key} if absent
#   - halos_ca_fingerprint <crt>          print SHA256 fingerprint (lowercase hex, no colons)
#   - halos_ca_sign_leaf <ca-crt> <ca-key> <leaf-crt-out> <leaf-key-out> <san> <cn> [days]
#
# Generated certs carry the extensions browsers + OS trust stores require:
#   CA   — basicConstraints CA:TRUE (so importing as trust anchor actually works),
#          keyUsage keyCertSign+cRLSign, subjectKeyIdentifier
#   leaf — basicConstraints CA:FALSE, keyUsage digitalSignature+keyEncipherment,
#          extendedKeyUsage serverAuth (Chrome requires this), subjectAltName
#
# notBefore on both CA and leaf is backdated 24h to absorb first-boot clock
# skew (devices with dead RTC + no NTP yet would otherwise see "cert not yet
# valid" until the clock catches up).

# Tuning ---------------------------------------------------------------------

: "${HALOS_CA_DAYS:=7300}"            # 20 years
: "${HALOS_CA_LEAF_DAYS:=3650}"       # 10 years
: "${HALOS_CA_BACKDATE_HOURS:=24}"
: "${HALOS_CA_SUBJECT:=/CN=HaLOS Device CA}"

# Internal -------------------------------------------------------------------

_halos_ca_not_before() {
    local epoch
    epoch=$(date -u +%s)
    epoch=$((epoch - HALOS_CA_BACKDATE_HOURS * 3600))
    # Portable across GNU and BSD date: try GNU's `-d @epoch` first, fall back to BSD's `-r epoch`.
    date -u -d "@${epoch}" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "${epoch}" +%Y%m%d%H%M%SZ
}

# Public ---------------------------------------------------------------------

# halos_ca_ensure_auto <output_dir>
# Generates ca.crt + ca.key under <output_dir> if either is missing.
# Idempotent: if both files exist, returns 0 without touching them.
halos_ca_ensure_auto() {
    local out_dir="$1"
    if [ -z "$out_dir" ]; then
        echo "halos_ca_ensure_auto: output_dir required" >&2
        return 2
    fi
    mkdir -p "$out_dir"
    # Tighten directory mode regardless of whether mkdir just created it or it
    # already existed — defense-in-depth so any other files placed alongside
    # the CA key (e.g. .srl, future intermediate exports) are not reachable
    # by other local UIDs.
    chmod 700 "$out_dir"
    local ca_crt="${out_dir}/ca.crt"
    local ca_key="${out_dir}/ca.key"

    if [ -f "$ca_crt" ] && [ -f "$ca_key" ]; then
        return 0
    fi

    local ca_crt_new="${ca_crt}.new"
    local ca_key_new="${ca_key}.new"
    local not_before
    not_before=$(_halos_ca_not_before)

    if ! openssl req -x509 -nodes -newkey rsa:4096 \
            -days "$HALOS_CA_DAYS" \
            -not_before "$not_before" \
            -keyout "$ca_key_new" \
            -out "$ca_crt_new" \
            -subj "$HALOS_CA_SUBJECT" \
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" \
            -addext "subjectKeyIdentifier=hash" \
            >/dev/null 2>&1; then
        rm -f "$ca_crt_new" "$ca_key_new"
        echo "halos_ca_ensure_auto: openssl req failed generating CA" >&2
        return 1
    fi

    chmod 600 "$ca_key_new"
    chmod 644 "$ca_crt_new"
    mv "$ca_key_new" "$ca_key"
    mv "$ca_crt_new" "$ca_crt"
}

# halos_ca_fingerprint <crt_path>
# Prints SHA256 fingerprint as lowercase hex (no colons). Stable across openssl
# versions; suitable for use in the cert sentinel.
halos_ca_fingerprint() {
    local crt="$1"
    if [ -z "$crt" ] || [ ! -f "$crt" ]; then
        echo "halos_ca_fingerprint: cert path required and must exist" >&2
        return 1
    fi
    openssl x509 -in "$crt" -noout -fingerprint -sha256 2>/dev/null \
        | sed -e 's/^.*Fingerprint=//' -e 's/://g' \
        | tr '[:upper:]' '[:lower:]'
}

# halos_ca_sign_leaf <ca_crt> <ca_key> <leaf_crt_out> <leaf_key_out> <san> <cn> [days]
# Generates a fresh leaf key + cert signed by the given CA.
# SAN format: openssl-compatible list, e.g. "DNS:device.local,DNS:device.lan,IP:10.0.0.5".
# Writes leaf_key first then leaf_crt (atomic on Linux); Traefik tolerates the
# brief key-without-matching-cert window better than the inverse.
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

    # Compute timestamp before allocating tempfiles so a date(1) failure
    # can't leak csr_tmp / ext_tmp under set -e.
    local not_before
    not_before=$(_halos_ca_not_before)

    local leaf_key_new="${leaf_key}.new"
    local leaf_crt_new="${leaf_crt}.new"
    local csr_tmp ext_tmp
    csr_tmp="$(mktemp)"
    ext_tmp="$(mktemp)"
    local rc=0

    if ! openssl req -nodes -newkey rsa:2048 \
            -keyout "$leaf_key_new" \
            -out "$csr_tmp" \
            -subj "/CN=${cn}" \
            >/dev/null 2>&1; then
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
        if ! openssl x509 -req \
                -in "$csr_tmp" \
                -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial \
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
