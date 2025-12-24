# HaLOS SSO - System Architecture

**Version**: 2.0
**Date**: 2025-12-23
**Status**: Draft

## System Overview

The SSO architecture provides unified authentication for all HaLOS web applications. Applications are accessed via subdomains and protected by either Forward Auth (default) or OIDC.

```
                      mDNS/Avahi (*.{hostname}.local)
                                  │
                                  v
┌─────────────────────────────────────────────────────────────────┐
│                     Traefik (Port 80, 443)                      │
│  - Docker provider (label-based routing)                        │
│  - ForwardAuth middleware for protected apps                    │
│  - Shared network: halos-proxy-network                          │
└─────────────────────────────────────────────────────────────────┘
         │              │              │              │
         v              v              v              v
   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
   │  Homarr  │   │ Grafana  │   │ InfluxDB │   │ Signal K │
   │  (OIDC)  │   │ (FwdAuth)│   │ (FwdAuth)│   │(host net)│
   └──────────┘   └──────────┘   └──────────┘   └──────────┘
         │              │              │              │
         └──────────────┴──────────────┴──────────────┘
                                  │
                                  v
                          ┌────────────┐
                          │  Authelia  │
                          │ (OIDC+FA)  │
                          └────────────┘
```

## Components

### Traefik Reverse Proxy

**Image**: `traefik:v3.6`
**Network**: `halos-proxy-network` (bridge, owned by this container)
**Ports**: 80 (HTTP), 443 (HTTPS)

Traefik is the central routing component. It receives all incoming HTTP/HTTPS requests and routes them to the appropriate backend based on the `Host` header.

**Key responsibilities**:
- Create and own the shared Docker network
- Watch Docker daemon for container labels
- Route requests based on `Host` header rules
- Apply ForwardAuth middleware for protected routes
- TLS termination for HTTPS

**Configuration approach**:
- Static configuration loaded from mounted file
- Dynamic configuration from Docker labels (per-app routing)
- File provider for Authelia middleware and per-app middleware customizations

### Authelia Identity Provider

**Image**: `authelia/authelia:4.39`
**Network**: `halos-proxy-network` (external)
**Ports**: None exposed (accessed via Traefik)

Authelia provides both OIDC provider and Forward Auth functionality.

**Key responsibilities**:
- Authenticate users against file-based user database
- Issue OIDC tokens to client applications
- Provide Forward Auth endpoint for non-OIDC applications
- Manage user sessions with secure cookies

**Configuration files**:
- `configuration.yml` - Base configuration (session, auth backend, access control)
- `oidc-clients.yml` - OIDC client definitions (regenerated when apps change)
- `users_database.yml` - User credentials (argon2id hashes)

**Note**: `configuration.yml` is regenerated from a template on every Authelia restart to handle hostname/domain changes. Manual edits to this file will be overwritten. For customization, modify the template in the package or use environment variable overrides where supported.

**Data storage**:
- Session data: SQLite database
- OIDC keys: RSA private key for JWT signing

### mDNS Publisher

**Image**: `ghcr.io/hatlabs/halos-mdns-publisher:latest`
**Network**: Host network mode (required for mDNS)
**Ports**: None

The mDNS publisher enables subdomain resolution on local networks without DNS infrastructure.

**Key responsibilities**:
- Monitor Docker daemon for container events
- Read `halos.subdomain` labels from containers
- Run `avahi-publish` for each subdomain
- Clean up registrations when containers stop

**Implementation approach**:
- Dedicated container image built from Alpine base
- Pre-installed: docker-cli, avahi-tools, jq
- Shell script using `docker events` for monitoring
- One `avahi-publish` process per subdomain
- Process management via shell job control

### Application Containers

Applications integrate with SSO based on their declared authentication mode:

**Forward Auth apps** (default):
- Join `halos-proxy-network`
- Traefik labels for routing
- ForwardAuth middleware applied automatically
- Receive user identity via HTTP headers

**OIDC apps** (e.g., Homarr):
- Join `halos-proxy-network`
- Traefik labels for routing (no ForwardAuth middleware)
- OIDC client registered in Authelia
- Handle OIDC flow directly with Authelia

**No-auth apps**:
- Join `halos-proxy-network`
- Traefik labels for routing (no middleware)
- Publicly accessible on LAN

