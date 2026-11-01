# syntax=docker/dockerfile:1
# MESA RStudio — AI Sandbox variant. The published image with every path from
# UID 1000 to root removed: no sudo, no setuid/setgid binaries, no file
# capabilities, no account passwords. Built on the CPU image (-> :sandbox) or
# the GPU image (-> :gpu-sandbox):
#   make build-sandbox        # BASE_IMAGE=harbor.cyverse.org/vice/mesa-rstudio:latest
#   make build-gpu-sandbox    # BASE_IMAGE=harbor.cyverse.org/vice/mesa-rstudio:gpu
# Humans keep the sudo-enabled :latest/:gpu images (the VICE "modify your
# environment" feature); AI agents run in these. See ../README.md "AI Sandbox".
ARG BASE_IMAGE=harbor.cyverse.org/vice/mesa-rstudio:latest
FROM ${BASE_IMAGE}

LABEL org.label-schema.name="CyVerse VICE MESA RStudio (AI Sandbox)" \
      org.label-schema.description="MESA RStudio for CyVerse VICE with sudo and every privilege-escalation path removed: the AI-agent sandbox variant" \
      org.label-schema.url="https://cyverse.org" \
      org.label-schema.vcs-url="https://github.com/idss-mesa/rstudio" \
      org.label-schema.vendor="CyVerse" \
      org.label-schema.schema-version="1.0.0"

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# RStudio runs the whole stack (supervisord, nginx, rserver) as UID 1000 in the
# sandbox: nginx moves to :8080 (no CAP_NET_BIND_SERVICE), rserver takes the
# non-root flags jupyter-rsession-proxy uses, runtime state lives under /tmp.
COPY --chmod=755 run.sh /usr/local/bin/run.sh
COPY --chmod=644 nginx.conf.tmpl /nginx.conf.tmpl
COPY --chmod=644 supervisord.conf /etc/supervisor/supervisord.conf
COPY --chmod=644 supervisor-rstudio.conf /etc/supervisor/conf.d/rstudio.conf
RUN chown -R 1000:1000 /etc/nginx /var/lib/nginx /var/log/nginx /etc/supervisor && \
    REDIRECT_URL=http://localhost/ gomplate -f /nginx.conf.tmpl -o /dev/null
EXPOSE 8080

# The lockdown script is shared verbatim by the five idss-mesa repos.
COPY --chmod=755 mesa-sandbox-lockdown.sh /usr/local/sbin/mesa-sandbox-lockdown
RUN /usr/local/sbin/mesa-sandbox-lockdown rstudio && rm -f /usr/local/sbin/mesa-sandbox-lockdown && \
    test -x /usr/lib/rstudio-server/bin/rserver && test -x /usr/sbin/nginx && test -x /usr/bin/supervisord

ENV MESA_SANDBOX=1
USER rstudio
WORKDIR /home/rstudio/data-store
