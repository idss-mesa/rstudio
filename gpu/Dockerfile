# syntax=docker/dockerfile:1
# MESA RStudio Geospatial — NVIDIA GPU variant. Adds CUDA-enabled R torch (luz,
# torchvision, tabnet, brulee), GPU xgboost, Ollama for local LLMs (ollamar,
# ellmer, mall) and GPU tooling on top of the published CPU image; see
# ../README.md "GPU variant".
ARG BASE_IMAGE=harbor.cyverse.org/vice/mesa-rstudio:latest

# cuda-probe: tiny glibc-only helper used by mesa-gpu-env.sh and mesa-gpu-check
FROM ubuntu:24.04 AS cuda-probe
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev && rm -rf /var/lib/apt/lists/*
COPY --chmod=644 common/cuda-probe.c /src/cuda-probe.c
RUN gcc -O2 -Wall -o /cuda-probe /src/cuda-probe.c -ldl

FROM ${BASE_IMAGE}

LABEL org.label-schema.name="CyVerse VICE MESA RStudio Geospatial (NVIDIA GPU)" \
      org.label-schema.description="Rocker geospatial RStudio Server for NVIDIA GPUs: CUDA R torch, GPU xgboost and Ollama local LLMs, plus agentic AI CLIs and MESA MCP servers, for CyVerse VICE" \
      org.label-schema.url="https://cyverse.org" \
      org.label-schema.vcs-url="https://github.com/idss-mesa/rstudio" \
      org.label-schema.vendor="CyVerse" \
      org.label-schema.schema-version="1.0.0"

USER root
# RUN under bash -o pipefail, as in cli/jupyterlab: every pipe below fails the build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Each version ARG (and the ENV derived from one) is declared just above the
# first RUN that uses it, and the small pinned layers (Ollama, CUDA
# forward-compat) come after the R/Python GPU stack: an ARG or ENV is part of
# the cache key of every later RUN, so an Ollama or cuda-compat bump declared
# up here would re-run the 6 GB R torch layer.

# apt refuses NVIDIA driver packages, in this build and in user sessions
# (`sudo apt install cuda-drivers` would shadow the host driver the runtime
# injects); see the file header and README "GPU variant"
COPY --chmod=644 common/apt-no-nvidia-driver.pref /etc/apt/preferences.d/mesa-no-nvidia-driver

# nvtop, and zstd for the Ollama tarball (curl for the downloads below)
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl zstd nvtop && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# R GPU stack (heaviest, most stable layers first)
# ---------------------------------------------------------------------------

# mlverse torch, prebuilt CUDA kind: bundles the CUDA 12.8 runtime, cuBLAS and
# cuDNN 9 (no system CUDA toolkit) and runs on any R525+ driver through CUDA
# minor-version compatibility. torch-cdn only serves the kinds cpu and cu128.
# The static libs and test libraries are dead weight (~350 MB).
ARG TORCH_R_VERSION=0.17.0
ARG TORCH_R_KIND=cu128
RUN Rscript -e 'options(timeout = 1800); \
      ver <- Sys.getenv("TORCH_R_VERSION"); kind <- Sys.getenv("TORCH_R_KIND"); \
      install.packages("torch", repos = c(torch = sprintf("https://torch-cdn.mlverse.org/packages/%s/%s/", kind, ver), \
                                          CRAN = getOption("repos")[["CRAN"]])); \
      stopifnot(packageVersion("torch") == ver, torch::torch_is_installed())' && \
    tlib=/usr/local/lib/R/site-library/torch/lib && \
    case "${TORCH_R_KIND}" in cu*) ls "$tlib"/libcudart.so.* >/dev/null ;; esac && \
    find "$tlib" -name '*.a' -delete && rm -f "$tlib"/*test*.so && \
    rm -rf /tmp/downloaded_packages /tmp/Rtmp*

# R deep-learning / ML / local-LLM packages (P3M binaries; torch above is
# already installed, so they keep the CUDA build), then the GPU xgboost build
# over CRAN's CPU-only one. xgboost 3.3.0.1 is the last R GPU binary built with
# CUDA 12.9; 3.3.1+/3.4.x need CUDA 13 (R580+) and silently fall back to CPU.
# It comes from xgboost's "experimental" nightly bucket, hence the sha256 pin.
# install.packages("xgboost") (or "torch"; and update.packages() once CRAN is
# newer) swaps these GPU builds for CPU-only ones (see README).
ARG XGBOOST_GPU_URL=https://s3-us-west-2.amazonaws.com/xgboost-nightly-builds/release_3.3.0/d5cd2b40725d55747447f66e4a24f9a2c341b0bf/xgboost_r_gpu_linux.tar.gz
ARG XGBOOST_GPU_SHA256=df276bf14ebda98319da70fa88874746d9275ffbcde77e18e171d809cdbda86a
RUN install2.r --error --skipinstalled -n 4 \
        luz torchvision tabnet brulee tidymodels reticulate keras3 tensorflow \
        ellmer ollamar mall lightgbm data.table jsonlite Matrix && \
    curl -fsSL -o /tmp/xgboost_r_gpu_linux.tar.gz "${XGBOOST_GPU_URL}" && \
    echo "${XGBOOST_GPU_SHA256}  /tmp/xgboost_r_gpu_linux.tar.gz" | sha256sum -c - && \
    R CMD INSTALL /tmp/xgboost_r_gpu_linux.tar.gz && rm -f /tmp/xgboost_r_gpu_linux.tar.gz && \
    Rscript -e 'pkgs <- c("torch", "luz", "torchvision", "tabnet", "brulee", "tidymodels", "reticulate", "keras3", \
                          "tensorflow", "ellmer", "ollamar", "mall", "lightgbm", "xgboost"); \
                for (p in pkgs) stopifnot(requireNamespace(p, quietly = TRUE)); \
                stopifnot(packageVersion("torch") == Sys.getenv("TORCH_R_VERSION"))' && \
    rm -rf /tmp/downloaded_packages /tmp/Rtmp*

# Optional (WITH_PYTHON_GPU=1, +~9 GB): one reticulate venv with CUDA 12.6
# PyTorch and TensorFlow/Keras sharing one set of nvidia-*-cu12 wheels, so
# keras3/tensorflow run on the GPU from R right away. Without it (the default),
# the first library(keras3) use has reticulate/uv download TensorFlow plus the
# nvidia-*-cu12 wheels (~13 GB, per user, into ~/.cache/R/reticulate) and
# gpu/Rprofile-gpu.R puts that env on the GPU. reticulate needs libpython.
# rsession does not see Docker ENV (run.sh starts supervisord through sudo), so
# RETICULATE_PYTHON goes into Renviron.site, and TF's missing cusolver RUNPATH
# entry (TF 2.21 wheel bug) is fixed in R's ldpaths, which rsession and Rscript
# both source. The constraints file keeps TensorFlow from swapping torch.
ARG WITH_PYTHON_GPU=0
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu126
ARG TORCH_VERSION=2.14.0
ARG TORCHVISION_VERSION=0.29.0
ARG TF_VERSION=2.21.0
ARG KERAS_VERSION=3.15.1
RUN if [ "${WITH_PYTHON_GPU}" = 1 ]; then \
        apt-get update && apt-get install -y --no-install-recommends libpython3.12t64 && \
        apt-get clean && rm -rf /var/lib/apt/lists/* && \
        python3 -m venv /opt/r-python && \
        /opt/r-python/bin/pip install --no-cache-dir --upgrade pip && \
        /opt/r-python/bin/pip install --no-cache-dir "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}" \
            --index-url "${TORCH_INDEX_URL}" --extra-index-url https://pypi.org/simple && \
        cuda_tag="${TORCH_INDEX_URL##*/}" && \
        printf 'torch==%s+%s\ntorchvision==%s+%s\n' "${TORCH_VERSION}" "$cuda_tag" "${TORCHVISION_VERSION}" "$cuda_tag" \
            > /tmp/torch-constraints.txt && \
        /opt/r-python/bin/pip install --no-cache-dir -c /tmp/torch-constraints.txt --extra-index-url "${TORCH_INDEX_URL}" \
            "tensorflow[and-cuda]==${TF_VERSION}" "keras==${KERAS_VERSION}" scipy pandas pillow pydot && \
        rm -f /tmp/torch-constraints.txt && \
        cusolver=$(ls -d /opt/r-python/lib/python3*/site-packages/nvidia/cusolver/lib) && \
        echo "RETICULATE_PYTHON=/opt/r-python/bin/python" >> /usr/local/lib/R/etc/Renviron.site && \
        printf '\n# MESA GPU: TensorFlow %s wheels omit nvidia/cusolver from RUNPATH\nLD_LIBRARY_PATH="${LD_LIBRARY_PATH:+${LD_LIBRARY_PATH}:}%s"\nexport LD_LIBRARY_PATH\n' \
            "${TF_VERSION}" "$cusolver" >> "$(R RHOME)/etc/ldpaths"; \
    else \
        echo "WITH_PYTHON_GPU=${WITH_PYTHON_GPU}: no reticulate PyTorch/TensorFlow venv"; \
    fi

