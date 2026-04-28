---
title: "Bash command-substitution subshells defeat per-call global caching"
date: 2026-04-28
repo: halos-core-containers
pr: https://github.com/halos-org/halos-core-containers/pull/123
tags: [bash, subshell, caching, performance, prestart, gotcha, knowledge]
---

# Context

`lib-hostnames.sh` exposes a `_halos_resolve_domain` helper that shells out to `hostname -d` and `nmcli` to discover the device's DNS domain at service start. The function caches its result in a global `HALOS_HOSTNAMES_DOMAIN_CACHE` so all per-line expansions in `halos_load_hostnames` share a single resolver call:

```bash
_halos_resolve_domain() {
    if [ -n "${HALOS_HOSTNAMES_DOMAIN_CACHE+set}" ]; then
        printf '%s' "$HALOS_HOSTNAMES_DOMAIN_CACHE"
        return 0
    fi
    # ... actually resolve ...
    HALOS_HOSTNAMES_DOMAIN_CACHE="$d"
    printf '%s' "$d"
}
```

Intent: one `nmcli` invocation per `halos_load_hostnames` call. The `nmcli` call is wrapped in `timeout 2`, so worst-case = 2s. With 16 lines in `hostnames.conf`, the cache is the difference between 2s and 32s of prestart delay.

# Guidance

**In bash, `result=$(helper "$x")` runs `helper` in a subshell.** Globals written inside the subshell vanish when it exits. So this pattern doesn't cache:

```bash
halos_load_hostnames() {
    while IFS= read -r raw; do
        # Each iteration spawns a subshell; cache write inside _halos_expand_line
        # → _halos_resolve_domain is lost when the subshell exits.
        expanded="$(_halos_expand_line "$line")"
        ...
    done < "$file"
}
```

**Fix: prime the cache in the parent process before the loop.** Subshells inherit the parent's environment, so they read the cached value rather than re-resolving:

```bash
halos_load_hostnames() {
    unset HALOS_HOSTNAMES_DOMAIN_CACHE
    _halos_resolve_domain >/dev/null    # primes the cache in THIS process
    while IFS= read -r raw; do
        expanded="$(_halos_expand_line "$line")"   # subshell inherits cache, no re-resolve
        ...
    done < "$file"
}
```

# Why This Matters

The bug is invisible to obvious testing strategies:

- **Functional output is correct.** Every subshell re-resolves and produces the right answer.
- **Shell-variable counters can't catch it.** A test that increments `_call_count` inside the helper and checks the count afterwards reads zero — because the increment also happened in a subshell. The test passes for the wrong reason.
- **Performance is the only symptom.** On a healthy LAN with a fast `hostname -d`, the duplicated calls are too quick to notice. Once `nmcli` is wrapped in `timeout 2` (because NetworkManager can hang), the cost compounds linearly.

The same trap applies to any pattern that mixes per-line `$(...)` with global state:

- `<(...)` (process substitution) — also a subshell.
- `cmd | while read x; do ...; done` in bash without `shopt -s lastpipe` — the `while` runs in a subshell.
- `(...)` explicit subshells — by definition.

# When to Apply

Audit any bash function that:

1. Caches expensive work in a shell global, AND
2. Is called from inside command substitution, process substitution, or a piped `while` loop.

Either prime the cache in the calling parent before the substitution-bearing loop, or pass the cached value explicitly as a function argument so it doesn't depend on globals at all.

# Examples

**Detection via file-counter test.** A robust test for "resolver called exactly once per load" needs a counter that survives subshells. A file works:

```bash
_resolver_counting() {
    echo >> "${_RESOLVER_COUNT_FILE:-/dev/null}"
    printf 'example.com'
}

test_resolver_cache_prevents_repeated_calls() {
    local counter="$TMPDIR_ROOT/r-count.tally"
    : > "$counter"
    write_conf "$f" '${fqdn}' '${domain}' '${hostname}.${domain}'
    _RESOLVER_COUNT_FILE="$counter"
    HALOS_DOMAIN_RESOLVER=_resolver_counting
    halos_load_hostnames
    local n; n="$(wc -l < "$counter" | tr -d ' ')"
    assert_eq "$n" "1" "resolver should be called exactly once per load"
}
```

This test surfaced the bug; a shell-variable counter would have happily reported 0 (which equals 0 calls or 16 calls — indistinguishable).

**Equivalent failure mode in piped reads.** This loop runs in a subshell because of the pipe; `count` reverts to 0 after the loop:

```bash
count=0
ls | while read f; do count=$((count + 1)); done
echo "$count"   # prints 0
```

Fixes: process substitution `done < <(ls)`, or `shopt -s lastpipe` in bash 4.2+.

# Related

- PR halos-org/halos-core-containers#123 — feat: `${fqdn}` and `${domain}` template tokens
- `halos-core-containers/assets/lib-hostnames.sh` — `_halos_resolve_domain`, `halos_load_hostnames` cache priming
- `halos-core-containers/tests/test-lib-hostnames.sh` — `test_resolver_cache_prevents_repeated_calls`
- BashGuide §"Why doesn't my variable work?" / Bash FAQ E4 — the canonical write-up of the subshell-scope trap
