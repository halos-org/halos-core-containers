#!/bin/bash
# lib-hostnames.sh — Shared shell library for hostname-aware operations
#
# Sourced by:
#   - halos-core-containers/prestart.sh
#   - /usr/bin/configure-container-routing
#   - /usr/bin/reload-oidc-clients
#
# Provides parsing, validation, and querying of /etc/halos/hostnames.conf,
# the admin-managed hostname list that drives:
#   - TLS cert SANs (DNS + IP)
#   - Authelia per-hostname session.cookies entries
#   - OIDC redirect_uris (DNS only)
#   - Path-only Traefik routing (canonical used for OIDC issuer)
#
# Quoting contract: every consumer that expands a hostname into a shell
# argument, openssl SAN string, YAML scalar, or URL MUST quote/escape the
# value at the consumer site. Validation eliminates shell metacharacters
# as defense-in-depth; quoting is the primary defense.

# Configuration --------------------------------------------------------------

# Override via env for tests; defaults match production.
: "${HALOS_HOSTNAMES_FILE:=/etc/halos/hostnames.conf}"
: "${HALOS_HOSTNAMES_MAX:=16}"

# Pinned regexes (shell-portable; bash =~ ERE).
# RFC 1123 DNS: labels start/end alphanumeric. Single labels are allowed —
# many SOHO routers (UniFi, OpenWrt, pfSense, Fritz!Box) integrate DHCP with
# LAN DNS so a bare hostname like `halosdev` is resolvable, and DHCP option
# 15 may itself be a single label (e.g., `hal`). Defense-in-depth against
# shell metacharacters lives in _halos_has_dangerous_chars; the regex is
# the syntactic check.
HALOS_HOSTNAMES_DNS_RE='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'
HALOS_HOSTNAMES_IPV4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
# IPv6: rough literal shape (colons and hex). Round-tripped via getent for soundness.
HALOS_HOSTNAMES_IPV6_RE='^[0-9a-fA-F:]+$'

# State (populated by halos_load_hostnames) ----------------------------------

# After halos_load_hostnames, these globals hold the parsed result:
#   HALOS_HOSTNAMES_CANONICAL  — first DNS entry (or ${hostname}.local fallback)
#   HALOS_HOSTNAMES_DNS[]      — DNS entries in input order (post-expansion, post-validation)
#   HALOS_HOSTNAMES_IPS[]      — IP entries in input order
#   HALOS_HOSTNAMES_FALLBACK   — "1" if loaded canonical is the default (not from a valid file entry), else "0"
#   HALOS_HOSTNAMES_FALLBACK_REASON — short human-readable cause when fallback is set

# Internal helpers -----------------------------------------------------------

_halos_log() {
    # Stable signature on the first token so journalctl greps cleanly.
    printf '%s\n' "$*" >&2
}

_halos_short_hostname() {
    hostname -s 2>/dev/null || hostname | cut -d. -f1
}

