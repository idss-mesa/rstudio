#!/usr/bin/env bash
# gpu/test-gpu.sh IMAGE — smoke test for the MESA RStudio NVIDIA GPU image.
#
#   GPU=<index>|all  gpu/test-gpu.sh harbor.cyverse.org/vice/mesa-rstudio:gpu
#
# Needs an NVIDIA GPU and nvidia-container-toolkit (`docker run --gpus`).
# Starts the image the way VICE does (UID 1000, default entrypoint), as root
# (local `make run-gpu`) and without a GPU, and checks R torch, GPU xgboost,
# Ollama and R -> Ollama inside it. Pulls qwen3:0.6b (~0.5 GB) into a
# throwaway container. Exits non-zero on any failure; containers are removed
# on exit. Per-test logs are kept in $LOG_DIR (created if missing). A test
# that needs the network (the apt pin against the live repos) is SKIPped, not
# failed, when there is none.
# TEST_KERAS=1 also runs keras3 in its per-user reticulate env on the GPU
# (default build only; downloads ~13 GB of TensorFlow/CUDA wheels).
set -uo pipefail

IMAGE=${1:-harbor.cyverse.org/vice/mesa-rstudio:gpu}
GPU=${GPU:-0}
if [ "$GPU" = all ]; then GPUS=(--gpus all); else GPUS=(--gpus "device=$GPU"); fi
APP_PORT=80
START_TIMEOUT=${START_TIMEOUT:-300}
LOG_DIR=${LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/mesa-gpu-rstudio-test.XXXXXX")}
mkdir -p "$LOG_DIR" || exit 1
PREFIX=mesa-gpu-rstudio-test-$$
# the environment rsession sees: run.sh starts supervisord through sudo, which
# drops Docker ENV; R then reads Renviron.site and ldpaths itself
RSESSION_ENV=(env -i HOME=/home/rstudio USER=rstudio LOGNAME=rstudio LANG=en_US.UTF-8
              PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)

CONTAINERS=()
NAMES=() STATUS=() DETAILS=()
cleanup() {
    for c in "${CONTAINERS[@]}"; do docker rm -f "$c" >/dev/null 2>&1; done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

say() { printf '\n\e[1m== %s\e[0m\n' "$*"; }
record() { # name pass|fail|skip detail
    NAMES+=("$1") STATUS+=("$2") DETAILS+=("$3")
    case "$2" in
        pass) printf '  \e[32mPASS\e[0m %s: %s\n' "$1" "$3" ;;
        skip) printf '  \e[33mSKIP\e[0m %s: %s\n' "$1" "$3" ;;
        *)    printf '  \e[31mFAIL\e[0m %s: %s\n' "$1" "$3" ;;
    esac
}
check() { # name log-file detail-on-pass -- command...   (pass = exit 0)
    local name=$1 log=$2 detail=$3; shift 4
    if "$@" >"$log" 2>&1; then record "$name" pass "$detail"
    else record "$name" fail "exit $? — $(grep -v '^[[:space:]]*$' "$log" | tail -3 | tr '\n' ' ' | cut -c1-400) (log: $log)"; fi
}
last_line() { grep -v '^[[:space:]]*$' "$1" | tail -1 | cut -c1-300; }

