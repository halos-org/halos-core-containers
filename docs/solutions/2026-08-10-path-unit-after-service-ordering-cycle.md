---
title: "A .path unit with After= on a service closes a boot ordering cycle"
date: 2026-08-10
repo: halos-core-containers
pr: https://github.com/halos-org/halos-core-containers/pull/209
tags: [systemd, path-units, default-dependencies, ordering-cycle, boot, container-apps, gotcha, knowledge]
---

# Context

`halos-oidc-clients-reload.path` watches `/etc/halos/oidc-clients.d` and should
only watch while the core stack is up, so it was given the obvious pair:

```ini
PartOf=halos-core-containers.service
After=halos-core-containers.service
```

Every device flashed with the image carrying that unit booted without Traefik,
Authelia or Homarr. `systemctl is-active halos-core-containers.service` said
`inactive`, and `journalctl -u halos-core-containers.service -b` was **empty** —
the unit had never been given a job. The only visible failure was a different
unit: `halos-oidc-clients-reload.service`, reporting "Authelia secrets not
found ... Start halos-core-containers first".

# The mechanism

`systemd.path(5)`: unless `DefaultDependencies=no` is set, a path unit gets
`Before=paths.target`, `After=`/`Requires=sysinit.target`, and
`Conflicts=`/`Before=shutdown.target`. An ordinary service gets
`After=basic.target`, and `basic.target` is after `paths.target`. So the
explicit `After=` on the service closes a loop:

```
<service> → basic.target → paths.target → <watcher>.path → <service>
```

systemd does not fail a cycle; it deletes an arbitrary job to break one and logs
it:

```
Found ordering cycle on halos-manage-certs.service/start
Found dependency on basic.target/start
Found dependency on paths.target/start
Found dependency on halos-oidc-clients-reload.path/start
Found dependency on halos-core-containers.service/start
Job halos-manage-certs.service/start deleted to break ordering cycle starting with halos-core-containers.service/start
```

The deleted job was a `Requires=` of the stack, so the stack got no job either.
Which job systemd picks is arbitrary — a different unit set breaks elsewhere,
which is why the symptom points away from the unit that is actually wrong.

# The rule

**Nothing about that unit was special.** Any `.path` unit that declares `After=`
on an ordinary service closes this loop, in any package. The same shape is
emitted by `container-packaging-tools`' `systemd/path.j2` for every app that
declares a `file_watcher`.

When a watcher must not arm before its service, opt out of the default
dependencies and restore what the opt-out drops other than the `paths.target`
edge:

```ini
After=<service>
DefaultDependencies=no
After=sysinit.target
Conflicts=shutdown.target
Before=shutdown.target
```

Dropping the `After=` on the service also breaks the cycle, and the triggered
`.service` carries its own ordering — but then `PartOf=`'s restart of the
watcher is unordered against the service it watches.

# Diagnosis

`journalctl -b | grep -i "ordering cycle"` on the device. The named units are
the cycle members; the unit whose job was deleted is the one to look at, and
the unit that fails loudly is usually a bystander.

# Detection

`systemd-analyze verify` does **not** catch this: a cycle exists only in a job
transaction, not in a unit file. `tests/test-packaging-contract.sh` pins the
invariant statically instead — every `debian/*.path` with an `After=` on a
`.service` must carry `DefaultDependencies=no` plus the shutdown pair.
