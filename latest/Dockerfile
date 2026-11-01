# MESA RStudio Geospatial — built from cyverse-vice/rstudio-geospatial `latest`
# Rocker-Project geospatial image — thanks R OpenSci and Rocker!
# https://rocker-project.org/images/versioned/rstudio.html
FROM ghcr.io/rocker-org/geospatial:latest

LABEL org.label-schema.name="CyVerse VICE MESA RStudio Geospatial" \
      org.label-schema.description="Rocker geospatial RStudio Server with agentic AI CLIs and MESA MCP servers for CyVerse VICE" \
      org.label-schema.url="https://cyverse.org" \
      org.label-schema.vcs-url="https://github.com/idss-mesa/rstudio" \
      org.label-schema.vendor="CyVerse" \
      org.label-schema.schema-version="1.0.0"

USER root

ARG TARGETARCH=amd64
# ---------------------------------------------------------------------------
# Pinned, checksum-verified downloads (2026-10 security review). Bump the
# version AND its hash together: a mismatch fails the build.
# ---------------------------------------------------------------------------
ARG GO_VERSION="1.27.3"
ARG GO_SHA256_AMD64=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40
ARG GCM_VERSION="2.7.3"
ARG GCM_SHA256_X64=a5431e1b6f25aa8b424e747d880f86e74c739ad52e72c924a7b1a25d87ac7e72
# gomplate v5 (v4.3.3 was built with Go 1.24.5: CVE-2025-68121 + grpc CRITICALs)
ARG GOMPLATE_VERSION="v5.3.1"
ARG GOMPLATE_SHA256_AMD64=2a618bfb02a54dd3c76d92ae4375ccc1f33eeb0545d6565ea7c3388359cb93f8
ARG NODE_VERSION=22.23.4
ARG GOCMD_VERSION=v0.12.5
ARG GOCMD_SHA256_AMD64=af551f8cb2f3f5df63fb3a8eb1bf605c7f27e50ec10283a5375190239db9f57a
ARG AWSCLI_VERSION=2.38.5
ARG AWSCLI_SHA256_X86_64=5def7d1b7e55d892f9a381bb2cb2081a685712464be0d36d5d706af0ac48d0d3
ARG DUCKDB_SHA256_AMD64=c6507206baf7793c6013dbd82368469a45f20dc0e17a6f92f204602f652ed2bc
ARG CLAUDE_CODE_VERSION=2.1.310
ARG CODEX_VERSION=0.164.0
ARG CCR_VERSION=3.1.3
ARG MCP_FS_VERSION=2.0.1
ARG OPENCODE_VERSION=1.19.4

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Phoenix
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone

# System dependencies: upstream set (nginx + supervisor front RStudio on :80)
# plus the MESA stack
# `apt-get upgrade` first: the rocker base lags Ubuntu security updates between
# its releases (openssl, linux-libc-dev, ... were behind)
RUN apt-get update && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        apt-transport-https apt-utils ca-certificates curl wget gcc glances \
        gnupg2 htop less libfuse2 lsb-release nano nginx \
        software-properties-common supervisor sudo gettext git tmux unzip xz-utils \
        socat bubblewrap python3 python3-venv python3-pip \
        locales figlet lolcat s3fs fuse && \
    locale-gen en_US.UTF-8 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Node.js 22 from the official tarball, verified against nodejs.org's SHASUMS256.txt
# (replaces the unpinned `curl deb.nodesource.com/setup_22.x | bash`)
RUN curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" && \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | grep " node-v${NODE_VERSION}-linux-x64.tar.xz$" | sed 's|  .*|  /tmp/node.tar.xz|' | sha256sum -c - && \
    tar -xJ -C /usr/local --strip-components=1 --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md' -f /tmp/node.tar.xz && \
    rm -f /tmp/node.tar.xz && node --version && npm --version

# gomplate renders the nginx config at startup (pinned + sha256; the template is
# rendered once here so a gomplate major bump that breaks it fails the build)
RUN curl -fsSL https://github.com/hairyhenderson/gomplate/releases/download/${GOMPLATE_VERSION}/gomplate_linux-${TARGETARCH} -o /usr/bin/gomplate && \
    echo "${GOMPLATE_SHA256_AMD64}  /usr/bin/gomplate" | sha256sum -c - && \
    chmod a+x /usr/bin/gomplate

# Users may install into the default R library
RUN chmod -R 777 /usr/local/lib/R/site-library

