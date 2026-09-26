# shellcheck shell=bash
# /etc/mesa/gpu-entrypoint.d/50-rstudio-ollama.sh — sourced (bash) by mesa-gpu-entrypoint.
#
# VICE starts this image as UID 1000 (rstudio), so the entrypoint's Ollama runs
# as rstudio. A local `docker run` starts as root: run Ollama as rstudio there
# too (as run.sh does for mesa-init), so the server, its models
# (~rstudio/.ollama) and its log (/tmp/ollama-1000.log) belong to the RStudio
# user either way. runuser keeps the OLLAMA_* / CUDA environment (sudo would
# reset it) and sets HOME. Falls back to the entrypoint's own start on failure.
if [ "$(id -u)" = 0 ] && [ "${MESA_OLLAMA_AUTOSTART:-1}" = 1 ] && id rstudio >/dev/null 2>&1 \
    && command -v mesa-ollama-start >/dev/null 2>&1; then
    if runuser -u rstudio -- mesa-ollama-start --no-wait >/dev/null 2>&1; then
        MESA_OLLAMA_AUTOSTART=0   # started above; skip the entrypoint's root start
    fi
fi
