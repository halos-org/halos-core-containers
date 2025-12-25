# HaLOS Core Containers

Core container application definitions for HaLOS. These apps are pre-installed in HaLOS images, providing essential system functionality including Single Sign-On (SSO).

## What's in This Repository

This repository contains core HaLOS container applications:

- **Traefik** - Reverse proxy and load balancer, routes all web traffic via subdomains
- **Authelia** - Identity provider for SSO (OIDC + ForwardAuth)
- **Homarr** - Dashboard landing page at `https://{hostname}.local/`
- **mDNS Publisher** - Advertises app subdomains via Avahi/mDNS

**Key difference from halos-marine-containers:** No store package - core apps are pre-installed in HaLOS images, not discovered via store UI.

## Single Sign-On (SSO)

HaLOS provides unified authentication across all web applications:

- All apps accessible via subdomains: `{app}.{hostname}.local`
- Single login for all applications
- HTTP automatically redirects to HTTPS
- Three auth modes: ForwardAuth (default), OIDC, or none

See [docs/SSO_SPEC.md](docs/SSO_SPEC.md) and [docs/SSO_ARCHITECTURE.md](docs/SSO_ARCHITECTURE.md) for details.

## Build Output

CI/CD builds Debian packages from this repository:
- `halos-traefik-container` - Reverse proxy
- `halos-authelia-container` - SSO identity provider
- `halos-homarr-container` - Dashboard landing page
- `halos-mdns-publisher-container` - mDNS subdomain advertising

All packages are published to apt.hatlabs.fi.

## Agentic Coding Setup (Claude Code, GitHub Copilot, etc.)

For development with AI assistants, use the halos-distro workspace for full context:

```bash
# Clone the workspace
git clone https://github.com/hatlabs/halos-distro.git
cd halos-distro

# Get all sub-repositories including halos-core-containers
./run repos:clone

# Work from workspace root for AI-assisted development
# Claude Code gets full context across all repos
```

See `halos-distro/docs/` for development workflows:
- `LIFE_WITH_CLAUDE.md` - Quick start guide
- `IMPLEMENTATION_CHECKLIST.md` - Development checklist
- `DEVELOPMENT_WORKFLOW.md` - Detailed workflows

## Repository Structure

```
halos-core-containers/
├── apps/
│   ├── traefik/            # Reverse proxy
│   ├── authelia/           # SSO identity provider
│   ├── homarr/             # Dashboard landing page
│   └── mdns-publisher/     # mDNS subdomain advertising
├── docs/
│   ├── SSO_SPEC.md         # SSO technical specification
│   └── SSO_ARCHITECTURE.md # SSO system architecture
├── tools/                   # Build scripts
├── .github/workflows/       # CI/CD
└── README.md
```

## Adding a New App

1. Create `apps/<app-name>/` directory
2. Add required files: `docker-compose.yml`, `metadata.yaml`, `icon.png`
3. Optionally add `config.yml` for user-configurable settings
4. Test locally with `container-packaging-tools`
5. Create PR - CI will build and validate

## Building Locally

Requirements:
- `container-packaging-tools` package installed

```bash
# Build all packages
./tools/build-all.sh

# Build output in build/ directory
ls build/*.deb
```

## Related Repositories

- [halos-distro](https://github.com/hatlabs/halos-distro) - HaLOS workspace and planning
- [halos-marine-containers](https://github.com/hatlabs/halos-marine-containers) - Marine container store
- [cockpit-apt](https://github.com/hatlabs/cockpit-apt) - APT package manager with store filtering
- [container-packaging-tools](https://github.com/hatlabs/container-packaging-tools) - Package generation tooling
- [apt.hatlabs.fi](https://github.com/hatlabs/apt.hatlabs.fi) - APT repository infrastructure

## License

Apache License 2.0 - See [LICENSE](LICENSE) for details.
