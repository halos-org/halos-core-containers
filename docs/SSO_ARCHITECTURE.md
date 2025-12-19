# HaLOS SSO - System Architecture

**Version**: 1.0
**Date**: 2025-12-19
**Status**: Draft

## System Overview

The SSO architecture consists of four primary components working together to provide unified authentication for HaLOS web applications.

```
                         mDNS/Avahi (*.halos.local)
                                   │
                                   v
┌──────────────────────────────────────────────────────────────┐
│                    Traefik (Port 80)                         │
│  - Docker provider (label-based routing)                     │
│  - Shared network: halos-proxy-network                       │
└──────────────────────────────────────────────────────────────┘
              │                    │                    │
              v                    v                    v
        ┌──────────┐        ┌────────────┐      ┌─────────────┐
        │  Homarr  │        │  Authelia  │      │ mDNS-Pub    │
        │  (OIDC)  │        │  (OIDC+FA) │      │ (host net)  │
        └──────────┘        └────────────┘      └─────────────┘
              ^                    │
              └────────────────────┘
                   OIDC redirect
```

## Components

### Traefik Reverse Proxy

**Image**: `traefik:v3.6`
**Network**: `halos-proxy-network` (bridge, owned by this container)
**Ports**: 80 (HTTP), 443 (reserved for future HTTPS)

Traefik is the central routing component. It receives all incoming HTTP requests and routes them to the appropriate backend container based on the `Host` header.

**Key responsibilities**:
- Create and own the shared Docker network
- Watch Docker daemon for container labels
- Route requests based on `Host` header rules
- Provide ForwardAuth middleware for protected routes

**Configuration approach**:
- Static configuration loaded from mounted file
- Dynamic configuration from Docker labels
- Additional dynamic configuration from file provider (for Authelia middleware)

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

**Data storage**:
- User database: YAML file with usernames and argon2id password hashes
- Session data: SQLite database
- Configuration: YAML file with OIDC client definitions

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

### Homarr Dashboard (Modified)

**Image**: `ghcr.io/homarr-labs/homarr:v1.45+`
**Network**: `halos-proxy-network` (external)
**Ports**: None exposed (accessed via Traefik)

The existing Homarr container is modified to work with the SSO infrastructure.

**Key changes**:
- Remove direct port binding
- Add Traefik routing labels
- Join shared proxy network
- Add OIDC configuration via environment variables

## Network Architecture

### halos-proxy-network

A Docker bridge network created and owned by the Traefik container. All containers that need to be accessible via Traefik must join this network.

**Properties**:
- Driver: bridge
- Name: halos-proxy-network
- Scope: local

**Membership**:
- traefik (owner)
- authelia (member)
- homarr (member)
- future applications (members)

### Host Network (mDNS Publisher only)

The mDNS publisher requires host network mode to access the Avahi daemon running on the host system. This is the only container that uses host networking.

## Data Flow

### Initial Page Load

1. User enters `halos.local` in browser
2. mDNS resolves hostname to device IP address
3. Browser sends HTTP request to port 80
4. Traefik receives request, matches `Host: halos.local`
5. Traefik routes to Homarr container
6. Homarr detects no session, redirects to Authelia

### OIDC Authentication

1. Homarr redirects to `http://auth.halos.local/api/oidc/authorization`
2. Authelia presents login form
3. User enters credentials
4. Authelia validates against user database
5. Authelia redirects to `http://halos.local/api/auth/callback/oidc` with code
6. Homarr exchanges code for tokens via back-channel to Authelia
7. Homarr creates local session, redirects to dashboard

### Subsequent Requests

1. User makes request with session cookie
2. Traefik routes to Homarr
3. Homarr validates session, serves content

## Technology Stack

### Reverse Proxy: Traefik v3.5

**Rationale**: Traefik is chosen over alternatives (nginx, Caddy) because:
- Native Docker integration with label-based configuration
- Built-in ForwardAuth middleware
- Low memory footprint (~15-30 MB)
- Active development and good documentation

### Identity Provider: Authelia 4.38

**Rationale**: Authelia is chosen over alternatives (Keycloak, Authentik) because:
- Extremely low memory footprint (~30-50 MB)
- File-based user storage (no database required)
- Both OIDC and ForwardAuth in one component
- Simple YAML configuration

### mDNS: Dedicated halos-mdns-publisher image

**Rationale**: A dedicated container image built from Alpine because:
- Fast startup (no runtime package installation)
- Reproducible builds with fixed dependencies
- Smallest possible footprint
- Avahi tools pre-installed
- Simple enough that shell scripting is appropriate
- Image hosted on ghcr.io/hatlabs for easy distribution

## File Structure

```
halos-core-containers/
├── apps/
│   ├── traefik/
│   │   ├── docker-compose.yml      # Container definition
│   │   ├── metadata.yaml           # Package metadata
│   │   ├── config.yml              # User-configurable options
│   │   └── assets/
│   │       ├── traefik.yml         # Traefik static config
│   │       └── dynamic/
│   │           └── authelia.yml    # ForwardAuth middleware
│   │
│   ├── authelia/
│   │   ├── docker-compose.yml      # Container definition
│   │   ├── metadata.yaml           # Package metadata
│   │   ├── config.yml              # User-configurable options
│   │   ├── prestart.sh             # Secret generation script
│   │   └── assets/
│   │       └── configuration.yml.template
│   │
│   ├── mdns-publisher/
│   │   ├── docker-compose.yml      # Container definition
│   │   ├── metadata.yaml           # Package metadata
│   │   ├── Dockerfile              # Image build definition
│   │   └── assets/
│   │       └── publish-subdomains.sh
│   │
│   └── homarr/                     # Modified existing app
│       ├── docker-compose.yml      # Updated for Traefik
│       └── config.yml              # Added OIDC options
│
└── docs/
    ├── SSO_SPEC.md
    └── SSO_ARCHITECTURE.md
```

## Security Considerations

### Session Security

- Authelia session cookies are HTTP-only and secure (when HTTPS enabled)
- Session secrets are auto-generated at first boot
- Sessions expire after configurable timeout

### Credential Storage

- Passwords stored as argon2id hashes (not reversible)
- OIDC client secrets stored in configuration files
- Private keys for OIDC JWT signing stored in data directory

### Network Security

- All containers communicate over isolated Docker network
- Only Traefik exposes ports to host network
- mDNS publisher has host network access (required for Avahi)

### Limitations (MVP)

- No HTTPS (traffic is unencrypted on local network)
- No rate limiting on login attempts
- No account lockout after failed attempts

## Integration Points

### Container Labels

Applications integrate with Traefik via Docker labels:

| Label | Purpose |
|-------|---------|
| `traefik.enable=true` | Enable Traefik routing |
| `traefik.http.routers.{name}.rule` | Host matching rule |
| `traefik.http.services.{name}.loadbalancer.server.port` | Backend port |
| `halos.subdomain` | mDNS subdomain to advertise |

### Environment Variables

Applications integrate with Authelia via environment variables for OIDC configuration. The specific variables depend on the application.

### Credential Sync

The homarr-container-adapter syncs credentials from:
- Source: `/etc/halos-homarr-branding/branding.toml` (credentials section)
- Target: Authelia's `users_database.yml`

## Deployment Dependencies

```
traefik-container (standalone, creates network)
       │
       ├── mdns-publisher-container (depends on traefik)
       │
       ├── authelia-container (depends on traefik)
       │
       └── homarr-container (depends on traefik, recommends authelia)
```

The Debian package dependencies ensure correct installation order. Systemd service dependencies ensure correct startup order.
