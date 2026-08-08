#!/bin/bash
# Shared Authelia OIDC client-registration merger.
#
# One implementation, sourced by prestart.sh (boot-time render) and by
# /usr/bin/reload-oidc-clients (hot reload). A second copy drifts, and the
# drift is invisible until a login breaks.
#
# Caller contract — set these before calling halos_oidc_merge_clients:
#   OIDC_CLIENTS_DIR    directory of client snippets
#   AUTHELIA_OIDC_FILE  rendered registration Authelia loads
#   OIDC_HMAC_SECRET    from the Authelia secrets file
#   OIDC_PRIVATE_KEY    JWKS signing key (PEM text)
# lib-hostnames.sh must already be sourced with halos_load_hostnames run:
# redirect_uris expansion goes through halos_expand_oidc_redirect_uri.
#
# Applying the registration is the caller's job, because only the caller knows
# what applying means: prestart is about to start the container, the reload
# tool has to restart a running one. So the merge renders and reports through
# HALOS_OIDC_CHANGED, and the caller calls halos_oidc_commit once the render is
# live. Until that commit the merge is not recorded, and the next run redoes it
# — at-least-once is the safe direction, since the alternative is a rendered
# file Authelia never loaded that every later run reports as current.

# Image used for secret hashing. Pinned to the tag docker-compose.yml runs, so
# the device never has to pull, retain, or reach a registry for a second image.
HALOS_OIDC_AUTHELIA_IMAGE="authelia/authelia:4.39.19"

# Read one top-level scalar field from a snippet. First match only: a repeated
# key would otherwise yield a multi-line value that escapes the client mapping
# and injects top-level Authelia config.
_halos_oidc_snippet_field() {
    local snippet="$1" key="$2"
    grep -m1 -E "^${key}:" "$snippet" | sed "s/${key}:[[:space:]]*//" | tr -d "'\""
}

# Hash a plaintext client secret with Authelia's own CLI. The plaintext goes
# through the environment, not argv: /proc/<pid>/cmdline is world-readable.
# Every call salts afresh, so output is never comparable between runs — change
# detection works off the inputs (see _halos_oidc_input_digest).
_halos_oidc_hash_secret() {
    local plaintext="$1" hash_output digest
    if ! hash_output=$(HALOS_OIDC_PW="$plaintext" docker run --rm \
        -e HALOS_OIDC_PW \
        "$HALOS_OIDC_AUTHELIA_IMAGE" \
        sh -c 'authelia crypto hash generate pbkdf2 --variant sha512 --password "$HALOS_OIDC_PW"' 2>&1); then
        printf 'docker: %s\n' "$hash_output" >&2
        return 1
    fi
    digest=$(printf '%s\n' "$hash_output" | grep -m1 'Digest:' | sed 's/Digest: //')
    # An exit-0 run whose output carries no digest would otherwise register the
    # client with an empty secret, which Authelia rejects at config load.
    [ -n "$digest" ] || { printf 'authelia crypto hash produced no digest\n' >&2; return 1; }
    printf '%s\n' "$digest"
}

