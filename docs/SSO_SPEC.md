# HaLOS SSO - Technical Specification

**Version**: 1.0
**Date**: 2025-12-19
**Status**: Draft

## Project Overview

This specification defines the Single Sign-On (SSO) feature for HaLOS web applications. The goal is to provide unified authentication across all HaLOS web interfaces, eliminating the need for users to log in separately to each application.

The solution uses Traefik as a reverse proxy for routing and Authelia as the identity provider. Authentication is handled via OpenID Connect (OIDC), with Authelia serving as the OIDC provider and web applications as OIDC clients.

## Core Features

### 1. Traefik Reverse Proxy

Traefik serves as the central entry point for all web traffic. It provides:

- Docker-based service discovery using container labels
- Host-header-based routing to direct requests to appropriate backends
- A shared Docker network for inter-container communication
- Integration with Authelia for Forward Auth on protected routes

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

### 4. First-Boot Credential Synchronization

Initial setup creates matching admin credentials across all systems:

- Read credentials from the existing branding configuration
- Create corresponding user in Authelia's user database
- Ensure password hashes use Authelia-compatible format (argon2id)

## Technical Requirements

### Host-Header Routing

All web applications are accessed via hostnames rather than ports:

- `halos.local` - Homarr dashboard (main landing page)
- `auth.halos.local` - Authelia login portal

Future applications will follow the pattern `{app}.halos.local`.

### Shared Docker Network

All containers participating in the reverse proxy must join a shared bridge network named `halos-proxy-network`. This enables:

- Container-to-container communication by service name
- Traefik's ability to route traffic to backend containers
- Isolation from other Docker networks on the system

### OIDC Authentication Flow

The authentication flow follows the standard OIDC Authorization Code flow:

1. User accesses protected application
2. Application redirects to Authelia authorization endpoint
3. User authenticates with username/password
4. Authelia redirects back with authorization code
5. Application exchanges code for tokens
6. Application creates local session

### Password Hashing

Authelia requires passwords in argon2id format. The credential sync process must:

- Read plaintext password from branding configuration
- Hash using argon2id with Authelia-compatible parameters
- Store in YAML format matching Authelia's user database schema

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
- No HTTPS for MVP (HTTP only on local network)

## Non-Functional Requirements

### Zero-Touch First Boot

The system must complete initial setup without user intervention:

- Generate required cryptographic secrets automatically
- Create initial admin user from branding configuration
- Start all services in correct order

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

## Out of Scope

The following are explicitly excluded from this specification:

### Other Application SSO

Integration with Grafana, Signal K, InfluxDB, or other marine applications is deferred to future work. This MVP focuses on Homarr only.

### DNS-Based Domain Configuration

Support for custom domains (e.g., `halos.lan`, `myboat.home`) via DNS infrastructure is not included. The system uses `halos.local` exclusively.

### Two-Factor Authentication

TOTP, WebAuthn, or other second-factor methods are not included in this specification.

### HTTPS Certificates

TLS/SSL certificate management (self-signed or Let's Encrypt) is deferred. All traffic is HTTP on the local network.

### User Management UI

A Cockpit plugin or other UI for managing Authelia users is not included. User management is done via configuration files.

## Success Criteria

The implementation is complete when:

1. User can access `halos.local` and see Homarr dashboard
2. User is redirected to Authelia login on first access
3. After login, user is returned to Homarr with active session
4. Session persists across page refreshes
5. Logout from Homarr clears Authelia session
6. All above works on fresh install without manual configuration
