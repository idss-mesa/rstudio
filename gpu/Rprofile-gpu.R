
## ---- MESA GPU (gpu/Rprofile-gpu.R, appended to Rprofile.site) ----
## TensorFlow 2.21 wheels leave nvidia/cusolver/lib out of their RUNPATH, so TF in
## a reticulate Python (keras3's per-user env, or /opt/r-python in WITH_PYTHON_GPU=1
## builds) cannot load libcusolver.so.11 and registers no GPU. As soon as reticulate
## starts Python, preload libcusolver from that env's own nvidia wheel (its RUNPATH
## finds cuBLAS/cuSPARSE/nvJitLink beside it); TF's dlopen("libcusolver.so.11") then
## reuses it. No-op for envs without TensorFlow or without the cusolver wheel.
## If R torch was loaded first, its bundled cuBLAS 12.8 (same soname) is too old for
## the env's cuSOLVER: say so instead of letting TF drop to the CPU silently.
setHook("reticulate.onPyInit", function() try({
  res <- reticulate::py_run_string(local = TRUE, "
import ctypes, glob, os, sys
err = ''
for p in sys.path:
    if os.path.isdir(os.path.join(p, 'tensorflow')):
        for so in sorted(glob.glob(os.path.join(p, 'nvidia', 'cusolver', 'lib', 'libcusolver.so.*'))):
            try:
                ctypes.CDLL(so, mode=ctypes.RTLD_GLOBAL)
            except OSError as e:
                err = str(e)
        break
")
  err <- res[["err"]]
  if (nzchar(err))
    message("MESA GPU: TensorFlow will not see the GPU in this R session: ", err,
            if (grepl("undefined symbol", err)) paste0(
              "\n  R torch was loaded first and its CUDA libraries are older than TensorFlow's.",
              "\n  Restart R and load keras3/tensorflow before torch."))
}, silent = TRUE))