# Digest of everything the rendered registration derives from. A snippet whose
# text never changes still lands here through its secret file's contents — that
# is the rotation case that broke OIDC silently (#201).
#
# The shell libraries are digested too. The renderer's output depends on its own
# code and on halos_expand_oidc_redirect_uri in lib-hostnames.sh, so an upgrade
# that changes either must re-render; a hand-maintained version constant would
# put that invariant in a comment and let the next author miss it.
_halos_oidc_input_digest() {
    local lib_dir; lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    {
        cat "${lib_dir}/lib-oidc-clients.sh" "${lib_dir}/lib-hostnames.sh" 2>/dev/null
        printf 'hmac=%s\n' "$OIDC_HMAC_SECRET"
        printf 'key=%s\n' "$OIDC_PRIVATE_KEY"
        printf 'hostnames=\n'
        halos_dns_hostnames

        local snippet secret_file
        for snippet in "${OIDC_CLIENTS_DIR}"/*.yml; do
            [ -e "$snippet" ] || continue
            printf 'snippet=%s\n' "$snippet"
            cat "$snippet"
            secret_file="$(_halos_oidc_snippet_field "$snippet" client_secret_file)"
            if [ -n "$secret_file" ] && [ -s "$secret_file" ]; then
                printf 'secret=%s\n' "$secret_file"
                cat "$secret_file"
            fi
        done
    } | sha256sum | awk '{print $1}'
}

_halos_oidc_output_digest() {
    [ -f "$AUTHELIA_OIDC_FILE" ] || return 1
    sha256sum < "$AUTHELIA_OIDC_FILE" | awk '{print $1}'
}

# Write the registration Authelia loads when there is nothing to register. The
# file cannot simply be omitted: docker-compose.yml names it in
# X_AUTHELIA_CONFIG, and Authelia will not start without a config it lists.
_halos_oidc_write_empty() {
    cat > "$1" << 'EOF'
# Authelia OIDC Configuration - No clients configured
EOF
}

# Render the registration from the current snippets, through a same-directory
# temp file so Authelia never observes a half-written config.
#
# Returns non-zero when a client could not be hashed or the write failed, and
# leaves the previous registration in place. Hashing runs the Authelia image, so
# it fails for reasons that have nothing to do with the snippets, and dropping a
# client from the registration breaks exactly the logins this mechanism protects.
_halos_oidc_render() {
    local client_count=0
    local clients_yaml=""
    local render_failed=0
    local snippet snippet_name

    for snippet in "${OIDC_CLIENTS_DIR}"/*.yml; do
        [ -e "$snippet" ] || continue
        snippet_name=$(basename "$snippet")
        echo "  Processing: ${snippet_name}"

        local client_id client_name client_secret_file consent_mode token_auth_method
        client_id=$(_halos_oidc_snippet_field "$snippet" client_id)
        client_name=$(_halos_oidc_snippet_field "$snippet" client_name)
        client_secret_file=$(_halos_oidc_snippet_field "$snippet" client_secret_file)
        consent_mode=$(_halos_oidc_snippet_field "$snippet" consent_mode)
        token_auth_method=$(_halos_oidc_snippet_field "$snippet" token_endpoint_auth_method)

        [ -z "$client_id" ] && { echo "  WARNING: Skipping ${snippet_name} - missing client_id"; continue; }

        # -s, not -f: an app that has written its snippet but not yet its secret
        # would otherwise be registered with the hash of the empty string.
        local client_secret_hash=""
        if [ -n "$client_secret_file" ] && [ -s "$client_secret_file" ]; then
            local plaintext_secret
            plaintext_secret=$(cat "$client_secret_file")
            if ! client_secret_hash=$(_halos_oidc_hash_secret "$plaintext_secret"); then
                echo "  ERROR: Failed to hash client secret for ${snippet_name}" >&2
                render_failed=1
                continue
            fi
        else
            echo "  WARNING: Skipping ${snippet_name} - client_secret_file missing or empty: ${client_secret_file}"
            continue
        fi

        # Expand the ${HALOS_DOMAIN} placeholder to one URI per configured DNS
        # hostname (IP entries excluded — see halos_expand_oidc_redirect_uri).
        local redirect_uris=""
        local in_redirect=false
        local line uri expanded_uri
        while IFS= read -r line; do
            if echo "$line" | grep -qE '^redirect_uris:'; then
                in_redirect=true
                continue
            fi
            if $in_redirect; then
                if echo "$line" | grep -qE '^[[:space:]]+-'; then
                    uri=$(echo "$line" | sed "s/^[[:space:]]*-[[:space:]]*//" | tr -d "'\"")
                    while IFS= read -r expanded_uri; do
                        [ -z "$expanded_uri" ] && continue
                        redirect_uris="${redirect_uris}          - '${expanded_uri}'\n"
                    done < <(halos_expand_oidc_redirect_uri "$uri")
                elif echo "$line" | grep -qE '^[a-z_]+:'; then
                    break
                fi
            fi
        done < "$snippet"

        # A client with no redirect_uris renders an empty YAML key, which
        # Authelia rejects at config load — taking every SSO route down rather
        # than just this client's logins.
        if [ -z "$redirect_uris" ]; then
            echo "  WARNING: Skipping ${snippet_name} - no usable redirect_uris (unsupported YAML shape?)"
            continue
        fi

        local scopes_line scopes
        scopes_line=$(grep -m1 -E '^scopes:' "$snippet")
        if echo "$scopes_line" | grep -qE '\[.*\]'; then
            scopes=$(echo "$scopes_line" | sed 's/scopes:[[:space:]]*//')
        else
            scopes="[openid, profile, email]"
        fi

        clients_yaml="${clients_yaml}      - client_id: ${client_id}
        client_name: '${client_name:-${client_id}}'
        client_secret: '${client_secret_hash}'
        public: false
        authorization_policy: one_factor
        redirect_uris:
$(echo -e "${redirect_uris}" | sed '/^$/d')
        scopes: ${scopes}
        consent_mode: ${consent_mode:-implicit}
        token_endpoint_auth_method: ${token_auth_method:-client_secret_post}
"
        client_count=$((client_count + 1))
    done

    if [ $render_failed -eq 1 ]; then
        if [ ! -f "$AUTHELIA_OIDC_FILE" ]; then
            # First run: no previous registration to keep, and the stack cannot
            # start without the file at all.
            _halos_oidc_write_empty "$AUTHELIA_OIDC_FILE"
            chmod 600 "$AUTHELIA_OIDC_FILE"
        fi
        echo "ERROR: OIDC client hashing failed - registration left unchanged" >&2
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp "${AUTHELIA_OIDC_FILE}.XXXXXX") || return 1
    # The temp file holds the HMAC secret and the signing key, and lives in the
    # directory bind-mounted as Authelia's /config.
    trap 'rm -f "$tmp_file"' RETURN
    chmod 600 "$tmp_file"

    # Writes are checked explicitly: this function runs as an `if` condition, so
    # errexit is disabled throughout its body and a failed write (a full /var on
    # an embedded device) would otherwise install a truncated config.
    if [ $client_count -eq 0 ]; then
        echo "  No OIDC client snippets found - OIDC will be disabled"
        _halos_oidc_write_empty "$tmp_file" || return 1
    else
        echo "  Merged ${client_count} OIDC client(s)"
        local indented_key
        indented_key=$(echo "${OIDC_PRIVATE_KEY}" | awk 'NR==1 {print} NR>1 {print "          " $0}')

        cat > "$tmp_file" << EOF || return 1
# Authelia OIDC Configuration
# Auto-generated from ${OIDC_CLIENTS_DIR} - do not edit
identity_providers:
  oidc:
    hmac_secret: '${OIDC_HMAC_SECRET}'
    jwks:
      - key: |
          ${indented_key}
    clients:
${clients_yaml}
EOF
    fi

    mv "$tmp_file" "$AUTHELIA_OIDC_FILE" || return 1
    trap - RETURN
}