# Trim leading/trailing whitespace from $1, echo the result.
_halos_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Reject domain values that contain anything outside the DNS label set.
# Used to defend against /etc/hosts garbage flowing through `hostname -d`
# or pathological nmcli output. Returns 0 if safe, 1 if not.
_halos_domain_safe() {
    local d="$1"
    [ -z "$d" ] && return 1
    _halos_has_dangerous_chars "$d" && return 1
    [[ "$d" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
    return 0
}

# Resolve the device's DNS domain for ${fqdn}/${domain} token expansion.
# Resolution chain (first non-empty wins):
#   1. $HALOS_DOMAIN_RESOLVER (test injection seam) — only honored when it
#      names a defined shell function (declare -F). Production environments
#      with a stray export are not allowed to short-circuit real resolution
#      or invoke arbitrary commands.
#   2. `hostname -d` — admin-set domain via /etc/hosts or hostnamectl.
#   3. `nmcli -t -f IP4.DOMAIN device show` — DHCP-provided domain across
#      connected devices; first non-empty value wins. Wrapped in `timeout`
#      so a hung NetworkManager can't block prestart. Skipped if nmcli is
#      not installed.
# Resolved values are validated by _halos_domain_safe; anything that fails
# (whitespace, NUL, shell metacharacters, non-DNS characters) is treated
# as no-domain and the chain falls through.
# Echoes the empty string when nothing resolves; never errors.
#
# Cached per `halos_load_hostnames` invocation in HALOS_HOSTNAMES_DOMAIN_CACHE.
# Note: empty-string is a valid cached value (meaning "resolver completed,
# no domain available"). The `${VAR+set}` test distinguishes that from
# unset (not yet resolved). Do not "simplify" to `[ -n "$VAR" ]`.
_halos_resolve_domain() {
    if [ -n "${HALOS_HOSTNAMES_DOMAIN_CACHE+set}" ]; then
        printf '%s' "$HALOS_HOSTNAMES_DOMAIN_CACHE"
        return 0
    fi

    local d=""

    # 1. Test injection seam — only when it names a defined shell function.
    if [ -n "${HALOS_DOMAIN_RESOLVER:-}" ] && declare -F "$HALOS_DOMAIN_RESOLVER" >/dev/null 2>&1; then
        d="$("$HALOS_DOMAIN_RESOLVER" 2>/dev/null || true)"
        d="$(_halos_trim "$d")"
        # Injected resolver output is authoritative (including empty) so
        # tests can pin empty-domain behavior. No domain-shape validation.
        HALOS_HOSTNAMES_DOMAIN_CACHE="$d"
        printf '%s' "$d"
        return 0
    fi

    # 2. hostname -d (admin-configured).
    d="$(_halos_trim "$(hostname -d 2>/dev/null || true)")"
    if [ -n "$d" ] && ! _halos_domain_safe "$d"; then
        _halos_log "HALOS_HOSTNAMES_SKIP: hostname -d returned unsafe value, ignoring"
        d=""
    fi

    # 3. nmcli (DHCP-provided), with timeout so a hung NM can't block prestart.
    if [ -z "$d" ] && command -v nmcli >/dev/null 2>&1; then
        local nmcli_cmd
        if command -v timeout >/dev/null 2>&1; then
            nmcli_cmd="timeout 2 nmcli"
        else
            nmcli_cmd="nmcli"
        fi
        local line value
        while IFS= read -r line; do
            # Format: IP4.DOMAIN[N]:value (terse mode, colon-separated).
            value="${line#*:}"
            # nmcli emits "--" for empty fields; skip those.
            if [ -n "$value" ] && [ "$value" != "--" ]; then
                value="$(_halos_trim "$value")"
                if _halos_domain_safe "$value"; then
                    d="$value"
                    break
                fi
            fi
        done < <($nmcli_cmd -t -f IP4.DOMAIN device show 2>/dev/null || true)
    fi

    HALOS_HOSTNAMES_DOMAIN_CACHE="$d"
    printf '%s' "$d"
}

# Validate IPv4 octet bounds (regex only matches digit shape).
_halos_valid_ipv4() {
    local ip="$1" o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<<"$ip"
    [ -n "$o1" ] && [ -n "$o2" ] && [ -n "$o3" ] && [ -n "$o4" ] || return 1
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        # Reject leading zeros (canonical form only) and out-of-range.
        case "$octet" in
            0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# Validate IPv6 via getent (round-trip parse). Avoids hand-rolled regex.
_halos_valid_ipv6() {
    local addr="$1"
    # Must contain at least one colon to be IPv6 (and not bare digits like "1").
    case "$addr" in *:*) ;; *) return 1 ;; esac
    [[ "$addr" =~ $HALOS_HOSTNAMES_IPV6_RE ]] || return 1
    # getent ahosts <ipv6> echoes the address back if parseable.
    getent ahosts "$addr" >/dev/null 2>&1
}

# Reject obvious shell-metacharacter and control-character contamination.
# Validation regex would already exclude most, but this is defense-in-depth.
_halos_has_dangerous_chars() {
    local s="$1"
    case "$s" in
        *' '*|*$'\t'*|*$'\n'*|*$'\r'*) return 0 ;;
        *'`'*) return 0 ;;
        *'$'*) return 0 ;;
        *'\'*) return 0 ;;
        *'"'*) return 0 ;;
        *"'"*) return 0 ;;
    esac
    # Reject NUL and ASCII control chars (POSIX class).
    [[ "$s" =~ [[:cntrl:]] ]] && return 0
    return 1
}

