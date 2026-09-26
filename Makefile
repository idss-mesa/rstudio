platform = linux/amd64
repo = harbor.cyverse.org/vice/mesa-rstudio
tag = latest
context = latest
repotag = $(repo):$(tag)

build:
	docker buildx build --rm --platform "$(platform)" -t "$(repotag)" --load "$(context)/"

push:
	docker push "$(repotag)"

run:
	docker run --rm -p 8787:80 -e REDIRECT_URL=http://localhost:8787 -e IPLANT_USER=$$USER "$(repotag)"

rmi:
	docker rmi "$(repotag)"

# ---- NVIDIA GPU variant (gpu/) — layers on the CPU image above ----
gpu_repotag = $(repo):gpu
base_image = $(repo):latest
# 1 also bakes the reticulate PyTorch/TensorFlow venv (+~9 GB)
WITH_PYTHON_GPU ?= 0

pull-base:        ## fetch the published CPU image the GPU layer builds FROM
	docker pull "$(base_image)"

build-gpu:        ## BASE_IMAGE defaults to the CPU image (run `make build` first to layer on a local CPU build)
	docker buildx build --rm --platform "$(platform)" --build-arg BASE_IMAGE="$(base_image)" \
		--build-arg WITH_PYTHON_GPU="$(WITH_PYTHON_GPU)" -t "$(gpu_repotag)" --load gpu/
	@docker image inspect -f 'built on $(base_image): {{.Id}} {{.RepoDigests}}' "$(base_image)" 2>/dev/null || true

test-gpu:         ## GPU smoke test (needs an NVIDIA GPU + nvidia-container-toolkit); GPU=<index> picks the device
	gpu/test-gpu.sh "$(gpu_repotag)"

push-gpu:
	docker push "$(gpu_repotag)"

run-gpu:          ## loopback only: RStudio is unauthenticated outside VICE (on a remote GPU host: ssh -L 8787:127.0.0.1:8787 <host>)
	docker run --rm --gpus all -p 127.0.0.1:8787:80 -e REDIRECT_URL=http://localhost:8787 -e IPLANT_USER=$$USER "$(gpu_repotag)"

rmi-gpu:
	docker rmi "$(gpu_repotag)"

.PHONY: build push run rmi pull-base build-gpu test-gpu push-gpu run-gpu rmi-gpu
