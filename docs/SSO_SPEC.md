# HaLOS SSO - Technical Specification

**Version**: 2.0
**Date**: 2025-12-23
**Status**: Draft

## Project Overview

This specification defines the Single Sign-On (SSO) feature for HaLOS web applications. The goal is to provide unified authentication across all HaLOS web interfaces, eliminating the need for users to log in separately to each application.

The solution uses Traefik as a reverse proxy for routing and Authelia as the identity provider. All container applications with web interfaces are accessible via subdomains and protected by SSO. Applications can use either Forward Auth (default) or OIDC for authentication, or opt out of authentication entirely.

## Core Features

### 1. Traefik Reverse Proxy

Traefik serves as the central entry point for all web traffic. It provides:

- Docker-based service discovery using container labels
- Host-header-based routing to direct requests to appropriate backends
- A shared Docker network for inter-container communication
- Integration with Authelia for Forward Auth on protected routes
- TLS termination for HTTPS access

### 2. Authelia Identity Provider

Authelia provides the authentication layer with:

- File-based user storage for simplicity and low resource usage
- OIDC provider functionality for applications that support it
- Forward Auth endpoint for applications that don't support OIDC
- Session management with cookie-based persistence
- Single-factor authentication (password only for MVP)

### 3. mDNS Subdomain Advertising

To enable subdomain-based routing on local networks without DNS infrastructure:

- Dynamic advertisement of subdomains via Avahi/mDNS
- Automatic registration when containers start
- Automatic cleanup when containers stop
- Support for the `.local` domain standard
- Works with any device hostname (not hardcoded)

### 4. First-Boot Credential Synchronization

Initial setup creates matching admin credentials across all systems:

- Read credentials from the existing branding configuration
- Create corresponding user in Authelia's user database
- Ensure password hashes use Authelia-compatible format (argon2id)

### 5. Container App Integration

All container applications with web interfaces integrate with the SSO system:

- Each app is accessible via `{subdomain}.{hostname}.local`
- Apps declare their authentication mode in package metadata
- Traefik routing labels are generated from metadata
- OIDC clients are registered automatically when apps are installed

## Authentication Modes

Applications declare one of three authentication modes:

### Forward Auth (Default)

For applications that don't have native SSO support. Traefik intercepts requests and validates the session with Authelia before forwarding.

- No application changes required
- User identity passed via HTTP headers (default: `Remote-User`, `Remote-Groups`, `Remote-Email`, `Remote-Name`)
- Headers can be customized per-app if the application expects different header names
- Session managed entirely by Authelia
- Recommended for most applications

### OIDC

For applications with native OpenID Connect support. The application handles the OIDC flow directly with Authelia.

- Requires application-specific OIDC configuration
- Application manages its own session after authentication
- OIDC client must be registered with Authelia
- Used by Homarr and other OIDC-capable applications

### None

For applications that should be publicly accessible on the LAN or that implement their own authentication.

- No authentication enforced by Traefik/Authelia
- Application is directly accessible without login
- Use for public dashboards or self-authenticating applications

## Technical Requirements

### Host-Header Routing

All web applications are accessed via hostnames rather than ports:

- `{hostname}.local` - Homarr dashboard (main landing page)
- `auth.{hostname}.local` - Authelia login portal
- `{app}.{hostname}.local` - Other applications

Where `{hostname}` is the device's hostname (e.g., `halos`, `boat`, `myvessel`).

### Subdomain Naming

- Subdomain defaults to the application's `app_id` from metadata
- Can be explicitly overridden in metadata if needed
- Must be lowercase alphanumeric with hyphens
- Must be unique across all installed applications

### Shared Docker Network

All containers participating in the reverse proxy must join a shared bridge network named `halos-proxy-network`. This enables:

- Container-to-container communication by service name
- Traefik's ability to route traffic to backend containers
- Isolation from other Docker networks on the system

### Host Networking Applications

Applications using Docker host networking (`network_mode: host`) can still use Traefik:

- Traefik routes to the host IP and exposed port
- Application gets subdomain access, TLS, and Forward Auth
- Direct port access remains available as fallback
- Example: Signal K at `signalk.{hostname}.local` and port 3000

### Forward Auth Flow

The Forward Auth flow works as follows:

1. User accesses protected application via subdomain
2. Traefik intercepts request, calls Authelia Forward Auth endpoint
3. If no valid session, Authelia returns 401 with redirect to login
4. User authenticates with username/password at Authelia portal
5. Authelia sets session cookie, redirects back to original URL
6. Traefik validates session, forwards request with auth headers
7. Application receives pre-authenticated request with user identity