# TensorFlow 2.21's missing cusolver RUNPATH, for any reticulate Python (the
# per-user keras3 env as well as /opt/r-python): preload it when Python starts
RUN --mount=type=bind,source=Rprofile-gpu.R,target=/tmp/Rprofile-gpu.R \
    cat /tmp/Rprofile-gpu.R >> /usr/local/lib/R/etc/Rprofile.site && \
    Rscript -e 'stopifnot(length(getHook("reticulate.onPyInit")) == 1L)'

# Ollama (pinned, sha256-checked; never install.sh, which can bake cuda-drivers
# into the image). The wrapper at /usr/local/bin/ollama re-runs the CUDA
# forward-compat probe for `ollama serve`.
ARG OLLAMA_VERSION=0.34.4
ARG OLLAMA_SHA256=c238986e61d40c0cc5f4a9b9e40b9eea104350b77efa34741fc134e105cb9533
RUN curl -fsSL -o /tmp/ollama.tar.zst "https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-amd64.tar.zst" && \
    echo "${OLLAMA_SHA256}  /tmp/ollama.tar.zst" | sha256sum -c - && \
    zstd -dc /tmp/ollama.tar.zst | tar -xf - -C /usr/local && rm -f /tmp/ollama.tar.zst && \
    mv /usr/local/bin/ollama /usr/local/bin/ollama.bin