# rstudio user: passwordless sudo, bash
RUN echo "rstudio ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers && \
    usermod -aG sudo rstudio && \
    mkdir -p /home/rstudio/.irods /home/rstudio/data-store && \
    chown -R rstudio:rstudio /home/rstudio

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y gh && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Git Credential Manager (pinned + sha256)
RUN wget -q https://github.com/git-ecosystem/git-credential-manager/releases/download/v${GCM_VERSION}/gcm-linux-x64-${GCM_VERSION}.deb -O /tmp/gcm.deb && \
    echo "${GCM_SHA256_X64}  /tmp/gcm.deb" | sha256sum -c - && \
    dpkg -i /tmp/gcm.deb && rm -f /tmp/gcm.deb
ENV GCM_CREDENTIAL_STORE=cache

# Go, then the iRODS MCP server (https://github.com/idss-mesa/irods-mcp-server)
RUN curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz" && \
    echo "${GO_SHA256_AMD64}  /tmp/go.tgz" | sha256sum -c - && \
    tar -xz -C /usr/local -f /tmp/go.tgz && rm -f /tmp/go.tgz && \
    git clone --depth 1 https://github.com/idss-mesa/irods-mcp-server /tmp/irods-mcp-server && \
    cd /tmp/irods-mcp-server && \
    CGO_ENABLED=0 GOPATH=/tmp/go GOCACHE=/tmp/go-cache /usr/local/go/bin/go build -o /usr/local/bin/irods-mcp-server ./cmd/main.go && \
    cd / && rm -rf /tmp/irods-mcp-server /tmp/go /tmp/go-cache

# GoCommands (pinned + sha256; not self-upgraded from ~/.bashrc any more)
# https://learning.cyverse.org/ds/gocommands/
RUN curl -fsSL -o /tmp/gocmd.tgz "https://github.com/cyverse/gocommands/releases/download/${GOCMD_VERSION}/gocmd-${GOCMD_VERSION}-linux-${TARGETARCH}.tar.gz" && \
    echo "${GOCMD_SHA256_AMD64}  /tmp/gocmd.tgz" | sha256sum -c - && \
    tar -xz -C /usr/local/bin -f /tmp/gocmd.tgz && rm -f /tmp/gocmd.tgz && gocmd --version

# AWS CLI (pinned + sha256)
RUN curl -fsSL -o /tmp/awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" && \
    echo "${AWSCLI_SHA256_X86_64}  /tmp/awscliv2.zip" | sha256sum -c - && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update && \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# mesa-mcp and mesa-ducklake in a dedicated venv (cyverse-login uses
# /opt/mesa/bin/python3 for iRODS password obfuscation)
# Pinned to release tags: DuckDB 2.0 (mesa-ducklake >= 0.2) writes catalogs
# DuckDB 1.x cannot open, and a changed ref also invalidates this layer's cache.
# The [ducklake] extra enforces mesa-mcp's mesa-ducklake>=0.2 floor; the
# assertion fails the build if the venv Python or DuckDB is too old.
ARG MESA_DUCKLAKE_REF=v0.2.0
ARG MESA_MCP_REF=v0.2.0
RUN /usr/bin/python3 -m venv /opt/mesa && \
    /opt/mesa/bin/pip install --no-cache-dir \
      "mesa-ducklake @ git+https://github.com/idss-mesa/mesa-ducklake@${MESA_DUCKLAKE_REF}" \
      "mesa-mcp[ducklake] @ git+https://github.com/idss-mesa/mesa-mcp@${MESA_MCP_REF}" && \
    /opt/mesa/bin/python -c "import sys, duckdb; from importlib.metadata import version as v; assert sys.version_info >= (3, 11), sys.version; assert duckdb.__version__.startswith('2.'), duckdb.__version__; print('mesa-mcp', v('mesa-mcp'), 'mesa-ducklake', v('mesa-ducklake'), 'duckdb', duckdb.__version__)" && \
    ln -s /opt/mesa/bin/mesa-ducklake /usr/local/bin/

# DuckDB 2.0 for users: the `duckdb` CLI on PATH and the R duckdb package (Rocker ships 1.x).
# Same major as /opt/mesa, so catalogs mesa-ducklake writes (DuckDB 2-only)
# open here too.
ARG DUCKDB_VERSION=2.0.0
RUN DUCKDB_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo arm64 || echo amd64) && \
    curl -fsSL -o /tmp/duckdb.tgz "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb-cli-linux-${DUCKDB_ARCH}.tar.gz" && \
    echo "${DUCKDB_SHA256_AMD64}  /tmp/duckdb.tgz" | sha256sum -c - && \
    tar -xz -C /usr/local/bin -f /tmp/duckdb.tgz duckdb && rm -f /tmp/duckdb.tgz && \
    duckdb --version | grep "^v${DUCKDB_VERSION} " && \
    Rscript -e 'install.packages("duckdb"); v <- as.character(packageVersion("duckdb")); cat("R duckdb", v, "\n"); stopifnot(startsWith(v, "2."))'

