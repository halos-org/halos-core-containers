---
title: "NEXTAUTH_URL forces canonical Host on every NextAuth redirect, defeating multi-hostname access"
date: 2026-05-27
repo: halos-core-containers
issue: https://github.com/halos-org/halos/issues/117
tags: [homarr, nextauth, authjs, multi-host, sso, oidc, reverse-proxy]
---

# Problem

After multi-hostname support shipped (Traefik path-only routing, per-host Authelia cookies, per-host OIDC redirect_uris, Homarr fork with header-driven URL construction), browsing Homarr on a non-canonical hostname and logging in still teleported the user to the canonical hostname (`${hostname}.local`). The OIDC issuer hop to canonical is expected (single-issuer constraint); the post-login redirect back to the originating host is not.

Symptom: every redirect generated server-side by NextAuth used the canonical Host regardless of the request's `x-forwarded-host`.

# Root Cause

`docker-compose.yml` set `NEXTAUTH_URL=https://${HALOS_DOMAIN}` (canonical). Two next-auth code paths consume that env var and override request-driven URL construction:

1. `next-auth/lib/env.js` `reqWithEnvURL(req)` rewrites the request URL's origin to match `AUTH_URL ?? NEXTAUTH_URL` before any handler logic runs. Called from `next-auth/index.js` on every GET/POST to the `/api/auth/*` route, and from `lib/index.js` `handleAuth` for middleware-style auth.

2. `@auth/core/lib/utils/env.js` `createActionURL(...)` prefers `AUTH_URL ?? NEXTAUTH_URL` over `x-forwarded-host`/`host` headers when constructing internal URLs (session endpoints, signin URLs, callback URLs). Used by `getSession` for server-side `auth()` calls in RSCs.

The Homarr fork's `reqWithTrustedOrigin(req)` rewrite in `apps/nextjs/src/app/api/auth/[...nextauth]/route.ts` correctly substitutes `x-forwarded-host`/`x-forwarded-proto` into the request URL before passing it to NextAuth, but `reqWithEnvURL` is called next inside NextAuth's own handler and silently undoes that work whenever the env var is set. Setting `trustHost: true` in the NextAuth config (which Homarr does) is necessary but not sufficient — `trustHost` controls validation, not URL construction precedence.

# Solution

Unset `NEXTAUTH_URL` (and `AUTH_URL`). With `trustHost: true`, NextAuth derives the base URL from the request headers per call, which is exactly what multi-hostname access requires. The Homarr fork's per-request OIDC `redirect_uri` and `redirectProxyUrl` (both built from headers via `createRedirectUri`) then function as designed, and `createActionURL` falls through to the `x-forwarded-host` branch.

The OIDC issuer URL is still pinned to canonical via `AUTH_OIDC_ISSUER=https://${HALOS_DOMAIN}/sso`, satisfying the single-issuer constraint without leaking canonical into post-auth redirects. The container's `extra_hosts: "${HALOS_DOMAIN}:host-gateway"` entry stays — Homarr's server-side OIDC discovery call still resolves the issuer hostname.

# Lessons

- For NextAuth/Auth.js v5 behind a reverse proxy serving multiple hostnames, `NEXTAUTH_URL` and `AUTH_URL` must remain unset. `trustHost: true` alone is not enough; the env URL overrides take precedence over request headers in two separate code paths.
- The fork's per-request URL rewriter (`reqWithTrustedOrigin`) is necessary because Next.js's `NextRequest.nextUrl.origin` reflects the container-internal listen address, not the public Host. With `NEXTAUTH_URL` unset, that rewriter is what makes header-driven URL construction work end-to-end.
- Future regression test: any new env var that next-auth or `@auth/core` reads with `AUTH_*` / `NEXTAUTH_*` naming is potential for the same class of bug. Grep `node_modules/next-auth` for `process.env.AUTH_` references when upgrading next-auth or auth.js.