free_port() {
    local p
    for _ in $(seq 1 100); do
        p=$((20000 + RANDOM % 40000))
        (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { echo "$p"; return 0; }
    done
    return 1
}

start() { # name port [docker run args...]  -> container name on stdout
    local name=$PREFIX-$1 port=$2; shift 2
    CONTAINERS+=("$name")
    docker run -d --name "$name" -p "127.0.0.1:$port:$APP_PORT" -e IPLANT_USER=mesa-test \
        -e REDIRECT_URL="http://127.0.0.1:$port" "$@" "$IMAGE" >/dev/null
}

wait_http() { # container port -> 0 when the app answers 200/302 and the container is running
    local c=$1 port=$2 code=000 t=0
    while [ "$t" -lt "$START_TIMEOUT" ]; do
        [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || { echo "container exited"; return 1; }
        code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$port/") || true
        case "$code" in 200|302) sleep 3
            [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] && { echo "HTTP $code after ${t}s"; return 0; } ;;
        esac
        sleep 3; t=$((t + 3))
    done
    echo "no HTTP 200/302 within ${START_TIMEOUT}s (last: $code)"; return 1
}

rx() { # docker exec as rstudio with a timeout
    local c=$1; shift
    timeout 900 docker exec -u rstudio "$c" "$@"
}

procs_ok() { # rserver up, Ollama API up and served by rstudio (uid 1000)
    docker exec "$1" pgrep -x rserver >/dev/null || { echo "rserver not running"; return 1; }
    ollama_as_rstudio "$1" && echo "rserver running; ollama serve runs as rstudio"
}
ollama_as_rstudio() {
    local v=""
    for _ in $(seq 1 30); do v=$(docker exec "$1" curl -fsS -m 2 http://127.0.0.1:11434/api/version) && break; sleep 1; done
    echo "ollama API: ${v:-no answer}"
    local p; p=$(docker exec "$1" ps -ww -o user=,args= -C ollama.bin | grep ' serve')
    echo "ollama process: $p"
    grep -q '^rstudio ' <<<"$p"
}
motd_ok() { # the CPU splash (motd-base) and then the GPU panel, without errors
    local out; out=$(docker exec -u rstudio "$1" /etc/motd 2>&1); printf '%s\n' "$out"
    grep -q 'cyverse-login' <<<"$out" && grep -q 'aiverde-setup' <<<"$out" \
        && grep -q 'OLLAMA' <<<"$out" && grep -q 'Local LLMs on this GPU' <<<"$out" && grep -q 'mesa-gpu-check' <<<"$out" \
        && grep -q 'nvtop / nvitop' <<<"$out" \
        && ! grep -qiE 'no such file|permission denied|command not found' <<<"$out"
}
xgb_ok() { # device=cuda in the model config and no silent CPU fallback warning
    local out rc; out=$(rx "$1" Rscript -e "$R_XGB" 2>&1); rc=$?; printf '%s\n' "$out"
    [ "$rc" -eq 0 ] && ! grep -q 'No visible GPU' <<<"$out"
}
root_ok() {
    ollama_as_rstudio "$1" || { echo "ollama serve is not running as rstudio"; return 1; }
    rx "$1" mesa-gpu-check
}
# docker/kubectl exec shells do not descend from the entrypoint: /etc/bash.bashrc
# must give a non-login interactive shell the same forward-compat decision as
# the processes started with the container. PID 1 is `sudo supervisord`, whose
# environ nobody in the container may read, so the reference is the Ollama
# server the entrypoint started (as rstudio). Checked with Docker ENV (docker
# exec) and without it: rsession's environment, where an RStudio terminal
# starts (login or not).
exec_shell_ok() {
    local c=$1 ep ex rs rl norc
    ep=$(rx "$c" bash -c 'p=$(pgrep -u rstudio -f "ollama.bin serve" | head -1) && tr "\0" "\n" < "/proc/$p/environ"' |
         sed -n 's/^MESA_CUDA_COMPAT=//p')
    ex=$(rx "$c" bash -i -c 'echo "@@MESA_CUDA_COMPAT=${MESA_CUDA_COMPAT:-unset}"' 2>/dev/null | sed -n 's/^@@MESA_CUDA_COMPAT=//p')
    rs=$(rx "$c" "${RSESSION_ENV[@]}" bash -i -c 'echo "@@MESA_CUDA_COMPAT=${MESA_CUDA_COMPAT:-unset}"' 2>/dev/null | sed -n 's/^@@MESA_CUDA_COMPAT=//p')
    rl=$(rx "$c" "${RSESSION_ENV[@]}" bash -l -i -c 'echo "@@MESA_CUDA_COMPAT=${MESA_CUDA_COMPAT:-unset}"' 2>/dev/null | sed -n 's/^@@MESA_CUDA_COMPAT=//p')
    norc=$(rx "$c" bash --norc -i -c 'echo "@@MESA_CUDA_COMPAT=${MESA_CUDA_COMPAT:-unset}"' 2>/dev/null | sed -n 's/^@@MESA_CUDA_COMPAT=//p')
    echo "MESA_CUDA_COMPAT: ollama serve (container start)=${ep:-unset}  docker exec bash -i=${ex:-?}  rsession env bash -i=${rs:-?} / bash -l -i=${rl:-?}  bash --norc -i=${norc:-?}"
    [ -n "$ep" ] && [ "$ex" = "$ep" ] && [ "$rs" = "$ep" ] && [ "$rl" = "$ep" ] && [ "$norc" = unset ] || return 1
    # a `set -e` script that sources the rc files (as interactive setups do) survives them
    rx "$c" bash -c 'set -e; PS1="\$ "; . /etc/bash.bashrc; echo "set -e + bash.bashrc: survived (MESA_CUDA_COMPAT=$MESA_CUDA_COMPAT)"'
}
nvitop_ok() { # on PATH for uid 1000 in an interactive shell and runnable
    local p; p=$(rx "$1" bash -ic 'echo "@@$(command -v nvitop)"' 2>/dev/null | sed -n 's/^@@//p')
    echo "bash -ic 'command -v nvitop': ${p:-not found}"
    [ -n "$p" ] && rx "$1" bash -c "$p --version"
}

# A real RStudio session: sign in through nginx (auth-none), open a client
# (client_init spawns rsession under rserver/sudo supervisord, exactly as a
# browser does) and send R code to its console; the R code writes its result
# to a file. Runs inside the container, so the host needs only docker.
R_RSESSION='res <- tryCatch({
  suppressMessages(library(torch)); stopifnot(cuda_is_available())
  x <- torch_randn(1024, 1024, device = "cuda"); invisible((x %*% x)$sum()$item())
  y <- nn_conv2d(3, 8, 3)$cuda()(torch_randn(2, 3, 64, 64, device = "cuda"))
  suppressMessages(library(xgboost)); X <- matrix(rnorm(5e4 * 10), ncol = 10)
  m <- xgb.train(params = xgb.params(objective = "binary:logistic", device = "cuda"),
                 data = xgb.DMatrix(X, label = as.numeric(X[, 1] > 0)), nrounds = 10, verbose = 0)
  dev <- xgb.config(m)$learner$generic_param$device; stopifnot(startsWith(dev, "cuda"))
  stopifnot(isTRUE(suppressMessages(ollamar::test_connection(logical = TRUE))))
  sprintf("OK %d: torch conv2d on %s, xgboost device=%s, ollamar connected, OLLAMA_CONTEXT_LENGTH=%s (Renviron.site)",
          Sys.getpid(), y$device$type, dev, Sys.getenv("OLLAMA_CONTEXT_LENGTH"))
}, error = function(e) paste("ERROR:", conditionMessage(e)))
writeLines(res, "/tmp/mesa-rsession-test.out")'

