#!/usr/bin/env bash
# Tests for the PathRegexp rule in
# assets/traefik/dynamic/signalk-server-icons.yml
#
# Run from repo root:
#   bash tests/test-traefik-signalk-icons-regex.sh
#
# The rule decides which /signalk-server/* requests are served same-origin
# on :443 (static images) versus left to the priority-100 redirect router
# (navigation: HTML/JS/CSS). A regression here silently reproduces the
# cross-port cert-exception friction the router exists to remove, with no
# on-device signal. This test extracts the regex from the config itself so
# it stays coupled to the shipped rule, and evaluates it the way Traefik
# does: against the URL path only (query/fragment already stripped).
#
# Pure bash (POSIX ERE via [[ =~ ]]) to match the rest of the suite and
# avoid any external-tool dependency in CI. The rule's `(?i)` flag (which
# ERE does not interpret) is asserted separately, and case-insensitive
# matching is emulated by lowercasing the path before matching against the
# all-lowercase extension alternation — equivalent for this pattern.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$REPO_ROOT/assets/traefik/dynamic/signalk-server-icons.yml"

if [ ! -f "$CONFIG" ]; then
    echo "config not found at $CONFIG" >&2
    exit 2
fi

# Colors only when stdout is a TTY.
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; RESET=""
fi

PASSES=0
FAILS=0

# Pull the pattern out of `rule: 'PathRegexp(`<regex>`)'` — the regex is the
# text between the backticks. Extracting from the file (not hardcoding it)
# means this test guards the actual shipped rule.
REGEX="$(sed -n "s/.*PathRegexp(\`\(.*\)\`).*/\1/p" "$CONFIG")"
if [ -z "$REGEX" ]; then
    echo "could not extract PathRegexp from $CONFIG" >&2
    exit 2
fi

# ERE for [[ =~ ]]: strip the Go-RE2 `(?i)` inline flag (ERE can't parse it);
# case-insensitivity is handled by lowercasing the candidate path below.
ERE_REGEX="${REGEX#'(?i)'}"

# regex_matches <path> -> exit 0 if the rule matches the path, 1 otherwise.
regex_matches() {
    local lower
    lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    [[ "$lower" =~ $ERE_REGEX ]]
}

assert_match() {
    if regex_matches "$1"; then return 0; fi
    printf '    expected MATCH (serve on :443) but did not: %q\n' "$1" >&2
    return 1
}

assert_no_match() {
    if ! regex_matches "$1"; then return 0; fi
    printf '    expected NO match (redirect to :4430) but matched: %q\n' "$1" >&2
    return 1
}

run_test() {
    local name="$1"; local out
    if out=$("$name" 2>&1); then
        PASSES=$((PASSES + 1))
        printf '%sPASS%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAILS=$((FAILS + 1))
        printf '%sFAIL%s %s\n%s\n' "$RED" "$RESET" "$name" "$out"
    fi
}

# --- The case-insensitive contract is in the rule itself --------------------

test_rule_carries_case_insensitive_flag() {
    case "$REGEX" in
        '(?i)'*) return 0 ;;
        *) printf '    rule must start with the (?i) flag; got: %q\n' "$REGEX" >&2; return 1 ;;
    esac
}

# --- Should be served on :443 (static images) -------------------------------

test_canonical_homarr_icon_path() {
    assert_match "/signalk-server/@signalk/app-dock/app-icon.svg"
}

test_each_lowercase_extension() {
    assert_match "/signalk-server/icon.svg" || return 1
    assert_match "/signalk-server/icon.png" || return 1
    assert_match "/signalk-server/favicon.ico" || return 1
    assert_match "/signalk-server/photo.jpg" || return 1
    assert_match "/signalk-server/image.webp"
}

test_jpeg_gif_avif_extensions() {
    # .jpeg (not just .jpg), .gif, and .avif are real icon formats; missing
    # them sends those icons back through the cert-friction redirect.
    assert_match "/signalk-server/photo.jpeg" || return 1
    assert_match "/signalk-server/anim.gif" || return 1
    assert_match "/signalk-server/next.avif"
}

test_uppercase_extensions_match() {
    # Case-insensitive: a plugin shipping APP-ICON.SVG must not regress.
    assert_match "/signalk-server/@signalk/app-dock/APP-ICON.SVG" || return 1
    assert_match "/signalk-server/Icon.PNG" || return 1
    assert_match "/signalk-server/Photo.Jpeg"
}

test_nested_path_image() {
    assert_match "/signalk-server/a/b/c/deep.svg"
}

test_dotted_filename_image_is_served() {
    # A filename with dots before the extension still resolves to an image
    # request; Signal K applies its own (auth_mode: none -> OIDC) authz on
    # both :443 and :4430, so this is acceptable and intended to match.
    assert_match "/signalk-server/report.v1.2.svg"
}

# --- Should fall through to the :4430 redirect (navigation) ------------------

test_root_and_extensionless_paths_redirect() {
    assert_no_match "/signalk-server/" || return 1
    assert_no_match "/signalk-server/admin/" || return 1
    assert_no_match "/signalk-server/plugins"
}

test_html_js_css_redirect() {
    assert_no_match "/signalk-server/admin/index.html" || return 1
    assert_no_match "/signalk-server/admin/main.js" || return 1
    assert_no_match "/signalk-server/admin/style.css"
}

test_wrong_prefix_does_not_match() {
    assert_no_match "/other/icon.svg" || return 1
    # No slash boundary after "signalk-server": must not match.
    assert_no_match "/signalkserver/icon.svg"
}

run_test test_rule_carries_case_insensitive_flag
run_test test_canonical_homarr_icon_path
run_test test_each_lowercase_extension
run_test test_jpeg_gif_avif_extensions
run_test test_uppercase_extensions_match
run_test test_nested_path_image
run_test test_dotted_filename_image_is_served
run_test test_root_and_extensionless_paths_redirect
run_test test_html_js_css_redirect
run_test test_wrong_prefix_does_not_match

echo ""
echo "Passed: $PASSES   Failed: $FAILS"
[ "$FAILS" -eq 0 ]
