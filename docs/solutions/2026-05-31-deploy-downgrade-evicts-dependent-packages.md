---
title: "Deploying a lower-versioned local build silently evicts dependent packages"
date: 2026-05-31
repo: halos-core-containers
tags: [deploy, apt, dpkg, downgrade, dependencies, marine, test-device, gotcha]
---

# Problem

After deploying `halos-core-containers` to a test device, the entire marine stack
(Signal K, AvNav, and their dashboard tiles) was gone — packages in `rc`
(config-files) state, services disabled, containers absent. Nothing in the
deploy targeted those packages.

On `halosdev.local` the eviction happened during this `apt` transaction:

```
Commandline: apt install -y --allow-downgrades /tmp/halos-core-containers_0.2.1-1_all.deb
Downgrade: halos-core-containers (0.4.1-3 → 0.2.1-1)
Remove: signalk-halpi, halos-halpi2-marine, halos-marine,
        marine-avnav-container, marine-signalk-server-container, halos-desktop-marine
```

# Root cause

The marine metapackages depend on a recent `halos-core-containers`. Installing a
**lower-versioned** build downgrades core below that floor, breaking the
dependency — and `apt` resolves the break by **removing the dependents**, not by
refusing the downgrade. With `-y` it does so silently.

The trap is the version of a *local* build. `./run build` stamps the `.deb` from
the committed `debian/changelog` (an arbitrary placeholder like `0.2.1-1`), which
is almost always **lower** than the CI-released version already installed
(`0.4.x`). So deploying a local dev build is usually a downgrade in disguise.

The current `./run deploy` flow is still exposed. It runs:

```
dpkg -i <deb>; apt-get -f install -y && systemctl restart ...
```

`dpkg -i` force-installs the downgrade; `apt-get -f install -y` then "fixes" the
broken dependency state — and removing the dependents is a valid fix it will take
without prompting. Same end result as `--allow-downgrades`.

# How to recognize

- Webapps vanish from the Homarr dashboard after a deploy.
- `dpkg -l | grep '^rc'` lists the evicted packages.
- The deploy's `/var/log/apt/history.log` entry contains a `Remove:` line.

# Mitigation

- **Test the CI artifact, not a local build.** Deploy the package CI published to
  `trixie-unstable` (`apt-get update && apt-get install halos-core-containers`),
  whose version moves monotonically upward. This avoids the downgrade entirely
  and is what should be tested anyway — the local `.deb` is not the released one.
- If a local build genuinely must be deployed, first bump its changelog above the
  installed version, or simulate the transaction (`apt-get -s -f install`, or
  `dpkg -i` then `apt-get -s -f install`) and abort if the plan contains any
  `Remove:`.

# Recovery

Reinstall the variant metapackage, plus any app packages that were added manually
(outside the metapackage's dependency tree — AvNav was a manual `apt install`, so
the metapackage does not pull it back):

```
sudo apt install halos-halpi2-marine marine-avnav-container halos-desktop-marine
```

Images remain on disk through an `rc`-state removal, so the containers come back
up without re-pulling. The `homarr-container-adapter` re-syncs the tiles on the
next run.