# Expand the supported tokens — ${fqdn}, ${domain}, ${hostname} — in a
# single non-recursive pass.
#
# Substitution order matters: ${fqdn} expands first to the resolved
# <short>.<domain> string directly (not to the literal "${hostname}.${domain}"),
# so subsequent substitutions can't re-process it. ${domain} expands second,
# ${hostname} last.
#
# When the resolved domain is empty, ${fqdn} expands to "<short>." and
# ${domain} to "" — both produce strings rejected by the DNS regex. The
# caller (halos_load_hostnames) detects this case via _halos_lineuses_domain
# and treats it as a soft-drop instead of a hard fallback.
_halos_expand_line() {
    local line="$1"
    local short domain fqdn
    short="$(_halos_short_hostname)"
    domain="$(_halos_resolve_domain)"
    if [ -n "$domain" ]; then
        fqdn="${short}.${domain}"
    else
        fqdn="${short}."
    fi
    line="${line//\$\{fqdn\}/$fqdn}"
    line="${line//\$\{domain\}/$domain}"
    line="${line//\$\{hostname\}/$short}"
    printf '%s' "$line"
}

# Predicate: does the raw (pre-expansion) line reference a domain-dependent
# token? Used to classify expansion failures as soft-drop vs hard-fail.
_halos_lineuses_domain() {
    local line="$1"
    case "$line" in
        *'${fqdn}'*|*'${domain}'*) return 0 ;;
    esac
    return 1
}

# Set fallback state and emit a diagnostic.
_halos_set_fallback() {
    local reason="$1"
    HALOS_HOSTNAMES_FALLBACK=1
    HALOS_HOSTNAMES_FALLBACK_REASON="$reason"
    _halos_log "HALOS_HOSTNAMES_FALLBACK: $reason — falling back to single-SAN default"
}

# Public API -----------------------------------------------------------------

