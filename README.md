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

An NVIDIA GPU variant (R torch on CUDA, GPU xgboost, local LLMs with Ollama) is published as `:gpu` — see [GPU variant](#gpu-variant-gpu).

## Run it

```bash
docker run --rm -p 8787:80 -e IPLANT_USER=$USER -e REDIRECT_URL=http://localhost:8787 harbor.cyverse.org/vice/mesa-rstudio:latest
```

Then open <http://localhost:8787>. In VICE, register the tool on port **80**. `REDIRECT_URL` only matters locally, for nginx redirect rewriting.

## DE tool settings

These live in the Discovery Environment, not in this repo, and must match the image. Change them only together with the Dockerfile.

| Setting | Value |
| --- | --- |
| DE app | **MESA RStudio Geospatial** (`01667dd8-b936-11f1-b923-008cfa5ae3e1`) |
| DE tool (version `1.0.0`) | `mesa-rstudio` (`e2dbec04-b935-11f1-ac49-008cfa5ae3e1`) |
| Image | `harbor.cyverse.org/vice/mesa-rstudio:latest` |
| Type | interactive (`interactive: true`) |
| Network mode | `bridge` (Terrain's default `none` gives an analysis that runs but never serves) |
| Skip /tmp mount | `true` (VNC/X and IPC sockets live in /tmp) |
| VICE proxy | `interactive_apps` = cas-proxy (`discoenv/cas-proxy`), as on the featured apps |
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

## GPU variant (`:gpu`)

`harbor.cyverse.org/vice/mesa-rstudio:gpu` is this image plus an NVIDIA GPU layer: [`gpu/Dockerfile`](gpu/Dockerfile) builds `FROM` the published `:latest` and only adds to it (nothing under `latest/` changes). Same port, user, working directory and startup; the entrypoint prefix `mesa-gpu-entrypoint` sets up CUDA and starts Ollama, then runs `run.sh`.

| Adds | Details |
| --- | --- |
| **R deep learning** | [torch](https://torch.mlverse.org) 0.17.0, mlverse `cu128` build (bundled CUDA 12.8 runtime + cuDNN 9; no system CUDA), luz, torchvision, tabnet, brulee, tidymodels |
| **GPU xgboost** | xgboost 3.3.0.1 R GPU build (`device = "cuda"`); lightgbm (CPU) |
| **Local LLMs** | [Ollama](https://ollama.com) 0.34.4 on `127.0.0.1:11434` (starts with the container, 32k context), `ollamar`, `ellmer`, `mall`; `ollama-setup` wires it to the agent CLIs |
| **Python from R** | reticulate, keras3, tensorflow (R packages). The default build bakes no Python env: the first `library(keras3)` has reticulate download TensorFlow 2.21 and its CUDA wheels (~13 GB, about a minute, into `~/.cache/R/reticulate`, per user and gone when the analysis ends), and an `Rprofile.site` hook puts that env on the GPU. The optional build `WITH_PYTHON_GPU=1` bakes `/opt/r-python` (PyTorch 2.14 cu126 + TensorFlow 2.21 / Keras 3) as `RETICULATE_PYTHON` (+~9 GB), so nothing is downloaded |
| **GPU tooling** | `mesa-gpu-check`, `nvtop`, `nvitop`, `cuda-probe`, CUDA 13 forward-compat driver (`cuda-compat-13-4`, from `CUDA_COMPAT_VERSION`), GPU panel on the terminal landing screen |

The GPU image is about **17.1 GB** uncompressed (CPU `:latest`: 7.9 GB); `WITH_PYTHON_GPU=1` builds are about 26.3 GB.

### Run it locally

```bash
docker run --rm --gpus all -p 127.0.0.1:8787:80 -e IPLANT_USER=$USER -e REDIRECT_URL=http://localhost:8787 harbor.cyverse.org/vice/mesa-rstudio:gpu
```

(`make run-gpu`). The port is bound to loopback because RStudio has no password outside VICE (in VICE, cas-proxy does the sign-in); on a remote GPU server, tunnel to it (`ssh -L 8787:127.0.0.1:8787 <gpu-host>`) instead of publishing it on all interfaces. Without `--gpus` it still starts and everything runs on the CPU. In R:

```r
library(torch); cuda_is_available()                      # TRUE
x <- torch_randn(4096, 4096, device = "cuda"); x %*% x
library(xgboost)
bst <- xgb.train(params = xgb.params(device = "cuda", objective = "binary:logistic"),
                 data = xgb.DMatrix(X, label = y), nrounds = 100)
```

- First visit in a local browser: the CPU image's nginx currently sends a new browser to `//auth-sign-in`, a 404 (this affects `:latest` too; the fix belongs in `latest/nginx.conf.tmpl`). Open <http://localhost:8787/auth-sign-in> once, then <http://localhost:8787/>.
- R torch and Python torch (`reticulate::import("torch")`) cannot be loaded in the same R session (symbol clash). TensorFlow/keras3 and R torch can share one. In the default build, load keras3/tensorflow **before** `library(torch)`: R torch's bundled cuBLAS 12.8 would otherwise shadow the newer one that keras3's per-user TensorFlow env needs, so TensorFlow falls back to the CPU and the session prints a `MESA GPU:` note (restart R). `WITH_PYTHON_GPU=1` builds (CUDA 12.6 wheels) work in either order.
- `install.packages("xgboost")` or `install.packages("torch")` replaces the GPU build (CRAN's xgboost, 3.2.1.1 today, is CPU-only; P3M's torch package comes without the bundled `cu128` libtorch/CUDA libraries). `update.packages()` will do the same once CRAN is newer than the image's versions. To restore them, reinstall xgboost with `R CMD INSTALL` from `XGBOOST_GPU_URL` and torch from the torch-cdn `cu128` repo; both are in [`gpu/Dockerfile`](gpu/Dockerfile).

### Local LLMs (Ollama)

Ollama runs as `rstudio`, on loopback only; models go to `~/.ollama/models` (container-local, gone when the analysis ends; none are baked in).

```bash
ollama-setup                  # pulls qwen3.5:9b, registers it with OpenCode, prints the agent commands
ollama-setup gpt-oss:20b      # any model that fits the GPU
```

Then `ollama launch claude --model qwen3.5:9b`, `codex --oss --local-provider ollama -m qwen3.5:9b` or `opencode -m ollama/qwen3.5:9b` in a terminal, or from R:

```r
ollamar::generate("qwen3.5:9b", "Summarise ...", output = "text")
ellmer::chat_ollama(model = "qwen3.5:9b")$chat("...")
mall::llm_use("ollama", "qwen3.5:9b"); mall::llm_sentiment(df, text)
```

One 16 GB GPU (A16 / T4) fits qwen3.5:9b (default), gpt-oss:20b, gemma4:12b or qwen3:4b; larger models spill to the CPU. Ollama keeps a model on the GPU for 5 min after its last request: `ollama stop <model>` frees the memory for torch/xgboost. The first model load in a new container takes about a minute (one-time CUDA kernel compile).

### Check the GPU

`mesa-gpu-check` (RStudio terminal) checks the driver, CUDA, R torch, GPU xgboost, Ollama and R → Ollama; `mesa-gpu-check --ollama` also runs a tiny model (qwen3:0.6b) and confirms it is 100% on the GPU. Exit 0 = all good. `no NVIDIA GPU in this container` in the DE means the tool was launched without one (`min_gpus`).

### CUDA and driver compatibility

- The image never ships an NVIDIA driver: the NVIDIA runtime injects the host's. R torch (CUDA 12.8) and xgboost (CUDA 12.9) run on any R525+ driver through CUDA minor-version compatibility.
- An apt pin (`/etc/apt/preferences.d/mesa-no-nvidia-driver`, from [`gpu/common/apt-no-nvidia-driver.pref`](gpu/common/apt-no-nvidia-driver.pref)) makes apt refuse NVIDIA driver packages (`nvidia-driver-*`, `libnvidia-*`, `cuda-drivers`): installed in a session they would shadow the injected host driver and break `nvidia-smi`/NVML. CUDA toolkit packages (`cuda-toolkit-12-x`, `libcudnn9-*`) still install. To install a driver package on purpose, `sudo rm` that file first.
- **Ollama 0.34.4** needs R550+ for its CUDA 12 runner and R580+ for CUDA 13; other CUDA 13 software needs R580+. On older drivers (e.g. R535) on data-center GPUs (A16, A100, T4, ...), the image's CUDA 13 forward-compat driver is switched on automatically — only when the host's CUDA API is below 13 and the compat driver works (`/etc/profile.d/mesa-gpu-env.sh`, also sourced from `/etc/bash.bashrc` for `docker exec`/`kubectl exec` shells, and the `ollama` wrapper). R sessions keep the host driver. `MESA_DISABLE_CUDA_COMPAT=1` opts out.
- `MESA_OLLAMA_AUTOSTART=0` (no Ollama server at start) and `MESA_DISABLE_CUDA_COMPAT=1` are read once at container start by the entrypoint, before any `~/.Renviron` or other dotfile, so setting them there has no effect. Set them as container environment variables instead: on VICE an *Environment Variable* parameter on the DE app, locally `docker run -e`.
- RStudio sessions do not inherit Docker `ENV` (`run.sh` starts supervisord through `sudo`), so the Ollama settings and `MESA_CUDA_COMPAT_DIR` (and `RETICULATE_PYTHON` in `WITH_PYTHON_GPU=1` builds) are also written to `Renviron.site`.

### Build & publish from a GPU server

`docker build` needs no GPU. The build host needs Docker with buildx and ~40 GB free disk, plus an NVIDIA GPU and nvidia-container-toolkit for `make test-gpu`. On a GPU build host (e.g. the A100 server):

```bash
git clone https://github.com/idss-mesa/rstudio && cd rstudio
docker login harbor.cyverse.org
make pull-base build-gpu      # FROM harbor.cyverse.org/vice/mesa-rstudio:latest -> :gpu (~8 min); prints the base digest
GPU=0 make test-gpu           # GPU=<index>|all; starts it like VICE, as root and without a GPU; non-zero on any failure
make push-gpu
```

- `make build build-gpu` layers on a fresh local CPU build instead of the published one; `make build-gpu WITH_PYTHON_GPU=1` adds the reticulate PyTorch/TensorFlow venv.
- The build does not depend on the clone's file modes: every `COPY` sets `--chmod`, so a checkout made under a restrictive umask (027/077) builds the same image, and `test-gpu.sh` checks the GPU scripts as UID 1000.
- `TEST_KERAS=1 GPU=0 make test-gpu` also runs keras3 in its per-user reticulate env on the GPU (default build only; downloads ~13 GB into the test container).
- Versions are build ARGs in [`gpu/Dockerfile`](gpu/Dockerfile): `TORCH_R_VERSION`/`TORCH_R_KIND`, `XGBOOST_GPU_URL`/`XGBOOST_GPU_SHA256`, `OLLAMA_VERSION`/`OLLAMA_SHA256`, `CUDA_COMPAT_VERSION`, `TORCH_INDEX_URL` (cu126; move to cu130 once every GPU node runs R580+). `CUDA_COMPAT_VERSION` (13.4) is the single compat pin: it sets both the `cuda-compat-13-4` package and `MESA_CUDA_COMPAT_DIR` (`/usr/local/cuda-13.4/compat`), and the build fails if that directory has no `libcuda.so.1`. Ollama and cuda-compat are installed after the R torch/xgboost/Python layers, so bumping `OLLAMA_*` or `CUDA_COMPAT_VERSION` rebuilds and re-pushes only the small layers after them.
- [`gpu/common/`](gpu/common) is shared with the other MESA GPU images; keep it identical across repos.
- CI alternative: the manual [`harbor-gpu`](.github/workflows/harbor-gpu.yml) workflow (Actions → harbor-gpu → Run workflow) builds on the digest of a CPU tag and pushes `:gpu`, without a GPU test. `security.yml` also lints `gpu/Dockerfile` and trivy-scans `:gpu`.

### DE tool settings (GPU)

A separate tool; the DE app is a copy of **MESA RStudio Geospatial** pointing at it. Admin import body: [`gpu/de-tool.json`](gpu/de-tool.json) (`POST /terrain/admin/tools`; `container_devices` is admin-only).

| Setting | Value |
| --- | --- |
| DE tool (version `1.0.0`) | `mesa-rstudio-gpu` |
| Image | `harbor.cyverse.org/vice/mesa-rstudio:gpu` |
| GPUs | `min_gpus` = `max_gpus` = **1** (with `min_gpus` unset a launch gets no GPU) |
| GPU model | `gpu_models: ["NVIDIA-A16"]` (must be listed by `GET /terrain/tools/gpu-models`) |
| Shared memory | `container_devices`: `{"host_path": "/dev/shm", "container_path": "4Gi"}` — a RAM-backed 4 GiB `/dev/shm` instead of the 64 MB default, for multi-process data loading and shared-memory ML libraries (admin-only; counts against memory) |
| CPU / memory | 4–8 cores, 16–32 GiB |
| Everything else | as the CPU tool: port **80**, working dir `/home/rstudio/data-store`, UID 1000, `bridge`, skip /tmp mount, cas-proxy, no entrypoint override; `pids_limit` 1024 (GPU tool) |

## Build

The build context is `latest/`:

```bash
make build             # linux/amd64 → harbor.cyverse.org/vice/mesa-rstudio:latest
make run               # local smoke test
make push
```

The Dockerfile copies all config/asset files *after* the heavy layers, so editing configs rebuilds in seconds.

**CI:** pushes to `main` touching `latest/` — plus a weekly Sunday rebuild that tracks the upstream base image and agent-CLI releases — build and push `:latest` to Harbor ([`harbor.yml`](.github/workflows/harbor.yml)). hadolint lints both Dockerfiles on PRs and trivy scans the published `:latest` and `:gpu` images weekly, reporting to the repo Security tab (until `:gpu` is first pushed, its scan is skipped with a warning) ([`security.yml`](.github/workflows/security.yml)). Both need the `HARBOR_USERNAME` / `HARBOR_PASSWORD` repo secrets.

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
gpu/                            NVIDIA GPU variant (:gpu), built FROM the CPU image
  Dockerfile                    R torch cu128, GPU xgboost, R ML/LLM packages, Ollama, CUDA forward-compat
  common/                       shared with the other MESA GPU images (keep identical): GPU entrypoint, CUDA env probe, mesa-gpu-check, Ollama helpers, apt driver pin
  gpu-entrypoint.d/             RStudio startup hook (Ollama runs as rstudio when started as root)
  gpu-check.d/                  RStudio checks for mesa-gpu-check (GPU xgboost, reticulate TensorFlow, R → Ollama)
  Rprofile-gpu.R                appended to Rprofile.site: preloads cuSOLVER for TensorFlow in reticulate envs (TF 2.21 wheel bug)
  test-gpu.sh                   GPU smoke test (make test-gpu)
  de-tool.json                  DE admin tool-import body for mesa-rstudio-gpu
Makefile                        local build/push/run (+ pull-base / build-gpu / test-gpu / push-gpu / run-gpu)
.github/workflows/              harbor.yml (build+push), harbor-gpu.yml (manual GPU build+push), security.yml (hadolint + trivy)
```

## Resources

- [CyVerse VICE apps](https://learning.cyverse.org/vice/) · [GoCommands](https://learning.cyverse.org/ds/gocommands/) · [AI Verde](https://aiverde-docs.cyverse.ai/) · [MESA docs](https://idss-mesa.github.io/docs/)
- Upstream: [cyverse-vice/rstudio-geospatial](https://github.com/cyverse-vice/rstudio-geospatial) · MESA org: <https://github.com/idss-mesa>