**Host networking apps** (e.g., Signal K):
- Use `network_mode: host`
- Traefik routes to host IP:port
- Can still use ForwardAuth or no-auth
- Also accessible via direct port

## Network Architecture

### halos-proxy-network

A Docker bridge network created and owned by the Traefik container.

**Properties**:
- Driver: bridge
- Name: halos-proxy-network
- Scope: local

**Membership**:
- traefik (owner)
- authelia (member)
- All proxied application containers (members)

### Host Network Access

Two cases require host network interaction:
1. **mDNS Publisher**: Uses host network mode to access Avahi daemon
2. **Host networking apps**: Traefik routes to `host.docker.internal` or host IP

## Data Flows

### Forward Auth Flow

Most applications use Forward Auth for authentication:

```
┌────────┐     ┌─────────┐     ┌──────────┐     ┌─────────┐
│ Browser│────>│ Traefik │────>│ Authelia │     │   App   │
└────────┘     └─────────┘     └──────────┘     └─────────┘
     │              │               │                │
     │  1. GET grafana.boat.local   │                │
     │─────────────>│               │                │
     │              │ 2. ForwardAuth│                │
     │              │──────────────>│                │
     │              │   3. 401 + redirect            │
     │              │<──────────────│                │
     │  4. Redirect to auth.boat.local               │
     │<─────────────│               │                │
     │  5. Login form               │                │
     │─────────────────────────────>│                │
     │  6. POST credentials         │                │
     │─────────────────────────────>│                │
     │  7. Set session cookie + redirect             │
     │<─────────────────────────────│                │
     │  8. GET grafana.boat.local (with cookie)      │
     │─────────────>│               │                │
     │              │ 9. ForwardAuth│                │
     │              │──────────────>│                │
     │              │  10. 200 + headers             │
     │              │<──────────────│                │
     │              │ 11. Forward with Remote-User   │
     │              │───────────────────────────────>│
     │              │               │   12. Response │
     │              │<───────────────────────────────│
     │ 13. Response │               │                │
     │<─────────────│               │                │
```

### OIDC Flow

Applications with native OIDC support (e.g., Homarr):

```
┌────────┐     ┌─────────┐     ┌──────────┐     ┌─────────┐
│ Browser│────>│ Traefik │────>│ Authelia │     │ Homarr  │
└────────┘     └─────────┘     └──────────┘     └─────────┘
     │              │               │                │
     │  1. GET boat.local           │                │
     │─────────────>│───────────────────────────────>│
     │              │               │  2. No session │
     │  3. Redirect to auth.boat.local/oidc/auth     │
     │<──────────────────────────────────────────────│
     │  4. Authorization request    │                │
     │─────────────────────────────>│                │
     │  5. Login (if no session)    │                │
     │<────────────────────────────>│                │
     │  6. Redirect with auth code  │                │
     │<─────────────────────────────│                │
     │  7. GET boat.local/callback?code=...          │
     │─────────────>│───────────────────────────────>│
     │              │               │  8. Token exchange
     │              │               │<───────────────│
     │              │               │  9. Tokens     │
     │              │               │───────────────>│
     │              │               │ 10. Create session
     │ 11. Redirect to dashboard    │                │
     │<──────────────────────────────────────────────│
```

### Host Networking App Flow

For apps like Signal K that require host networking:

```
┌────────┐     ┌─────────┐     ┌──────────┐     ┌──────────────┐
│ Browser│────>│ Traefik │────>│ Authelia │     │Signal K:3000 │
└────────┘     └─────────┘     └──────────┘     │  (host net)  │
     │              │               │           └──────────────┘
     │  1. GET signalk.boat.local   │                │
     │─────────────>│               │                │
     │              │ 2. ForwardAuth│                │
     │              │──────────────>│                │
     │              │  3. 200 (valid session)        │
     │              │<──────────────│                │
     │              │ 4. Route to host.docker.internal:3000
     │              │───────────────────────────────>│
     │              │               │   5. Response  │
     │              │<───────────────────────────────│
     │  6. Response │               │                │
     │<─────────────│               │                │
```

## OIDC Client Management

### Configuration Structure