# prestart and the path-triggered reload can run at once: an automatic service
# restart does not stop the path unit, and the tool is documented for manual
# use. Without serialization two renders interleave their rename and stamp
# writes and the stamp ends up describing neither.
#
# flock comes from util-linux, so it is always present on the Debian target; a
# developer machine without it just runs unserialized, which the tests do not
# depend on.
_halos_oidc_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"${AUTHELIA_OIDC_FILE}.lock"
    # Empty file, but it lives in Authelia's bind-mounted /config alongside
    # 0600 material; a stray world-readable artifact there invites the question.
    chmod 600 "${AUTHELIA_OIDC_FILE}.lock"
    flock 9
}

_halos_oidc_unlock() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>&-
}

_halos_oidc_require_globals() {
    local name
    for name in OIDC_CLIENTS_DIR AUTHELIA_OIDC_FILE OIDC_HMAC_SECRET OIDC_PRIVATE_KEY; do
        if [ -z "${!name:-}" ]; then
            echo "ERROR: ${name} is not set - lib-oidc-clients.sh caller contract violated" >&2
            return 1
        fi
    done
    # Without the hostname loader the digest would silently lose an input and
    # every redirect_uri would come out unexpanded.
    if ! declare -F halos_expand_oidc_redirect_uri >/dev/null; then
        echo "ERROR: lib-hostnames.sh must be sourced before lib-oidc-clients.sh" >&2
        return 1
    fi
}

# Merge the snippets into Authelia's registration, skipping the work when the
# inputs already match what was rendered AND applied. Sets HALOS_OIDC_CHANGED;
# the caller applies the result and then calls halos_oidc_commit.
halos_oidc_merge_clients() {
    HALOS_OIDC_CHANGED=0
    _halos_oidc_require_globals || return 1

    local stamp_file="${AUTHELIA_OIDC_FILE}.stamp"

    _halos_oidc_lock

    local input_digest output_digest
    input_digest="$(_halos_oidc_input_digest)"
    output_digest="$(_halos_oidc_output_digest || true)"

    # The stamp records the output digest too, so a registration that was
    # deleted, truncated or hand-edited is re-rendered rather than trusted.
    if [ "${HALOS_OIDC_FORCE:-0}" -eq 0 ] && [ -n "$output_digest" ] && [ -f "$stamp_file" ] &&
       [ "$(cat "$stamp_file")" = "${input_digest} ${output_digest}" ]; then
        _halos_oidc_unlock
        return 0
    fi

    echo "Merging OIDC client snippets..."
    if ! _halos_oidc_render; then
        # Drop the stamp so the next trigger retries rather than reading the
        # registration we failed to update as current.
        rm -f "$stamp_file"
        _halos_oidc_unlock
        return 1
    fi

    HALOS_OIDC_PENDING_DIGEST="$input_digest"
    HALOS_OIDC_CHANGED=1
    _halos_oidc_unlock
}

# Record the merge as applied. Called only once the rendered registration is
# live: before that, a crash or a failed restart must leave the next run work to
# redo rather than a stamp claiming the change already took effect.
halos_oidc_commit() {
    [ -n "${HALOS_OIDC_PENDING_DIGEST:-}" ] || return 0
    local stamp_file="${AUTHELIA_OIDC_FILE}.stamp"
    printf '%s %s\n' "$HALOS_OIDC_PENDING_DIGEST" "$(_halos_oidc_output_digest)" > "$stamp_file"
    chmod 600 "$stamp_file"
    HALOS_OIDC_PENDING_DIGEST=""
}
