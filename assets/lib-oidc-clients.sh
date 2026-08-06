#!/bin/bash
# Shared Authelia OIDC client-registration merger.
#
# Sourced by prestart.sh (renders before the stack comes up) and by
# reload-oidc-clients (re-renders while it is running). One implementation on
# purpose: the two copies this replaced drifted, and the copy in the
# standalone tool spent months writing to a path Authelia never read.
#
# Caller contract — set these before calling halos_oidc_merge_clients:
#   OIDC_CLIENTS_DIR    directory of client snippets
#   AUTHELIA_OIDC_FILE  rendered registration Authelia loads
#   OIDC_HMAC_SECRET    from the Authelia secrets file
#   OIDC_PRIVATE_KEY    JWKS signing key (PEM text)
# lib-hostnames.sh must already be sourced with halos_load_hostnames run:
# redirect_uris expansion goes through halos_expand_oidc_redirect_uri.
#
# After the call, HALOS_OIDC_CHANGED is 1 when the registration was rewritten
# and 0 when the inputs matched what is already on disk. Callers that need
# Authelia to pick the change up gate their restart on it.

# Rendered-output format. Mixed into the change-detection stamp so a package
# that changes the output cannot inherit an old stamp and call a registration
# in the previous format current. Bump on any change to the rendered YAML.
HALOS_OIDC_RENDER_VERSION=1

# Read one top-level scalar field from a snippet.
halos_oidc_snippet_field() {
    local snippet="$1" key="$2"
    grep -E "^${key}:" "$snippet" | sed "s/${key}:[[:space:]]*//" | tr -d "'\""
}

# Hash a plaintext client secret with Authelia's own CLI. Every call salts
# afresh, so the output is never comparable between runs — change detection
# works off the inputs (see _halos_oidc_input_digest), never the rendered hash.
halos_oidc_hash_secret() {
    local plaintext="$1" hash_output
    if ! hash_output=$(docker run --rm authelia/authelia:4.39 authelia crypto hash generate pbkdf2 \
        --variant sha512 \
        --password "${plaintext}" 2>/dev/null); then
        return 1
    fi
    printf '%s\n' "$hash_output" | grep 'Digest:' | sed 's/Digest: //'
}