Authelia uses multi-file configuration. OIDC clients are managed via a `.d` directory pattern:

```
/etc/halos/oidc-clients.d/           # App packages drop snippets here
├── homarr.yml                       # Installed by homarr-container
└── another-app.yml                  # Installed by another-app-container

/var/lib/container-apps/authelia-container/data/
├── configuration.yml                # Base config
├── oidc-clients.yml                 # Merged from .d directory (generated)
├── users_database.yml               # User credentials
├── oidc_private_key.pem             # JWT signing key
└── db.sqlite3                       # Session storage
```

### Client Registration Process

**App installation** (simple):
1. Package installs YAML snippet to `/etc/halos/oidc-clients.d/{app_id}.yml`
2. Package triggers Authelia restart (via systemd dependency or postinst)

**Authelia prestart** (handles merging):
1. Reads all files from `/etc/halos/oidc-clients.d/*.yml`
2. Merges client definitions into single `oidc-clients.yml`
3. Authelia container starts with merged config

**Important**: Authelia only reads OIDC client snippets during its prestart phase. If an OIDC-enabled app is installed while Authelia is already running, the new client won't be registered until Authelia restarts. The systemd service dependency ensures correct ordering on system boot, but manual restart may be needed after installing new OIDC apps:

```bash
systemctl restart authelia-container
```

**App removal**:
1. Package's `postrm` removes `/etc/halos/oidc-clients.d/{app_id}.yml`
2. Authelia restart merges remaining clients