# The one CUDA forward-compat pin: the cuda-compat-X-Y package and
# MESA_CUDA_COMPAT_DIR (read by /etc/profile.d/mesa-gpu-env.sh) both derive
# from it, so a bump cannot leave the env pointing at a directory that does
# not exist.
ARG CUDA_COMPAT_VERSION=13.4
ENV MESA_CUDA_COMPAT_DIR=/usr/local/cuda-${CUDA_COMPAT_VERSION}/compat

# NVIDIA apt repo (CUDA forward-compat driver only — never driver packages).
# The runtime injects the host's driver; a baked libcuda/nvidia-smi would shadow it.
# cuda-compat stays at its versioned path: /usr/local/cuda/compat would be
# force-mounted over the host driver for every process by the container toolkit.
# The driver check comes after every apt step of this build (the tools above,
# libpython in WITH_PYTHON_GPU=1 builds). It pipes into grep >/dev/null, not
# grep -q: under the pipefail SHELL, grep -q exits on the first match, dpkg
# gets SIGPIPE and the failed pipeline would make the check pass.
RUN curl -fsSL -o /tmp/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb && \
    dpkg -i /tmp/cuda-keyring.deb && rm -f /tmp/cuda-keyring.deb && \
    apt-get update && apt-get install -y --no-install-recommends "cuda-compat-$(printf '%s' "${CUDA_COMPAT_VERSION}" | tr . -)" && \
    test -e "${MESA_CUDA_COMPAT_DIR}/libcuda.so.1" && \
    test ! -e /usr/local/cuda/compat && \
    if dpkg -l | grep -E '^ii +(nvidia-driver|nvidia-dkms|nvidia-utils|nvidia-compute-utils|libnvidia-(compute|gl|decode|encode|extra|fbc1|cfg1|common)|cuda-drivers)' >/dev/null; then \
        echo 'NVIDIA driver userspace must not be baked into the image' >&2; exit 1; fi && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# nvitop, the landing screen's second live GPU monitor (next to nvtop), in its
# own small venv so it cannot disturb the MCP packages in /opt/mesa
RUN python3 -m venv /opt/nvitop && \
    /opt/nvitop/bin/pip install --no-cache-dir nvitop && \
    ln -s /opt/nvitop/bin/nvitop /usr/local/bin/nvitop

