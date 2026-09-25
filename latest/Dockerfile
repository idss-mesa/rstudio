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
ARG GO_VERSION="1.25.5"
ARG GCM_VERSION="2.7.3"
ARG GOMPLATE_VERSION="v4.3.3"

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Phoenix
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && \
    echo $TZ > /etc/timezone

# System dependencies: upstream set (nginx + supervisor front RStudio on :80)
# plus the MESA stack
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-transport-https apt-utils ca-certificates curl wget gcc glances \
        gnupg2 htop less libfuse2 lsb-release nano nginx \
        software-properties-common supervisor sudo gettext git tmux unzip \
        socat bubblewrap python3 python3-venv python3-pip \
        locales figlet lolcat s3fs fuse && \
    locale-gen en_US.UTF-8 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Node.js 22 (MESA standard; upstream used 20)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# gomplate renders the nginx config at startup
RUN curl -fsSL https://github.com/hairyhenderson/gomplate/releases/download/${GOMPLATE_VERSION}/gomplate_linux-${TARGETARCH} -o /usr/bin/gomplate && \
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

# Git Credential Manager
RUN wget -q https://github.com/git-ecosystem/git-credential-manager/releases/download/v${GCM_VERSION}/gcm-linux-x64-${GCM_VERSION}.deb -O /tmp/gcm.deb && \
    dpkg -i /tmp/gcm.deb && rm -f /tmp/gcm.deb
ENV GCM_CREDENTIAL_STORE=cache

# Go, then the iRODS MCP server (https://github.com/idss-mesa/irods-mcp-server)
RUN wget -q -c https://dl.google.com/go/go${GO_VERSION}.linux-${TARGETARCH}.tar.gz -O - | tar -xz -C /usr/local && \
    git clone --depth 1 https://github.com/idss-mesa/irods-mcp-server /tmp/irods-mcp-server && \
    cd /tmp/irods-mcp-server && \
    CGO_ENABLED=0 GOPATH=/tmp/go GOCACHE=/tmp/go-cache /usr/local/go/bin/go build -o /usr/local/bin/irods-mcp-server ./cmd/main.go && \
    cd / && rm -rf /tmp/irods-mcp-server /tmp/go /tmp/go-cache

# GoCommands https://learning.cyverse.org/ds/gocommands/
RUN cd /usr/local/bin && \
    GOCMD_VER=$(curl -L -s https://raw.githubusercontent.com/cyverse/gocommands/main/VERSION.txt) && \
    curl -L -s https://github.com/cyverse/gocommands/releases/download/${GOCMD_VER}/gocmd-${GOCMD_VER}-linux-${TARGETARCH}.tar.gz | tar zxvf -

# AWS CLI
RUN curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update && \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# mesa-mcp and mesa-ducklake in a dedicated venv (cyverse-login uses
# /opt/mesa/bin/python3 for iRODS password obfuscation)
RUN /usr/bin/python3 -m venv /opt/mesa && \
    /opt/mesa/bin/pip install --no-cache-dir \
      git+https://github.com/idss-mesa/mesa-ducklake.git \
      git+https://github.com/idss-mesa/mesa-mcp.git && \
    ln -s /opt/mesa/bin/mesa-ducklake /usr/local/bin/

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
RUN npm config set prefix /home/rstudio/.npm-global && \
    npm install -g @anthropic-ai/claude-code @openai/codex @musistudio/claude-code-router && \
    npm cache clean --force

# Antigravity CLI (agy) and OpenCode
RUN mkdir -p /home/rstudio/.cache/antigravity/staging && \
    curl -fsSL https://antigravity.google/cli/install.sh | bash
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path

# Shell: MESA prompt + landing screen (RStudio terminals are interactive bash)
RUN echo ". /etc/profile.d/mesa-prompt.sh" >> /home/rstudio/.bashrc && \
    echo 'if [[ $- == *i* ]] && [ -r /etc/motd ]; then /etc/motd; fi' >> /home/rstudio/.bashrc && \
    printf '\n# upgrade GoCommands\ntimeout 10 sudo gocmd upgrade > /dev/null 2>&1 || true\n' >> /home/rstudio/.bashrc && \
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