**Note**: OIDC snippet cleanup requires custom `postrm` logic in each OIDC app package. This will be automated by container-packaging-tools in Phase 2 (Issue #151).

### OIDC Client Snippet Format

Each app installs a snippet like:

```yaml
# /etc/halos/oidc-clients.d/homarr.yml
client_id: homarr
client_name: Homarr Dashboard
client_secret_file: /var/lib/container-apps/homarr-container/data/oidc-secret
redirect_uris:
  - 'http://${HALOS_DOMAIN}/api/auth/callback/oidc'
scopes: [openid, profile, email, groups]
consent_mode: implicit
```

The `client_secret_file` reference allows the prestart script to read and hash the secret during merge.

**YAML Format Limitations**: The prestart script uses shell-based YAML parsing which has limitations:
- Use simple YAML format only (no anchors, aliases, or complex types)
- Values should not contain inline comments (`# after value`)
- Multi-line quoted strings are not supported
- Array items must be on separate lines with `- ` prefix
- Scopes can use inline format: `[openid, profile, email]`

### Merged oidc-clients.yml Format

```yaml
# Generated by Authelia prestart - do not edit
identity_providers:
  oidc:
    clients:
      - client_id: homarr
        client_name: Homarr Dashboard
        client_secret: '$pbkdf2-sha512$...'  # Hashed from file
        redirect_uris:
          - 'http://boat.local/api/auth/callback/oidc'
        scopes: [openid, profile, email, groups]
        consent_mode: implicit
```

## Per-App Middleware

### Default ForwardAuth Middleware

Defined in Traefik's dynamic configuration:

```yaml
# /var/lib/container-apps/traefik-container/assets/dynamic/authelia.yml
http:
  middlewares:
    authelia:
      forwardAuth:
        address: "http://authelia:9091/api/authz/forward-auth"
        trustForwardHeader: true
        authResponseHeaders:
          - Remote-User
          - Remote-Groups
          - Remote-Email
          - Remote-Name
```

### Custom Per-App Middleware

Apps requiring custom headers get their own middleware:

```yaml
# /var/lib/container-apps/traefik-container/assets/dynamic/grafana.yml
http:
  middlewares:
    authelia-grafana:
      forwardAuth:
        address: "http://authelia:9091/api/authz/forward-auth"
        trustForwardHeader: true
        authResponseHeaders:
          - X-Forwarded-User      # Mapped from Remote-User
          - X-Forwarded-Groups    # Mapped from Remote-Groups

      headers:
        customRequestHeaders:
          X-Forwarded-User: "{{ .RemoteUser }}"
          X-Forwarded-Groups: "{{ .RemoteGroups }}"
```

## File Structure

```
halos-core-containers/
├── apps/
│   ├── traefik/
│   │   ├── docker-compose.yml
│   │   ├── metadata.yaml
│   │   └── assets/
│   │       ├── traefik.yml              # Static config
│   │       └── dynamic/
│   │           └── authelia.yml         # Default ForwardAuth middleware
│   │
│   ├── authelia/
│   │   ├── docker-compose.yml
│   │   ├── metadata.yaml
│   │   ├── prestart.sh                  # Secret generation
│   │   └── assets/
│   │       └── configuration.yml.template
│   │
│   ├── mdns-publisher/
│   │   ├── docker-compose.yml
│   │   ├── metadata.yaml
│   │   └── assets/
│   │       └── publish-subdomains.sh
│   │
│   └── homarr/
│       ├── docker-compose.yml
│       ├── metadata.yaml                # routing.auth.mode: oidc
│       └── prestart.sh                  # OIDC env setup
│
└── docs/
    ├── SSO_SPEC.md
    └── SSO_ARCHITECTURE.md
```

## Integration via metadata.yaml

Applications declare their SSO integration in `metadata.yaml` using the `routing` key:

```yaml
# Example: Forward Auth app with custom headers
name: Grafana
app_id: grafana
# ...
routing:
  subdomain: grafana
  auth:
    mode: forward_auth
    forward_auth:
      headers:
        Remote-User: X-WEBAUTH-USER
        Remote-Groups: X-WEBAUTH-GROUPS
```

```yaml
# Example: OIDC app
name: Homarr
app_id: homarr
# ...
routing:
  subdomain: ""  # Empty = root domain ({hostname}.local)
  auth:
    mode: oidc
```

```yaml
# Example: No-auth app
name: AvNav
app_id: avnav
# ...
routing:
  subdomain: avnav
  auth:
    mode: none
```

```yaml
# Example: Host networking app
name: Signal K
app_id: signalk-server
# ...
routing:
  subdomain: signalk
  auth:
    mode: forward_auth
  host_port: 3000  # Traefik routes to host:3000
```

**Note**: The deprecated `traefik:` key is no longer supported. Use `routing:` instead.

## Security Considerations

### Session Security

- Authelia session cookies are HTTP-only and Secure (when HTTPS)
- Session secrets auto-generated at first boot
- Sessions expire after configurable timeout
- Single session across all applications (SSO)

### Credential Storage

- Passwords stored as argon2id hashes (not reversible)
- OIDC client secrets stored hashed in configuration
- Plaintext client secrets stored in app data directories (600 permissions)
- OIDC private key stored in Authelia data directory (600 permissions)

### Network Security

- All containers communicate over isolated Docker network
- Only Traefik exposes ports to host network
- mDNS publisher has host network access (required for Avahi)
- Host networking apps expose their ports but can still use ForwardAuth

### Limitations

- No rate limiting on login attempts (future enhancement)
- No account lockout after failed attempts (future enhancement)
- Certificate management not automated

## Deployment Dependencies

```
traefik-container
       │
       ├── mdns-publisher-container
       │
       ├── authelia-container
       │
       └── application containers
            ├── homarr-container (OIDC)
            ├── grafana-container (ForwardAuth)
            ├── influxdb-container (ForwardAuth)
            └── signalk-container (ForwardAuth, host networking)
```

Package dependencies ensure correct installation order. Systemd service dependencies ensure correct startup order.

## Dynamic Registration

### App Installation

1. Debian package installed
2. `postinst` creates directories, generates secrets if needed
3. If OIDC app: snippet already installed to `/etc/halos/oidc-clients.d/`
4. Systemd service enabled (depends on Authelia for OIDC apps)
5. Authelia restarts, prestart merges OIDC clients
6. App container starts with Traefik labels
7. Traefik automatically picks up new route
8. mDNS publisher advertises new subdomain

### App Removal

1. Systemd service stopped
2. `postrm` removes OIDC snippet from `/etc/halos/oidc-clients.d/`
3. Authelia restarts, prestart regenerates merged config
4. Traefik automatically removes route
5. mDNS publisher removes subdomain advertisement

### Key Design Principle

Package scripts stay simple:
- **Install**: Drop files, create directories, generate secrets
- **Remove**: Delete files
- **No config parsing**: Authelia prestart handles all OIDC config merging
