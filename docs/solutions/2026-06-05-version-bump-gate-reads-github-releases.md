---
title: "Judge the VERSION-bump gate against GitHub Releases, not local git tags"
date: 2026-06-05
repo: halos-core-containers
pr: https://github.com/halos-org/halos-core-containers/pull/193
tags: [release-versioning, version-bump-check, shared-workflows, git-tags, github-releases, ci-gate, gotcha, knowledge]
---

# Context

A package-affecting PR (#193) failed `version-bump-check`. Before pushing it I
had twice asserted — confidently, and again when challenged — that no bump was
needed. The reasoning used the wrong source for "latest stable release".

The repo-level rule (workspace `AGENTS.md`): bump `VERSION` only on the PR that
**opens a new release cycle** — i.e. when `VERSION` still equals the latest
stable release's base version. If `VERSION` is already ahead, a prior PR opened
the cycle and CI walks the `+N` revision automatically; no bump.

I read "latest stable" from `git tag`:

```
$ git tag --sort=-v:refname | grep -v _pre | head
v0.4.3+10
v0.4.2+8
```

That showed `0.4.3` as the latest stable base. `VERSION` was `0.4.4`, so I
concluded the `0.4.4` cycle was already open → no bump. Wrong.

The shared `version-bump-check` workflow does **not** use git tags. It calls:

```
gh release list --exclude-drafts --exclude-pre-releases --json tagName --jq '.[].tagName'
```

GitHub Releases showed a stable `v0.4.4+1`, published the day before:

```
$ gh release list --exclude-drafts --exclude-pre-releases --limit 2
v0.4.4+1   Latest   v0.4.4+1   2026-06-04T07:09:20Z
v0.4.3+10           v0.4.3+10  2026-06-02T13:50:37Z
```

So `VERSION` (`0.4.4`) **equaled** the latest stable base (`0.4.4`), and this
PR was the one opening the `0.4.5` cycle — a bump was mandatory. My local
checkout simply never had the `v0.4.4+1` stable tag (only `v0.4.4+1_pre`), so
`git tag` gave a stale answer. The workflow uses `gh release list` deliberately:
a comment in it notes draft releases create tags that should not count as
stable, so tags are an unreliable proxy. Local tags are unreliable for a second
reason — they are only as fresh as the last `git fetch --tags`.

# Resolution

Read "latest stable release" from the same source the gate uses:

```
gh release list --repo halos-org/<repo> --exclude-drafts --exclude-pre-releases --limit 5
```

Then apply the rule:

- Strip the `+N` to get the stable **base** (`v0.4.4+1` → `0.4.4`).
- `VERSION` **equals** that base **and** the PR changes package-affecting files
  → this PR opens the cycle → **bump** (`./run bumpversion patch`).
- `VERSION` is **ahead** of that base → cycle already open → **no bump**; CI
  walks `+N`.

The `+N` revision is the release version walked across GitHub Releases, not a
`debian/changelog` artifact — so Releases is the authoritative state, and a
stale or draft-polluted local tag list misleads in either direction.

# Why it matters

The gate has a sharp, conditional answer, and the cheap-but-wrong source
(`git tag`) and the authoritative source (`gh release list`) disagree exactly at
the cycle boundary — the one moment the answer flips from "no bump" to "bump
required". Reading the wrong source produces a confident wrong answer precisely
when it costs a red check.

Second, a process lesson: when the human pushed back ("isn't a bump
mandatory?"), I re-derived from the same stale source and doubled down instead
of re-checking against the authoritative one. A challenge to a factual claim is
a cue to re-run the check from the source of truth, not to restate the prior
reasoning more firmly.

# When it applies

- Any package-affecting PR in a repo wired to shared-workflows
  `version-bump-check`. Answer "does this need a VERSION bump?" from
  `gh release list`, not memory and not `git tag`.
- Confirm the changed-file set against the workflow's exclusion globs before
  assuming "docs/tooling only" — the `run` script and root `docker-compose.yml`
  are **not** excluded; `apps/*/metadata.yaml` is a separate per-PR rule.

# Related

- `shared-workflows/.github/workflows/version-bump-check.yml` — the gate; reads
  `gh release list --exclude-pre-releases`, strips `+N`, compares to `VERSION`.
- Workspace `AGENTS.md` "Version Bumps" — the per-release-cycle policy this
  operationalizes.
- This PR also added the missing `./run bumpversion` target so the bump runs
  through the sanctioned tool instead of a hand-edit.