# Digest of everything the rendered registration derives from. A snippet whose
# text never changes still lands here through its secret file's contents —
# that is the rotation case that silently broke OIDC for four days (#201).
_halos_oidc_input_digest() {
    {
        printf 'render-version=%s\n' "$HALOS_OIDC_RENDER_VERSION"
        printf 'hmac=%s\n' "$OIDC_HMAC_SECRET"
        printf 'key=%s\n' "$OIDC_PRIVATE_KEY"
        printf 'hostnames=\n'
        halos_dns_hostnames

        local snippet secret_file
        for snippet in "${OIDC_CLIENTS_DIR}"/*.yml; do
            [ -e "$snippet" ] || continue
            printf 'snippet=%s\n' "$snippet"
            cat "$snippet"
            secret_file="$(halos_oidc_snippet_field "$snippet" client_secret_file)"
            if [ -n "$secret_file" ] && [ -f "$secret_file" ]; then
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

# Write the registration Authelia loads when there is nothing to register.
# The file cannot simply be omitted: docker-compose.yml names it in
# X_AUTHELIA_CONFIG, and Authelia will not start without a config it lists.
_halos_oidc_write_empty() {
    cat > "$1" << 'EOF'
# Authelia OIDC Configuration - No clients configured
EOF
}

# Render the registration from the current snippets. Writes through a
# same-directory temp file: Authelia refuses to start on a truncated config,
# so it must never observe a partial write.
#
# Returns non-zero when a client could not be hashed. Hashing runs the Authelia
# image, so it fails for reasons that have nothing to do with the snippets —
# and dropping a client from the registration breaks exactly the logins this
# mechanism exists to keep working. A failed render therefore leaves the
# previous registration in place for the caller to keep.
_halos_oidc_render() {
    local client_count=0
    local clients_yaml=""
    local hash_failed=0
    local snippet snippet_name

    for snippet in "${OIDC_CLIENTS_DIR}"/*.yml; do
        [ -e "$snippet" ] || continue
        snippet_name=$(basename "$snippet")
        echo "  Processing: ${snippet_name}"

        local client_id client_name client_secret_file consent_mode token_auth_method
        client_id=$(halos_oidc_snippet_field "$snippet" client_id)
        client_name=$(halos_oidc_snippet_field "$snippet" client_name)
        client_secret_file=$(halos_oidc_snippet_field "$snippet" client_secret_file)
        consent_mode=$(halos_oidc_snippet_field "$snippet" consent_mode)
        token_auth_method=$(halos_oidc_snippet_field "$snippet" token_endpoint_auth_method)

        [ -z "$client_id" ] && { echo "  WARNING: Skipping ${snippet_name} - missing client_id"; continue; }

        local client_secret_hash=""
        if [ -n "$client_secret_file" ] && [ -f "$client_secret_file" ]; then
            local plaintext_secret
            plaintext_secret=$(cat "$client_secret_file")
            if ! client_secret_hash=$(halos_oidc_hash_secret "$plaintext_secret"); then
                echo "  ERROR: Failed to hash client secret for ${snippet_name}" >&2
                hash_failed=1
                continue
            fi
        else
            echo "  WARNING: Skipping ${snippet_name} - client_secret_file not found: ${client_secret_file}"
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

        local scopes_line scopes
        scopes_line=$(grep -E '^scopes:' "$snippet")
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

    if [ $hash_failed -eq 1 ]; then
        if [ ! -f "$AUTHELIA_OIDC_FILE" ]; then
            # First run: there is no previous registration to keep, and the
            # stack cannot start without the file at all.
            _halos_oidc_write_empty "$AUTHELIA_OIDC_FILE"
            chmod 600 "$AUTHELIA_OIDC_FILE"
        fi
        echo "ERROR: OIDC client hashing failed - registration left unchanged" >&2
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp "${AUTHELIA_OIDC_FILE}.XXXXXX")
    chmod 600 "$tmp_file"

    if [ $client_count -eq 0 ]; then
        echo "  No OIDC client snippets found - OIDC will be disabled"
        _halos_oidc_write_empty "$tmp_file"
    else
        echo "  Merged ${client_count} OIDC client(s)"
        local indented_key
        indented_key=$(echo "${OIDC_PRIVATE_KEY}" | awk 'NR==1 {print} NR>1 {print "          " $0}')

        cat > "$tmp_file" << EOF
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

    mv "$tmp_file" "$AUTHELIA_OIDC_FILE"
}

# Merge the snippets into Authelia's registration, skipping the work when the
# inputs already match what was rendered. Sets HALOS_OIDC_CHANGED.
halos_oidc_merge_clients() {
    HALOS_OIDC_CHANGED=0

    local stamp_file="${AUTHELIA_OIDC_FILE}.stamp"
    local input_digest output_digest
    input_digest="$(_halos_oidc_input_digest)"
    output_digest="$(_halos_oidc_output_digest || true)"

    # The stamp records the output digest too, so a registration that was
    # deleted, truncated or hand-edited is re-rendered rather than trusted.
    if [ -n "$output_digest" ] && [ -f "$stamp_file" ] &&
       [ "$(cat "$stamp_file")" = "${input_digest} ${output_digest}" ]; then
        echo "OIDC client registration already current"
        return 0
    fi

    echo "Merging OIDC client snippets..."
    if ! _halos_oidc_render; then
        # Drop the stamp so the next trigger retries rather than reading the
        # registration we failed to update as current.
        rm -f "$stamp_file"
        return 1
    fi

    printf '%s %s\n' "$input_digest" "$(_halos_oidc_output_digest)" > "$stamp_file"
    chmod 600 "$stamp_file"
    HALOS_OIDC_CHANGED=1
}
