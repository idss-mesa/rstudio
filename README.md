# MESA RStudio Geospatial — CyVerse VICE

An [RStudio Server](https://posit.co/products/open-source/rstudio-server/) geospatial workbench for the **MESA** project, built to run as a [CyVerse Discovery Environment (VICE)](https://cyverse.org/discovery-environment) app, on the [Rocker geospatial](https://rocker-project.org/images/versioned/rstudio.html) stack with the MESA agentic AI stack and CyVerse Data Store tooling.

![harbor](https://github.com/idss-mesa/rstudio/actions/workflows/harbor.yml/badge.svg) ![platforms](https://img.shields.io/badge/platforms-linux%2Famd64-blue) ![registry](https://img.shields.io/badge/registry-harbor.cyverse.org%2Fvice%2Fmesa--rstudio-0a7bbb)

Built from the `latest` image in [cyverse-vice/rstudio-geospatial](https://github.com/cyverse-vice/rstudio-geospatial), with the MESA agentic stack from [idss-mesa/jupyterlab](https://github.com/idss-mesa/jupyterlab) layered on top.

## What's inside

| Category | Tools |
| --- | --- |
| **IDE** | RStudio Server behind nginx on port 80 (no login — VICE's ingress handles auth) |
| **Science** | R + tidyverse + sf/terra/stars, GDAL, PROJ, GEOS (Rocker geospatial) |
| **AI agent CLIs** | Claude Code (`claude`), OpenAI Codex (`codex`), OpenCode (`opencode`), Antigravity (`agy`), Claude Code Router (`ccr`) |
| **MCP servers** | `irods` (CyVerse Data Store), `mesa` ([mesa-mcp](https://github.com/idss-mesa/mesa-mcp) + [mesa-ducklake](https://github.com/idss-mesa/mesa-ducklake)), `formation` ([formation-mcp](https://github.com/idss-mesa/formation-mcp), CyVerse DE), `filesystem` — pre-registered for every agent CLI |
| **AI Verde** | `aiverde-setup` helper wires OpenCode + Claude Code (via `ccr`) to `https://llm-api.cyverse.ai` |
| **CyVerse data** | GoCommands (`gocmd`), iRODS config, `s3fs`/OSN mounts (`osn-mount.sh`), AWS CLI |
| **Dev** | GitHub CLI (`gh`), Git Credential Manager, Go 1.25, Node.js 22 |

Base image: `ghcr.io/rocker-org/geospatial:latest` (Ubuntu 24.04). RStudio runs as `rstudio` (uid 1000); working dir `/home/rstudio/data-store`. The agent CLIs are on `PATH` in RStudio terminals and in R (`system("claude --version")`) via `Renviron.site`.

## Run it

```bash
docker run --rm -p 8787:80 -e IPLANT_USER=$USER -e REDIRECT_URL=http://localhost:8787 harbor.cyverse.org/vice/mesa-rstudio:latest
```

Then open <http://localhost:8787>. In VICE, register the tool on port **80**. `REDIRECT_URL` only matters locally, for nginx redirect rewriting.

## DE tool settings

These live in the Discovery Environment, not in this repo, and must match the image. Change them only together with the Dockerfile.

| Setting | Value |
| --- | --- |
| DE app | **MESA RStudio Geospatial** (`0eea0f10-b92c-11f1-9c79-008cfa5ae3e1`) |
| DE tool | `mesa-rstudio` (`ff0aa2b2-b92b-11f1-8020-008cfa5ae3e1`) |
| Image | `harbor.cyverse.org/vice/mesa-rstudio:latest` |
| Type | interactive |
| Container port | **80** |
| Working directory | `/home/rstudio/data-store` (the Data Store CSI mount point; must match the Dockerfile `WORKDIR`) |
| UID | 1000 |
| Entrypoint override | none (the image's own startup script does the MESA per-user setup) |
| Max CPU | 128 cores (upstream `vice/rstudio/geospatial`) |
| Memory limit | 16 GiB (DE user cap; upstream 250 GiB) |

Port **80** is nginx, which proxies to rserver on `127.0.0.1:8787`. Registering 8787 would bypass nginx and fail.

## Sign in to CyVerse

```bash
cyverse-login          # your CyVerse username + password
```

Writes the standard iRODS credential files (`~/.irods/`) so GoCommands, the `mesa`
and `formation` MCP servers, and the agents all act as **you** — with write/own
access to your home and shared collections. Without it you get anonymous, public
read-only access.

For the hosted CyVerse Data Store MCP, **Claude Code** registers **two** servers:
`irods` points at the anonymous
[public endpoint](https://mcp-public.cyverse.ai/mcp) (public data under
`/iplant/home/shared`, no sign-in) and works out of the box; `irods-auth` points
at the [authenticated endpoint](https://mcp.cyverse.ai/mcp), which uses CyVerse's
pre-registered OAuth client (`mcp-client`). Sign in to `irods-auth` once per
session to reach your private home collection:

```bash
claude mcp login irods-auth --no-browser   # opens a kc.cyverse.org URL; paste the redirect back
```

For private-collection access under OpenCode, Codex, and Antigravity, rely on
`cyverse-login`: the bundled **local** `mesa`/iRODS MCP servers and `gocmd` read
your `~/.irods` credentials directly (no OAuth) and act as you. Restart an agent
after logging in so its MCP servers pick up the credentials.

## Connect AI Verde LLMs

Each user authenticates with their **own** institutional identity — no API key is baked into the image. Inside a terminal:

```bash
aiverde-setup          # paste your key from chat.cyverse.ai → Course → API Key
```

It validates the key against `/v1/models`, lists your models, and writes `~/.config/aiverde/env` (chmod 600). Then:

- **OpenCode** — uses the `aiverde` provider directly.
- **Claude Code** — uses `ccr` for non-Anthropic models (`ccr code`), or the native `ANTHROPIC_BASE_URL` env path if your course serves Anthropic models.
- **Codex** — *not* wired to AI Verde: Codex dropped Chat Completions support and AI Verde does not serve the Responses API. It runs on its own OpenAI auth.
## Build

The build context is `latest/`:

```bash
make build             # linux/amd64 → harbor.cyverse.org/vice/mesa-rstudio:latest
make run               # local smoke test
make push
```

The Dockerfile copies all config/asset files *after* the heavy layers, so editing configs rebuilds in seconds.

**CI:** pushes to `main` touching `latest/` — plus a weekly Sunday rebuild that tracks the upstream base image and agent-CLI releases — build and push `:latest` to Harbor ([`harbor.yml`](.github/workflows/harbor.yml)). hadolint lints the Dockerfile on PRs and trivy scans the published image weekly, reporting to the repo Security tab ([`security.yml`](.github/workflows/security.yml)). Both need the `HARBOR_USERNAME` / `HARBOR_PASSWORD` repo secrets.

## Layout

```
latest/
  Dockerfile                    image definition (rocker geospatial + MESA agentic stack)
  run.sh                        container entrypoint (mesa-init as rstudio, renders nginx.conf, runs supervisord)
  nginx.conf.tmpl               gomplate template: nginx :80 → rserver 127.0.0.1:8787
  rserver.conf                  RStudio Server config (auth-none)
  supervisor-*.conf             supervisord programs for nginx and rserver
  mesa-init.sh                  per-user startup (iRODS config, Data Store dotfile import, .env files, S3/OSN mounts)
  01-custom                     MESA ANSI splash screen (/etc/motd)
  mesa-prompt.sh                shell prompt (/etc/profile.d)
  osn-mount.sh                  s3fs mounts for OSN/S3 buckets
  configs/                      agent-CLI configs + aiverde-setup / cyverse-login / mesa-mcp shim
Makefile                        local build/push/run
.github/workflows/              harbor.yml (build+push), security.yml (hadolint + trivy)
```

## Resources

- [CyVerse VICE apps](https://learning.cyverse.org/vice/) · [GoCommands](https://learning.cyverse.org/ds/gocommands/) · [AI Verde](https://aiverde-docs.cyverse.ai/) · [MESA docs](https://idss-mesa.github.io/docs/)
- Upstream: [cyverse-vice/rstudio-geospatial](https://github.com/cyverse-vice/rstudio-geospatial) · MESA org: <https://github.com/idss-mesa>