rsession_ok() {
    docker exec -u rstudio "$1" rm -f /tmp/mesa-rsession-test.out
    printf '%s\n' "$R_RSESSION" | docker exec -i -u rstudio "$1" tee /tmp/mesa-rsession-test.R >/dev/null
    docker exec -u rstudio "$1" bash -c '
        set -e
        ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36"
        base=http://127.0.0.1:80 jar=$(mktemp)
        curl -fsS -A "$ua" -c "$jar" -b "$jar" -o /dev/null "$base/auth-sign-in?appUri=%2F"
        token=$(awk "\$6 == \"rs-csrf-token\" {print \$7}" "$jar")
        rpc() { curl -fsS -m 120 -A "$ua" -c "$jar" -b "$jar" -H "Content-Type: application/json" \
                     -H "X-RS-CSRF-Token: $token" -H "Origin: $base" --data "$2" "$base/rpc/$1"; }
        cid=$(rpc client_init "{\"method\":\"client_init\",\"params\":[\"$base/\"],\"clientId\":\"\",\"clientVersion\":\"\"}" |
              python3 -c "import json, sys; print(json.load(sys.stdin)[\"result\"][\"clientId\"])")
        rpc console_input "{\"method\":\"console_input\",\"params\":[\"source(\\\"/tmp/mesa-rsession-test.R\\\")\",\"\",0],\"clientId\":\"$cid\"}" >/dev/null
        for _ in $(seq 1 180); do [ -s /tmp/mesa-rsession-test.out ] && break; sleep 1; done
        out=$(cat /tmp/mesa-rsession-test.out 2>/dev/null || echo "no result from the R session within 180 s")
        pids=$(pgrep -d " " -u rstudio -x rsession || true)
        echo "rsession pid(s): $pids"
        echo "$out"
        case "$out" in "OK "*) ;; *) exit 1 ;; esac
        pid=$(echo "$out" | sed -E "s/^OK ([0-9]+):.*/\1/")
        case " $pids " in *" $pid "*) ;; *) echo "pid $pid is not an rsession"; exit 1 ;; esac'
}