# halos_load_hostnames
#   Parse $HALOS_HOSTNAMES_FILE, populate state globals.
#   Always returns 0 — fallback is signaled via HALOS_HOSTNAMES_FALLBACK,
#   never via exit status (consumers must boot in fallback mode).
halos_load_hostnames() {
    HALOS_HOSTNAMES_DNS=()
    HALOS_HOSTNAMES_IPS=()
    HALOS_HOSTNAMES_CANONICAL=""
    HALOS_HOSTNAMES_FALLBACK=0
    HALOS_HOSTNAMES_FALLBACK_REASON=""
    unset HALOS_HOSTNAMES_DOMAIN_CACHE
    # Prime the domain cache in this (parent) process so each per-line
    # `expanded="$(_halos_expand_line "$line")"` subshell inherits the
    # cached value instead of re-running the resolver chain. Without this
    # step the cache is subshell-local and the resolver runs once per line.
    _halos_resolve_domain >/dev/null

    local file="$HALOS_HOSTNAMES_FILE"
    local default_canonical
    default_canonical="$(_halos_short_hostname).local"

    if [ ! -e "$file" ]; then
        _halos_set_fallback "config file not found: $file"
        HALOS_HOSTNAMES_CANONICAL="$default_canonical"
        HALOS_HOSTNAMES_DNS=("$default_canonical")
        return 0
    fi

    if [ ! -r "$file" ]; then
        _halos_set_fallback "config file not readable: $file"
        HALOS_HOSTNAMES_CANONICAL="$default_canonical"
        HALOS_HOSTNAMES_DNS=("$default_canonical")
        return 0
    fi

    local line raw expanded
    local entry_count=0
    local had_invalid=0
    local first_invalid_reason=""

    while IFS= read -r raw || [ -n "$raw" ]; do
        # Strip leading/trailing whitespace.
        line="${raw#"${raw%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        # Skip blanks and comments.
        [ -z "$line" ] && continue
        case "$line" in '#'*) continue ;; esac

        entry_count=$((entry_count + 1))
        if [ "$entry_count" -gt "$HALOS_HOSTNAMES_MAX" ]; then
            had_invalid=1
            first_invalid_reason="${first_invalid_reason:-cap exceeded (max $HALOS_HOSTNAMES_MAX entries)}"
            break
        fi

        expanded="$(_halos_expand_line "$line")"

        # Soft-drop: a line referencing ${fqdn}/${domain} whose expansion
        # produced an empty or invalid result is silently skipped. This
        # lets the shipped default include ${fqdn} without forcing a
        # whole-file fallback on devices where no domain resolves.
        # Literal admin-typed entries still fail closed below.
        local uses_domain=0
        if _halos_lineuses_domain "$line"; then
            uses_domain=1
        fi

        # Empty expansion (bare ${domain} with no resolved domain).
        if [ -z "$expanded" ]; then
            if [ "$uses_domain" -eq 1 ]; then
                _halos_log "HALOS_HOSTNAMES_SKIP: domain unresolved, dropping line: $line"
                continue
            fi
            # A literally empty line is already filtered upstream; treat as invalid.
            had_invalid=1
            first_invalid_reason="${first_invalid_reason:-empty entry after expansion}"
            continue
        fi

        if _halos_has_dangerous_chars "$expanded"; then
            had_invalid=1
            first_invalid_reason="${first_invalid_reason:-rejected entry with dangerous characters}"
            continue
        fi

        # Classify: IPv4, IPv6, DNS, or invalid.
        if [[ "$expanded" =~ $HALOS_HOSTNAMES_IPV4_RE ]]; then
            if _halos_valid_ipv4 "$expanded"; then
                HALOS_HOSTNAMES_IPS+=("$expanded")
            else
                had_invalid=1
                first_invalid_reason="${first_invalid_reason:-invalid IPv4 entry: $expanded}"
            fi
        elif _halos_valid_ipv6 "$expanded"; then
            HALOS_HOSTNAMES_IPS+=("$expanded")
        elif [[ "$expanded" =~ $HALOS_HOSTNAMES_DNS_RE ]]; then
            HALOS_HOSTNAMES_DNS+=("$expanded")
        elif [ "$uses_domain" -eq 1 ]; then
            # Domain-dependent line whose expansion failed validation
            # (e.g., trailing-dot from empty domain). Soft-drop, do not
            # taint had_invalid.
            _halos_log "HALOS_HOSTNAMES_SKIP: domain-dependent expansion invalid, dropping line: $line"
            continue
        else
            had_invalid=1
            first_invalid_reason="${first_invalid_reason:-invalid hostname entry: $expanded}"
        fi
    done < "$file"

    if [ "$had_invalid" -eq 1 ]; then
        _halos_set_fallback "$first_invalid_reason"
        HALOS_HOSTNAMES_DNS=("$default_canonical")
        HALOS_HOSTNAMES_IPS=()
        HALOS_HOSTNAMES_CANONICAL="$default_canonical"
        return 0
    fi

    if [ "${#HALOS_HOSTNAMES_DNS[@]}" -eq 0 ]; then
        _halos_set_fallback "no valid DNS entries in $file"
        HALOS_HOSTNAMES_DNS=("$default_canonical")
        HALOS_HOSTNAMES_IPS=()
        HALOS_HOSTNAMES_CANONICAL="$default_canonical"
        return 0
    fi

    # Deduplicate (case-insensitive for DNS, exact for IPs), preserving
    # first-occurrence order. Necessary because admin-typed entries can
    # collide with token-expanded ones — e.g., a hostnames.conf containing
    # both `${hostname}.local` and `${fqdn}` on a SOHO LAN where DHCP
    # option 15 advertises domain=`local` would otherwise produce two
    # identical entries, leading to duplicate cert SANs and (more
    # critically) duplicate Authelia cookie blocks that Authelia 4.39+
    # rejects at config-load time.
    local -a _deduped
    local _seen _key h
    _deduped=()
    _seen=""
    for h in "${HALOS_HOSTNAMES_DNS[@]}"; do
        _key="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
        case " $_seen " in
            *" $_key "*) continue ;;
        esac
        _deduped+=("$h")
        _seen="$_seen $_key"
    done
    HALOS_HOSTNAMES_DNS=("${_deduped[@]}")

    _deduped=()
    _seen=""
    for h in "${HALOS_HOSTNAMES_IPS[@]}"; do
        case " $_seen " in
            *" $h "*) continue ;;
        esac
        _deduped+=("$h")
        _seen="$_seen $h"
    done
    HALOS_HOSTNAMES_IPS=("${_deduped[@]}")

    HALOS_HOSTNAMES_CANONICAL="${HALOS_HOSTNAMES_DNS[0]}"
    return 0
}

