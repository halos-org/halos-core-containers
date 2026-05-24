---
title: "Grep-against-`openssl x509 -text` is defeated by Subject/Issuer DN content"
date: 2026-05-25
repo: halos-core-containers
pr: https://github.com/halos-org/halos-core-containers/pull/134
tags: [openssl, x509, security, cert-validation, substring-injection, gotcha, knowledge]
---

# Context

`halos_ca_validate_pair` in `assets/lib-ca.sh` (Unit 2 of #129) gates "is this an acceptable device CA?" on two extension checks. The first cut shipped these as substring greps against the full cert dump:

```bash
local crt_text
crt_text=$(openssl x509 -in "$crt" -noout -text)
printf '%s' "$crt_text" | grep -q 'CA:TRUE'         # basicConstraints check
printf '%s' "$crt_text" | grep -q 'Certificate Sign' # keyUsage keyCertSign check
```

Looks plausible — both strings are openssl's human-readable extension values, they should only appear inside the extension blocks. The inline comment even claimed it: *"CA:TRUE marker only appears in basicConstraints; safe substring check."*

The claim is wrong. `openssl x509 -text` prints the entire decoded cert, including the Subject DN and Issuer DN verbatim. A leaf cert whose subject is `/CN=Evil/O=CA:TRUE Inc, Certificate Sign Co` produces output containing both literal strings on the Subject and Issuer lines, even when basicConstraints is actually `CA:FALSE`. Both substring greps fire on the DN, the function returns success, and the leaf gets accepted as the active signing CA. Downstream, `halos_ca_sign_leaf` then "signs" with a non-CA private key, producing a chain no compliant verifier will trust.

Discovered during ce:review of PR #134 by three independent reviewers (security, correctness, adversarial), all of whom reproduced it end-to-end against the unfixed code.

# Guidance

**Never grep against `openssl x509 -text` for security-relevant decisions.** The decoded output includes attacker-controlled fields (Subject DN, Issuer DN, extensions a CA might custom-encode). Use `openssl x509 -ext <name>` to get a scoped rendering of exactly one extension, then grep within that:

```bash
# CA:TRUE check — only basicConstraints body is emitted, DNs are excluded
if ! openssl x509 -in "$crt" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE'; then
    return 1
fi

# keyCertSign check — only keyUsage body is emitted
if ! openssl x509 -in "$crt" -noout -ext keyUsage 2>/dev/null | grep -q 'Certificate Sign'; then
    return 1
fi
```

`-ext <name>` is in OpenSSL 1.1.1+ (well below the Debian trixie 3.5 baseline). For older targets, parse the ASN.1 directly with `openssl asn1parse` rather than greping `-text`.

# Why this class of bug recurs

The general pattern: any "is this thing trustworthy?" check that runs `tool -text-dump | grep marker` is vulnerable to the marker appearing in any attacker-controlled field the tool also dumps. Cert validation is the canonical case, but the same shape applies to:

- `kubectl get -o yaml | grep` against resources where annotation values are user-controlled
- `gh api repo | grep` against fields that include user-provided text (descriptions, branch names)
- `ldapsearch | grep` against entries where attribute values can be set by the same user being checked

Whenever a check is implemented as `dump-then-grep`, the dump tool's structure determines whether attacker text can satisfy the grep. The fix is always the same shape: ask the tool for *only the field you care about*, not the whole record.

# Defense-in-depth

The substring check is the syntactic layer. Even after switching to `-ext`, the validation function still:

- Parses the cert (`openssl x509 -noout`) to confirm it's well-formed before any extension query
- Verifies the key matches the cert via derived-pubkey comparison (`openssl pkey -pubout` vs `openssl x509 -pubkey`)
- Checks remaining validity against a custom-CA threshold (separate from the auto-CA rotation threshold)

The key-match step is what would have caught the attack in the worst case — a leaf cert with a forged DN still has a different keypair than what the operator dropped — so the actual operational impact of the original bug was bounded to "operator dropped a leaf they actually owned the key for, expecting it to work as a CA." Still a real defect, just not a remote-attacker vulnerability.

# Where this bites in HaLOS

Any future `halos_*_validate_*` helper that wraps openssl/kubectl/gh/etc. and runs substring greps against `-text`/`-o yaml`/`--json` output. The convention going forward:

1. Ask the tool for the specific field (`-ext`, `-o jsonpath=...`, `--jq '...'`).
2. Validate the field's shape against a known schema before any predicate.
3. Treat the dump-then-grep pattern as a code smell that needs justification.

# References

- OpenSSL `x509(1)` manual — `-ext` flag (added in 1.1.1)
- RFC 5280 §4.2.1.9 (basicConstraints), §4.2.1.3 (keyUsage)
- Related: [set-e-cmdsubst-blind-spot.md](2026-05-24-set-e-cmdsubst-blind-spot.md) — separate bash gotcha that also bit lib-ca.sh