R_TORCH='suppressMessages(library(torch))
stopifnot(cuda_is_available())
x <- torch_randn(2048, 2048, device = "cuda")
s <- (x %*% x)$sum()$item()
conv <- nn_conv2d(3, 16, 3)$cuda()
inp <- torch_randn(8, 3, 224, 224, device = "cuda", requires_grad = TRUE)
out <- conv(inp); out$sum()$backward()
stopifnot(out$device$type == "cuda", identical(dim(out), c(8L, 16L, 222L, 222L)), !is.null(inp$grad))
cat(sprintf("\nR torch %s (CUDA %s, cuDNN %s, %d GPU): matmul + nn_conv2d fwd/bwd on cuda\n",
    packageVersion("torch"), cuda_runtime_version(), backends_cudnn_version(), cuda_device_count()))'

R_XGB='suppressMessages(library(xgboost)); set.seed(1)
X <- matrix(rnorm(2e5 * 20), ncol = 20); y <- as.numeric(X[, 1] + rnorm(2e5) > 0)
m <- xgb.train(params = xgb.params(objective = "binary:logistic", device = "cuda", tree_method = "hist"),
               data = xgb.DMatrix(X, label = y), nrounds = 50, verbose = 0)
dev <- xgb.config(m)$learner$generic_param$device
cat(sprintf("\nxgboost %s trained 50 rounds with device=%s\n", packageVersion("xgboost"), dev))
stopifnot(startsWith(dev, "cuda"))'

R_OLLAMA='stopifnot(isTRUE(suppressMessages(ollamar::test_connection(logical = TRUE))))
m <- ollamar::list_models()$name
stopifnot("qwen3:0.6b" %in% m)
txt <- ollamar::generate("qwen3:0.6b", "Reply with one word: hello", output = "text")
stopifnot(nzchar(txt))
cat(sprintf("\nollamar: connected, models: %s, generate -> %d chars\n", paste(m, collapse = ","), nchar(txt)))'

R_RSESSION_ENV='stopifnot(Sys.getenv("OLLAMA_CONTEXT_LENGTH") == "32768", Sys.getenv("NVIDIA_DRIVER_CAPABILITIES") == "")
stopifnot(file.exists(file.path(Sys.getenv("MESA_CUDA_COMPAT_DIR"), "libcuda.so.1")))  # Renviron.site, from CUDA_COMPAT_VERSION
suppressMessages(library(torch)); stopifnot(cuda_is_available())
x <- torch_randn(512, 512, device = "cuda"); invisible((x %*% x)$sum()$item())
stopifnot(isTRUE(suppressMessages(ollamar::test_connection(logical = TRUE))))
cat(sprintf("\nno Docker ENV: Renviron.site OLLAMA_CONTEXT_LENGTH=%s, torch cuda OK, ollamar OK; LD_LIBRARY_PATH=%s\n",
    Sys.getenv("OLLAMA_CONTEXT_LENGTH"), Sys.getenv("LD_LIBRARY_PATH")))'

echo "image: $IMAGE   GPU: $GPU   logs: $LOG_DIR"
docker image inspect "$IMAGE" >/dev/null || { echo "image $IMAGE not found (make build-gpu)" >&2; exit 1; }

