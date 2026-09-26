# shellcheck shell=bash disable=SC2154  # ok/bad/warn/info/hdr and $have_gpu come from mesa-gpu-check
# /etc/mesa/gpu-check.d/50-rstudio.sh — RStudio checks for mesa-gpu-check.
# Sourced by mesa-gpu-check (uses its ok/bad/warn/info/hdr helpers and
# $have_gpu). R torch is covered there; this adds the GPU xgboost build, R's
# connection to the local Ollama server and, in WITH_PYTHON_GPU=1 builds, the
# reticulate TensorFlow venv. Rscript reads Renviron.site, Rprofile.site and
# ldpaths exactly as an RStudio session does.
if command -v Rscript >/dev/null 2>&1; then
    hdr "R: xgboost GPU build, reticulate, Ollama"

    out=$(timeout 300 Rscript -e '
        suppressMessages(library(xgboost)); set.seed(1)
        X <- matrix(rnorm(1e5 * 20), ncol = 20); y <- as.numeric(X[, 1] + rnorm(1e5) > 0)
        m <- xgb.train(params = xgb.params(objective = "binary:logistic", device = "cuda", tree_method = "hist"),
                       data = xgb.DMatrix(X, label = y), nrounds = 20, verbose = 0)
        dev <- xgb.config(m)$learner$generic_param$device
        cat(sprintf("\nxgboost %s trained with device=%s", packageVersion("xgboost"), dev))
        quit(status = !startsWith(dev, "cuda"))' 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -q 'No visible GPU'; then
        ok "$(printf '%s' "$out" | tail -1) (GPU build)"
    elif [ "$have_gpu" = 1 ]; then
        bad "xgboost did not train on the GPU: $(printf '%s' "$out" | grep -v '^$' | tail -2 | tr '\n' ' ')"
    else
        warn "xgboost: no GPU, CPU fallback"
    fi

    if [ -x /opt/r-python/bin/python ]; then
        out=$(timeout 300 Rscript -e '
            tf <- reticulate::import("tensorflow"); n <- length(tf$config$list_physical_devices("GPU"))
            cat(sprintf("\nreticulate %s: TensorFlow %s sees %d GPU(s)", reticulate::py_config()$python, tf$`__version__`, n))
            quit(status = n == 0)' 2>&1)
        if [ $? -eq 0 ]; then ok "$(printf '%s' "$out" | tail -1)"
        elif [ "$have_gpu" = 1 ]; then bad "TensorFlow (reticulate): $(printf '%s' "$out" | grep -v '^$' | tail -2 | tr '\n' ' ')"
        else warn "TensorFlow (reticulate): no GPU"; fi
    else
        info "keras3/tensorflow: no Python env in this build (WITH_PYTHON_GPU=0); the first library(keras3) use downloads TensorFlow + CUDA wheels (~13 GB) into ~/.cache/R/reticulate"
    fi

    if curl -fsS -m 3 "http://${OLLAMA_HOST:-127.0.0.1:11434}/api/version" >/dev/null 2>&1; then
        out=$(timeout 60 Rscript -e 'v <- httr2::resp_body_json(httr2::req_perform(httr2::request("http://127.0.0.1:11434/api/version")))$version
            stopifnot(isTRUE(ollamar::test_connection(logical = TRUE)))
            cat(sprintf("\nR reaches Ollama %s (ollamar/ellmer/mall: http://127.0.0.1:11434)", v))' 2>&1)
        if [ $? -eq 0 ]; then ok "$(printf '%s' "$out" | tail -1)"
        else bad "R cannot reach Ollama: $(printf '%s' "$out" | grep -v '^$' | tail -2 | tr '\n' ' ')"; fi
    fi
    unset out rc
fi