### OIDC Authentication Flow

The OIDC flow follows the standard Authorization Code flow:

1. User accesses protected application
2. Application redirects to Authelia authorization endpoint
3. User authenticates with username/password
4. Authelia redirects back with authorization code
5. Application exchanges code for tokens
6. Application creates local session

### OIDC Client Management

OIDC clients are managed in a dedicated configuration file:

- All OIDC clients are defined in a single file (Authelia limitation)
- File is regenerated when OIDC-enabled apps are installed or removed
- Authelia loads this file via its multi-file configuration support
- Authelia is restarted after configuration changes

### Password Hashing

Authelia requires passwords in argon2id format. The credential sync process must:

- Read plaintext password from branding configuration
- Hash using argon2id with Authelia-compatible parameters
- Store in YAML format matching Authelia's user database schema

## App Metadata Configuration

Applications declare SSO configuration in their `metadata.yaml` using the `routing` key:

```yaml
routing:
  subdomain: myapp          # Optional, defaults to app_id
  auth:
    mode: forward_auth      # forward_auth (default) | oidc | none

    # Optional: customize auth headers for forward_auth
    # Maps Authelia header names to what the app expects
    # Default: Remote-User, Remote-Groups, Remote-Email, Remote-Name (passed as-is)
    forward_auth:
      headers:
        Remote-User: X-Forwarded-User      # Authelia sends Remote-User, app receives X-Forwarded-User
        Remote-Groups: X-Forwarded-Groups
        Remote-Email: X-Forwarded-Email
```

If the `routing` section is omitted:
- Apps with `web_ui.enabled: true` default to Forward Auth
- Subdomain defaults to `app_id`

**Note**: The deprecated `traefik:` key is no longer supported. Use `routing:` instead.

## Constraints

### Resource Budget

The combined RAM footprint for Traefik and Authelia must remain under 100 MB to ensure acceptable performance on Raspberry Pi 4 devices with 4GB RAM.

### Target Platform

- Raspberry Pi 4/5 (arm64 architecture)
- Debian Trixie base system
- Docker with compose plugin

### Network Environment

- Local network only (no public internet exposure)
- mDNS-capable network (standard home/office networks)
- HTTP and HTTPS supported (TLS termination at Traefik)

## Non-Functional Requirements

### Zero-Touch First Boot

The system must complete initial setup without user intervention:

- Generate required cryptographic secrets automatically
- Create initial admin user from branding configuration
- Start all services in correct order
- Configure all installed apps for SSO automatically

### mDNS Compatibility

Subdomain resolution must work on:

- macOS (native Bonjour support)
- Linux with Avahi installed
- Windows with Bonjour for Windows

### Service Dependencies

Container startup order must respect dependencies:

1. Traefik starts first (creates shared network)
2. mDNS publisher starts (enables subdomain resolution)
3. Authelia starts (identity provider ready)
4. Application containers start (can authenticate)

### Dynamic App Registration

When applications are installed or removed:

- Traefik routing is updated automatically via Docker labels
- mDNS advertisements are updated automatically
- OIDC clients are re-registered (for OIDC apps only)
- No manual configuration required

## Out of Scope

The following are explicitly excluded from this specification:

### Custom DNS Domains

Support for custom domains (e.g., `.lan`, `.home`, public domains) via DNS infrastructure is not included. Only mDNS `.local` domains are supported.

### Two-Factor Authentication

TOTP, WebAuthn, or other second-factor methods are not included in this specification.

### Certificate Management

While TLS termination is supported, automated certificate management (self-signed CA, Let's Encrypt) is not included. Manual certificate configuration is possible but not specified.

### User Management UI

A Cockpit plugin or other UI for managing Authelia users is not included. User management is done via configuration files.

## Success Criteria

The implementation is complete when:

1. All web applications are accessible via `{subdomain}.{hostname}.local`
2. Forward Auth protects applications by default (login required)
3. OIDC applications (Homarr) authenticate via OIDC flow
4. Applications with `auth: none` are accessible without login
5. Host networking applications are accessible via subdomain
6. System works with any device hostname (not hardcoded)
7. Session persists across page refreshes and applications
8. Logout clears session across all applications
9. App installation automatically configures SSO
10. All above works on fresh install without manual configuration