# ---------------------------------------------------------------------------
say "T1 static: host driver injected, nothing baked, image config"
check "T1 nvidia-smi + host libcuda" "$LOG_DIR/t1-static.log" "see log" \
    -- docker run --rm "${GPUS[@]}" --entrypoint bash "$IMAGE" -c '
        set -e
        nvidia-smi -L
        drv=$(sed -nE "s/.*Kernel Module( for [a-z0-9_]+)?[[:space:]]+([0-9]+\.[0-9.]+).*/\2/p" /proc/driver/nvidia/version | head -1)
        lib=$(readlink -f "$(ldconfig -p | awk "/libcuda\\.so\\.1 /{print \$NF; exit}")")
        echo "host driver $drv; libcuda.so.1 -> $lib"
        [ -n "$drv" ] && [ "$(basename "$lib")" = "libcuda.so.$drv" ]
        if dpkg -l | grep -E "^ii +(nvidia-driver|nvidia-dkms|nvidia-utils|nvidia-compute-utils|libnvidia-(compute|gl|decode|encode|extra|fbc1|cfg1|common)|cuda-drivers)"; then
            echo "driver userspace baked"; exit 1; fi
        test ! -e /usr/local/cuda/compat
        test -e "$MESA_CUDA_COMPAT_DIR/libcuda.so.1"
        echo "no driver packages; compat at $MESA_CUDA_COMPAT_DIR only"
        nvtop --version && nvitop --once >/dev/null && echo "nvtop and nvitop work"'
[ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(grep -c '^GPU ' "$LOG_DIR/t1-static.log") GPU(s); $(grep '^host driver' "$LOG_DIR/t1-static.log")"

cfg=$(docker image inspect -f '{{json .Config.Entrypoint}} {{json .Config.Cmd}} {{.Config.User}} {{.Config.WorkingDir}}' "$IMAGE")
envs=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$IMAGE")
if [ "$cfg" = '["/usr/local/bin/mesa-gpu-entrypoint","/usr/local/bin/run.sh"] null root /home/rstudio/data-store' ] \
    && ! grep -q '^NVIDIA_VISIBLE_DEVICES=' <<<"$envs" && grep -q '^NVIDIA_DRIVER_CAPABILITIES=compute,utility$' <<<"$envs"; then
    record "T1 image config" pass "$cfg; NVIDIA_VISIBLE_DEVICES unset"
else
    record "T1 image config" fail "$cfg / $(grep '^NVIDIA' <<<"$envs" | tr '\n' ' ')"
fi

check "T1 agent configs" "$LOG_DIR/t1-agents.log" "OpenCode ollama provider + Codex oss_provider, owned by rstudio" \
    -- docker run --rm --entrypoint bash "$IMAGE" -c '
        set -e
        oc=/home/rstudio/.config/opencode/opencode.json cx=/home/rstudio/.codex/config.toml
        python3 -c "import json,sys; p=json.load(open(sys.argv[1]))[\"provider\"]; assert \"ollama\" in p and \"aiverde\" in p, p.keys()" "$oc"
        grep -qx "oss_provider = \"ollama\"" "$cx"
        [ "$(stat -c %u:%g "$oc" "$cx" | sort -u)" = 1000:1000 ]'

# the GPU scripts must not inherit the build host's umask: UID 1000 sources and runs them
check "T1 GPU scripts usable by uid 1000" "$LOG_DIR/t1-modes.log" "profile.d env, apt pin, entrypoint/check hooks, helpers readable/executable as uid 1000" \
    -- docker run --rm --user 1000 --entrypoint bash "$IMAGE" -c '
        set -e
        stat -c "%A %U:%G %n" /etc/profile.d/mesa-gpu-env.sh /etc/apt/preferences.d/mesa-no-nvidia-driver /etc/bash.bashrc \
            /etc/mesa /etc/mesa/gpu-entrypoint.d /etc/mesa/gpu-entrypoint.d/* /etc/mesa/gpu-check.d /etc/mesa/gpu-check.d/* \
            /etc/mesa/motd-gpu.sh /usr/local/bin/ollama /usr/local/bin/mesa-* /usr/local/bin/cuda-probe /usr/local/bin/ollama-setup
        . /etc/profile.d/mesa-gpu-env.sh
        for f in /etc/apt/preferences.d/mesa-no-nvidia-driver /etc/bash.bashrc; do test -r "$f"; done
        for d in /etc/mesa /etc/mesa/gpu-entrypoint.d /etc/mesa/gpu-check.d; do test -r "$d" && test -x "$d"; done
        for f in /etc/mesa/gpu-entrypoint.d/*.sh /etc/mesa/gpu-check.d/*.sh; do test -r "$f"; done
        for f in /etc/mesa/motd-gpu.sh /usr/local/bin/ollama /usr/local/bin/mesa-gpu-entrypoint /usr/local/bin/mesa-gpu-check \
                 /usr/local/bin/mesa-ollama-start /usr/local/bin/ollama-setup /usr/local/bin/cuda-probe /usr/local/bin/nvitop; do test -x "$f"; done'

# apt must refuse NVIDIA driver packages (they would shadow the injected host
# driver). Needs the live repos: apt-get update as root in a throwaway
# container; without a network the policy check is skipped, not failed.
pin=/etc/apt/preferences.d/mesa-no-nvidia-driver
pin_mode=$(docker run --rm --entrypoint stat "$IMAGE" -c '%a %U:%G' "$pin" 2>&1)
if [ "$pin_mode" = "644 root:root" ]; then record "T1 apt driver pin file" pass "$pin: $pin_mode"
else record "T1 apt driver pin file" fail "$pin: $pin_mode"; fi
docker run --rm --user 0 --entrypoint bash "$IMAGE" -c '
    # apt-get update exits 0 even when every fetch fails: start from empty lists
    # and look for downloaded package lists
    rm -rf /var/lib/apt/lists/*
    timeout 300 apt-get update >/dev/null 2>&1
    if ! compgen -G "/var/lib/apt/lists/*_Packages*" >/dev/null; then echo "NO-NETWORK: apt-get update fetched no package lists"; exit 2; fi
    pinned=$(apt-cache policy nvidia-driver-580 cuda-drivers | grep -c "Candidate: (none)")
    unpinned=$(apt-cache -o Dir::Etc::PreferencesParts=/nonexistent policy nvidia-driver-580 2>/dev/null | sed -n "s/^ *Candidate: //p")
    echo "with the pin: $pinned of 2 (nvidia-driver-580, cuda-drivers) have Candidate: (none); without it nvidia-driver-580 -> ${unpinned:-?}"
    apt-cache policy nvidia-driver-580 | sed -n "/Candidate/p"
    [ "$pinned" = 2 ] && [ -n "$unpinned" ] && [ "$unpinned" != "(none)" ]' >"$LOG_DIR/t1-apt-pin.log" 2>&1
case $? in
    0) record "T1 apt pin: no driver candidate" pass "$(grep '^with the pin' "$LOG_DIR/t1-apt-pin.log")" ;;
    2) record "T1 apt pin: no driver candidate" skip "no network for apt-get update ($(head -1 "$LOG_DIR/t1-apt-pin.log" | cut -c1-80))" ;;
    *) record "T1 apt pin: no driver candidate" fail "$(last_line "$LOG_DIR/t1-apt-pin.log") (log: $LOG_DIR/t1-apt-pin.log)" ;;
esac

# ---------------------------------------------------------------------------
say "T2 start like VICE (--user 1000, default entrypoint)"
port=$(free_port); vice=$PREFIX-vice
start vice "$port" "${GPUS[@]}" --user 1000
if msg=$(wait_http "$vice" "$port"); then
    record "T2 VICE start: nginx :80" pass "$msg (host port $port)"
else
    record "T2 VICE start: nginx :80" fail "$msg"; docker logs "$vice" >"$LOG_DIR/t2-vice-docker.log" 2>&1
fi
check "T2 rserver + Ollama (uid 1000)" "$LOG_DIR/t2-procs.log" "see log" -- procs_ok "$vice"
[ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(last_line "$LOG_DIR/t2-procs.log")"
check "T2 landing screen" "$LOG_DIR/t2-motd.log" "/etc/motd shows the CPU splash + GPU panel" -- motd_ok "$vice"
check "T2 exec shell forward-compat env" "$LOG_DIR/t2-exec-shell.log" "see log" -- exec_shell_ok "$vice"
[ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(head -1 "$LOG_DIR/t2-exec-shell.log" | cut -c1-200)"
check "T2 nvitop on PATH (bash -i)" "$LOG_DIR/t2-nvitop.log" "see log" -- nvitop_ok "$vice"
[ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(head -1 "$LOG_DIR/t2-nvitop.log"); $(last_line "$LOG_DIR/t2-nvitop.log")"

# ---------------------------------------------------------------------------
say "T3 mesa-gpu-check --ollama (as rstudio)"
check "T3 mesa-gpu-check --ollama" "$LOG_DIR/t3-gpu-check.log" "see log" -- rx "$vice" mesa-gpu-check --ollama
sed 's/\x1b\[[0-9;]*m//g' "$LOG_DIR/t3-gpu-check.log" | grep -E '\[(PASS|FAIL|WARN)\]|Summary' | sed 's/^/    /'
[ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(sed 's/\x1b\[[0-9;]*m//g' "$LOG_DIR/t3-gpu-check.log" | grep 'Summary' | sed 's/== //')"

# ---------------------------------------------------------------------------
say "T4 RStudio GPU stack (as rstudio)"
check "T4 R torch CUDA" "$LOG_DIR/t4-torch.log" "see log" -- rx "$vice" Rscript -e "$R_TORCH"
[ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(last_line "$LOG_DIR/t4-torch.log")"
check "T4 xgboost device=cuda" "$LOG_DIR/t4-xgboost.log" "see log" -- xgb_ok "$vice"
[ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(last_line "$LOG_DIR/t4-xgboost.log")"
check "T4 ollamar -> Ollama" "$LOG_DIR/t4-ollamar.log" "see log" -- rx "$vice" Rscript -e "$R_OLLAMA"
[ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(last_line "$LOG_DIR/t4-ollamar.log")"
check "T4 real RStudio session (RPC)" "$LOG_DIR/t4-rsession.log" "see log" -- rsession_ok "$vice"
[ "${STATUS[-1]}" = pass ] && DETAILS[-1]="rsession $(last_line "$LOG_DIR/t4-rsession.log" | cut -c4-)"
check "T4 R without Docker ENV (as rsession)" "$LOG_DIR/t4-rsession-env.log" "see log" \
    -- rx "$vice" "${RSESSION_ENV[@]}" Rscript -e "$R_RSESSION_ENV"
[ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(last_line "$LOG_DIR/t4-rsession-env.log" | cut -c1-160)..."
if docker exec "$vice" test -x /opt/r-python/bin/python; then   # WITH_PYTHON_GPU=1 builds
    check "T4 reticulate TensorFlow GPU" "$LOG_DIR/t4-tf.log" "see log" -- rx "$vice" "${RSESSION_ENV[@]}" Rscript -e '
        tf <- reticulate::import("tensorflow"); n <- length(tf$config$list_physical_devices("GPU"))
        y <- tf$matmul(tf$random$normal(c(512L, 512L)), tf$random$normal(c(512L, 512L)))
        cat(sprintf("\nTensorFlow %s: %d GPU(s), matmul on %s\n", tf$`__version__`, n, y$device)); stopifnot(n > 0, grepl("GPU", y$device))'
    [ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(last_line "$LOG_DIR/t4-tf.log")"
    check "T4 reticulate PyTorch GPU" "$LOG_DIR/t4-pytorch.log" "see log" -- rx "$vice" "${RSESSION_ENV[@]}" Rscript -e '
        torch <- reticulate::import("torch"); stopifnot(torch$cuda$is_available())
        x <- torch$randn(1024L, 1024L, device = "cuda"); invisible(torch$matmul(x, x)$sum()$item())
        cat(sprintf("\nPyTorch %s via reticulate: cuda matmul OK\n", torch$`__version__`))'
    [ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(last_line "$LOG_DIR/t4-pytorch.log")"
elif [ "${TEST_KERAS:-0}" = 1 ]; then   # default build: keras3's own per-user env (~13 GB download)
    check "T4 keras3 per-user env on GPU" "$LOG_DIR/t4-keras3.log" "see log" -- rx "$vice" "${RSESSION_ENV[@]}" Rscript -e '
        suppressMessages(library(keras3)); invisible(op_add(1, 2))
        tf <- reticulate::import("tensorflow"); n <- length(tf$config$list_physical_devices("GPU"))
        y <- tf$matmul(tf$random$normal(c(512L, 512L)), tf$random$normal(c(512L, 512L)))
        cat(sprintf("\nkeras3 %s: TensorFlow %s (%s) sees %d GPU(s), matmul on %s\n", packageVersion("keras3"),
            tf$`__version__`, reticulate::py_config()$python, n, y$device)); stopifnot(n > 0, grepl("GPU", y$device))'
    [ "${STATUS[-1]}" = pass ] && DETAILS[-1]="$(last_line "$LOG_DIR/t4-keras3.log")"
fi

# ---------------------------------------------------------------------------
say "T5 no GPU: app still starts, mesa-gpu-check reports the missing GPU"
port=$(free_port); nogpu=$PREFIX-nogpu
start nogpu "$port" --user 1000
if msg=$(wait_http "$nogpu" "$port"); then record "T5 no-GPU start: nginx :80" pass "$msg"
else record "T5 no-GPU start: nginx :80" fail "$msg"; fi
rx "$nogpu" mesa-gpu-check >"$LOG_DIR/t5-gpu-check.log" 2>&1; rc=$?
if [ "$rc" = 1 ] && grep -q 'no NVIDIA GPU in this container' "$LOG_DIR/t5-gpu-check.log" \
    && grep -q '== Summary' "$LOG_DIR/t5-gpu-check.log"; then
    record "T5 mesa-gpu-check without GPU" pass "exit 1, reports 'no NVIDIA GPU', completes: $(grep 'Summary' "$LOG_DIR/t5-gpu-check.log" | sed 's/== //')"
else
    record "T5 mesa-gpu-check without GPU" fail "exit $rc (log: $LOG_DIR/t5-gpu-check.log)"
fi

# ---------------------------------------------------------------------------
say "T6 root start (local make run-gpu): Ollama runs as rstudio"
port=$(free_port); root=$PREFIX-root
start root "$port" "${GPUS[@]}"
if msg=$(wait_http "$root" "$port"); then record "T6 root start: nginx :80" pass "$msg"
else record "T6 root start: nginx :80" fail "$msg"; docker logs "$root" >"$LOG_DIR/t6-root-docker.log" 2>&1; fi
check "T6 Ollama as rstudio + gpu-check" "$LOG_DIR/t6-root.log" "see log" -- root_ok "$root"
[ "${STATUS[-1]}" = pass ] && DETAILS[-1]="ollama serve runs as rstudio; mesa-gpu-check $(sed 's/\x1b\[[0-9;]*m//g' "$LOG_DIR/t6-root.log" | grep 'Summary' | sed 's/== Summary: //')"

# ---------------------------------------------------------------------------
say "Results ($IMAGE, GPU=$GPU)"
fails=0 skips=0
printf '%-40s %-6s %s\n' TEST RESULT DETAIL
for i in "${!NAMES[@]}"; do
    printf '%-40s %-6s %s\n' "${NAMES[$i]}" "${STATUS[$i]^^}" "${DETAILS[$i]}"
    case "${STATUS[$i]}" in pass) ;; skip) skips=$((skips + 1)) ;; *) fails=$((fails + 1)) ;; esac
done
echo "logs: $LOG_DIR"
if [ "$fails" -gt 0 ]; then echo "FAILED: $fails test(s)"; exit 1; fi
if [ "$skips" -gt 0 ]; then echo "ALL PASSED ($((${#NAMES[@]} - skips)) tests, $skips skipped)"
else echo "ALL PASSED (${#NAMES[@]} tests)"; fi
