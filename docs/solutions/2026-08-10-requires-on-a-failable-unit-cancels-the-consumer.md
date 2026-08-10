---
title: "Requires= on a unit that can fail cancels the consumer's start job"
date: 2026-08-10
repo: halos-core-containers
pr: https://github.com/halos-org/halos-core-containers/pull/215
tags: [systemd, requires, wants, oneshot, restart, backoff, boot, gotcha, knowledge]
---

# Context

`halos-core-containers.service` hard-required two `Type=oneshot` units that
produce its inputs:

```ini
Requires=docker.service halos-manage-certs.service halos-resolve-domain.service
```

If either oneshot exits non-zero, the stack does **not** fail. It is never
started at all: `journalctl -u halos-core-containers.service -b` is empty,
`systemctl show` reports `ActiveState=inactive` with `Result=success`, and
`systemctl --failed` does not list it — while Traefik, Authelia and Homarr are
all absent. The only visible failure is the dependency itself, which reads as a
bystander.

# What was measured

Scratch units in `/run/systemd/system` on a HALPI2 (systemd 257, Debian trixie):

| Setup | Result |
|---|---|
| consumer `Requires=` a oneshot that fails | consumer `inactive`, `Result=success`, `ExecMainStartTimestamp` empty — ExecStart never ran |
| same, but the oneshot has `Restart=on-failure` and succeeds on attempt 3 | oneshot reached success; **consumer still never ran** |
| consumer `Wants=` + `After=` a oneshot that fails | consumer `active`, started 1.8 ms after the dependency finished; failed dependency listed in `systemctl --failed` |

The second row is the counter-intuitive one, and it kills the obvious fix:
once a start job is cancelled, nothing re-queues it. Adding retries to the
dependency does not help the consumer.

# The rule

`Requires=` for a **runtime** the unit cannot execute without (here:
`docker.service`). `Wants=` + `After=` for a unit that **produces an input** —
plus a check in the consumer for the input it genuinely cannot run without, so
a missing input fails loudly in the consumer's own journal instead of rendering
an empty value.

# Restart limits are not the answer either

The first fix attempt added `StartLimitIntervalSec=300` / `StartLimitBurst=6`
so an unbootable stack would stop looping and reach `failed`. Two problems:

- **It makes failure permanent.** Nothing re-queues a start-limit `failed` unit
  — no `OnFailure=`, no timer. A cause that clears later (network arrives,
  docker daemon finishes restarting) then needs a human, on a headless device.
- **The window interacts with the start timeout.** systemd's rate limiter
  resets its counter when an attempt arrives more than `interval` after the
  window opened. With `TimeoutStartSec=600` and `RestartSec=10`, an attempt
  cycle is ~610 s, so no two attempts ever fall inside a 300 s window and the
  burst never fills — a *hanging* start loops forever anyway. A limit only
  bounds failures faster than `StartLimitIntervalSec / StartLimitBurst`.

Backing the retries off does the job without either flaw:

```ini
Restart=on-failure
RestartSec=10
RestartSteps=6
RestartMaxDelaySec=300
```

Retries forever (so it self-heals), with the delay doubling to a 5-minute
ceiling (so it stops hammering), and no coupling to `TimeoutStartSec`.
`RestartSteps=` / `RestartMaxDelaySec=` need systemd 254+; trixie ships 257.

# Diagnosis

A stack that is absent with an empty `journalctl -u <unit> -b` is this bug, not
a crash. Check `systemctl show <unit> -p Result` — `success` on a unit that
never ran means its job was cancelled, and the cause is a failed `Requires=`
dependency, which `systemctl --failed` will name.