# FUSE for non-root users and the /osn mount root
RUN echo "user_allow_other" >> /etc/fuse.conf && \
    chmod 644 /etc/fuse.conf && \
    mkdir -p /osn && chmod 755 /osn && chown 1000:1000 /osn

# supervisord (runs nginx + rserver) must bind :80 without root
RUN mkdir -p /var/log/supervisor && \
    touch /var/log/supervisor/supervisord.log && \
    chown -R 1000:1000 /etc/nginx /var/log/supervisor && \
    setcap 'cap_net_bind_service=+ep' /usr/bin/supervisord

USER rstudio

# Agent CLIs: Claude Code, OpenAI Codex, Claude Code Router (AI Verde bridge)
# Versions pinned (ARGs above); the agent configs run mcp-server-filesystem directly
# instead of `npx -y` fetching the newest release at every agent start
RUN npm config set prefix /home/rstudio/.npm-global && \
    npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}" \
        "@musistudio/claude-code-router@${CCR_VERSION}" "@modelcontextprotocol/server-filesystem@${MCP_FS_VERSION}" && \
    npm cache clean --force && \
    test -x /home/rstudio/.npm-global/bin/mcp-server-filesystem

# Antigravity CLI (agy) and OpenCode
RUN mkdir -p /home/rstudio/.cache/antigravity/staging && \
    curl -fsSL https://antigravity.google/cli/install.sh | bash
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path --version "${OPENCODE_VERSION}" && \
    /home/rstudio/.opencode/bin/opencode --version | grep -F "${OPENCODE_VERSION}"

# Shell: MESA prompt + landing screen (RStudio terminals are interactive bash)
RUN echo ". /etc/profile.d/mesa-prompt.sh" >> /home/rstudio/.bashrc && \
    echo 'if [[ $- == *i* ]] && [ -r /etc/motd ]; then /etc/motd; fi' >> /home/rstudio/.bashrc && \
    printf 'set-option -g status off\nset -g mouse on\n' >> /home/rstudio/.tmux.conf

USER root

# RStudio sessions start from rserver, not a login shell, so put the agent CLIs
# on R's PATH too (Sys.which("claude"), system("gh ...") from the console)
ENV PATH="/home/rstudio/.local/bin:/home/rstudio/.npm-global/bin:/home/rstudio/.opencode/bin:/usr/local/go/bin:/usr/games:${PATH}"
RUN echo "PATH=${PATH}" >> /usr/local/lib/R/etc/Renviron.site

ENV REDIRECT_URL="http://localhost/"
EXPOSE 80

WORKDIR /home/rstudio/data-store

# ---------------------------------------------------------------------------
# Config / assets last so edits rebuild in seconds
# ---------------------------------------------------------------------------
COPY nginx.conf.tmpl /nginx.conf.tmpl
# fail the build if gomplate cannot render the nginx template (major-version guard)
RUN REDIRECT_URL=http://localhost/ gomplate -f /nginx.conf.tmpl -o /tmp/nginx.conf.test && \
    grep -q 'proxy_redirect .* http://localhost\$1;' /tmp/nginx.conf.test && rm -f /tmp/nginx.conf.test
COPY rserver.conf /etc/rstudio/rserver.conf
COPY supervisor-nginx.conf /etc/supervisor/conf.d/nginx.conf
COPY supervisor-rstudio.conf /etc/supervisor/conf.d/rstudio.conf

COPY --chmod=755 01-custom /etc/motd
COPY mesa-prompt.sh /etc/profile.d/mesa-prompt.sh
COPY --chmod=755 run.sh /usr/local/bin/run.sh
COPY --chmod=755 mesa-init.sh /usr/local/bin/mesa-init.sh
COPY --chmod=755 osn-mount.sh /usr/local/bin/osn-mount.sh
COPY --chmod=755 configs/aiverde-setup.sh /usr/local/bin/aiverde-setup
COPY --chmod=755 configs/cyverse-login.sh /usr/local/bin/cyverse-login
COPY --chmod=755 configs/mesa-mcp-shim.sh /usr/local/bin/mesa-mcp

COPY --chown=1000:1000 configs/claude.json /home/rstudio/.claude.json
COPY --chown=1000:1000 configs/codex-config.toml /home/rstudio/.codex/config.toml
COPY --chown=1000:1000 configs/opencode.json /home/rstudio/.config/opencode/opencode.json
COPY --chown=1000:1000 configs/antigravity-mcp_config.json /home/rstudio/.gemini/config/mcp_config.json
RUN chown -R 1000:1000 /home/rstudio

ENTRYPOINT ["/usr/local/bin/run.sh"]