# Print the canonical hostname (first DNS entry, or fallback default).
halos_canonical_hostname() {
    [ -z "${HALOS_HOSTNAMES_CANONICAL:-}" ] && halos_load_hostnames
    printf '%s\n' "$HALOS_HOSTNAMES_CANONICAL"
}

# Print all DNS hostnames, one per line, in input order.
halos_dns_hostnames() {
    [ -z "${HALOS_HOSTNAMES_CANONICAL:-}" ] && halos_load_hostnames
    local h
    for h in "${HALOS_HOSTNAMES_DNS[@]}"; do
        printf '%s\n' "$h"
    done
}

# Print all hostnames (DNS + IP), one per line, DNS first then IPs.
halos_all_hostnames() {
    [ -z "${HALOS_HOSTNAMES_CANONICAL:-}" ] && halos_load_hostnames
    local h
    for h in "${HALOS_HOSTNAMES_DNS[@]}"; do
        printf '%s\n' "$h"
    done
    for h in "${HALOS_HOSTNAMES_IPS[@]}"; do
        printf '%s\n' "$h"
    done
}

# Print SHA256 of LC_ALL=C-sorted hostname list (64 hex chars, no trailing whitespace).
halos_hostnames_hash() {
    [ -z "${HALOS_HOSTNAMES_CANONICAL:-}" ] && halos_load_hostnames
    halos_all_hostnames | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

# halos_expand_oidc_redirect_uri <uri>
#   If <uri> contains the literal token ${HALOS_DOMAIN}, emit one expanded
#   URI per DNS hostname (IP entries are deliberately excluded — IPs do not
#   make valid OIDC redirect_uris). If <uri> has no placeholder, emit it
#   unchanged. Always writes to stdout, one URI per line.
halos_expand_oidc_redirect_uri() {
    [ -z "${HALOS_HOSTNAMES_CANONICAL:-}" ] && halos_load_hostnames
    local uri="$1"
    if [[ "$uri" != *'${HALOS_DOMAIN}'* ]]; then
        printf '%s\n' "$uri"
        return 0
    fi
    local h
    for h in "${HALOS_HOSTNAMES_DNS[@]}"; do
        printf '%s\n' "${uri//\$\{HALOS_DOMAIN\}/$h}"
    done
}