# NVIDIA_VISIBLE_DEVICES is deliberately unset: the device plugin / `docker --gpus`
# sets it per container; an image default could expose GPUs a pod did not request.
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    OLLAMA_HOST=127.0.0.1:11434 OLLAMA_CONTEXT_LENGTH=32768 OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 \
    OLLAMA_KEEP_ALIVE=5m OLLAMA_NUM_PARALLEL=1 OLLAMA_MAX_LOADED_MODELS=1 CUDA_CACHE_MAXSIZE=1073741824

# RStudio sessions and their terminals do not inherit Docker ENV (sudo
# supervisord resets it), so give R the Ollama/CUDA settings too: a server
# restarted from R or an RStudio terminal keeps the 32k agent context, and
# mesa-gpu-env.sh in an RStudio terminal probes the pinned compat directory.
RUN printf '%s\n' '# MESA GPU: Ollama / CUDA settings (Docker ENV does not reach rsession)' \
        "MESA_CUDA_COMPAT_DIR=${MESA_CUDA_COMPAT_DIR}" "OLLAMA_HOST=${OLLAMA_HOST}" "OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}" \
        "OLLAMA_FLASH_ATTENTION=${OLLAMA_FLASH_ATTENTION}" "OLLAMA_KV_CACHE_TYPE=${OLLAMA_KV_CACHE_TYPE}" \
        "OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}" "OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}" \
        "OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}" "CUDA_CACHE_MAXSIZE=${CUDA_CACHE_MAXSIZE}" \
        >> /usr/local/lib/R/etc/Renviron.site

# Agent CLIs: register the local Ollama server with OpenCode (provider) and
# Codex (oss_provider); rewritten in place, so they stay owned by rstudio
RUN --mount=type=bind,source=common/patch-agent-configs.py,target=/tmp/patch-agent-configs.py \
    python3 /tmp/patch-agent-configs.py \
        --opencode /home/rstudio/.config/opencode/opencode.json \
        --codex /home/rstudio/.codex/config.toml && \
    chown 1000:1000 /home/rstudio/.config/opencode/opencode.json /home/rstudio/.codex/config.toml

# ---------------------------------------------------------------------------
# GPU scripts / assets last so edits rebuild in seconds. Every COPY sets its
# mode: a checkout made under a restrictive umask (027/077) would otherwise
# leave these root-only, and UID 1000 (VICE) could not source or run them.
# ---------------------------------------------------------------------------
COPY --from=cuda-probe --chmod=755 /cuda-probe /usr/local/bin/cuda-probe
COPY --chmod=644 common/mesa-gpu-env.sh /etc/profile.d/mesa-gpu-env.sh
COPY --chmod=755 common/ollama-wrapper.sh /usr/local/bin/ollama
COPY --chmod=755 common/mesa-ollama-start.sh /usr/local/bin/mesa-ollama-start
COPY --chmod=755 common/mesa-gpu-entrypoint.sh /usr/local/bin/mesa-gpu-entrypoint
COPY --chmod=755 common/mesa-gpu-check.sh /usr/local/bin/mesa-gpu-check
COPY --chmod=755 common/ollama-setup.sh /usr/local/bin/ollama-setup
COPY --chmod=755 common/motd-gpu.sh /etc/mesa/motd-gpu.sh
COPY --chmod=755 gpu-entrypoint.d/ /etc/mesa/gpu-entrypoint.d/
COPY --chmod=755 gpu-check.d/ /etc/mesa/gpu-check.d/

# Landing screen: the CPU splash, then the GPU panel (.bashrc runs /etc/motd)
RUN mv /etc/motd /etc/mesa/motd-base && \
    printf '#!/bin/bash\n/etc/mesa/motd-base\n/etc/mesa/motd-gpu.sh\n' > /etc/motd && chmod 755 /etc/motd

# Shells that do not descend from the entrypoint or a login shell (docker exec
# / kubectl exec `bash -i`) get the forward-compat env from bash.bashrc
RUN printf '\n# MESA GPU: CUDA forward-compat env for shells not started by the IDE (docker/kubectl exec)\nif [ -r /etc/profile.d/mesa-gpu-env.sh ]; then . /etc/profile.d/mesa-gpu-env.sh; fi\n' >> /etc/bash.bashrc

# Same user/workdir as the CPU image: run.sh works as root (local) and as
# UID 1000 (VICE); the GPU entrypoint prefix then execs it unchanged.
# hadolint ignore=DL3002
USER root
WORKDIR /home/rstudio/data-store

ENTRYPOINT ["/usr/local/bin/mesa-gpu-entrypoint", "/usr/local/bin/run.sh"]
