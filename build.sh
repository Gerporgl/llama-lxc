#!/bin/bash

if [[ "$CT_TOOL" == "" ]]; then
	podman=$(podman -v 2>/dev/null | grep -c -i podman)
	if [ "$podman" == "1" ]; then
		CT_TOOL=podman
	else
		CT_TOOL=docker
		echo "You are NOT using podman! Good luck!"
	fi
fi

set -e


# The stages of this Dockerfile are built one by one and each is tagged
# <stage>:latest, and the later stages refer to those *local* images
# (FROM rocm-dev:latest / COPY --from=llama-cpp:latest ...).
# A global --pull would make the engine resolve EVERY FROM against a registry,
# so docker tries to pull rocm-dev:latest (and the other stage tags) from
# docker.io and fails with "pull access denied", which is what broke the
# GitHub Actions build. Therefore the pull flag is only ever passed to the two
# stages that actually start from a public image (ubuntu:24.04).
base_pull_args=""
if [[ "$1" == "pull" ]]; then
	if [[ "$CT_TOOL" == "podman" ]]; then
		echo "Force pulling new base images... (podman --pull=newer, base stages only)"
		base_pull_args="--pull=newer"
	else
		echo "Force pulling new base images... (docker --pull, base stages only)"
		base_pull_args="--pull"
	fi
fi

extra_args=""

export rocm_version="7.2.4"
# Build latest official release version:
#export llama_build=$(curl -s "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" | jq -r '[.][0].tag_name')
# Build from latest pre-release from github:
export llama_build=$(curl -s "https://api.github.com/repos/ggml-org/llama.cpp/releases" | jq -r '[.[] | select(.prerelease == true)][0].tag_name')
export stable_diffusion_tag=$(curl -s https://api.github.com/repos/leejet/stable-diffusion.cpp/releases/latest | jq -r '.tag_name') && \
export llama_swap_version=$(curl -s https://api.github.com/repos/mostlygeek/llama-swap/releases/latest | jq -r '.tag_name')

echo $rocm_version > rocm_version.txt
echo $llama_build > llama_version.txt
echo $stable_diffusion_tag > sd_version.txt
echo $llama_swap_version > llama_swap_version.txt

llama_swap_build="${llama_swap_version//[[:alpha:]]}"
echo llama_build=$llama_build
echo stable_diffusion_tag=$stable_diffusion_tag
echo llama_swap_build=$llama_swap_build

if [[ "$llama_build" == "" || "$llama_build" == "stable_diffusion_tag" ]]; then
	echo "ERROR: Unable to get the latest builds info!"
	exit 1
fi

if [[ "$GPU_TARGETS" ]];then
	extra_args="$extra_args --build-arg GPU_TARGETS=$GPU_TARGETS"
fi

# Stages that FROM a public image (ubuntu:24.04): may force a re-pull
DOCKER_BUILDKIT=1 PODMAN_BUILDKIT=1 ${CT_TOOL} build $extra_args $base_pull_args \
	--target rocm-dev \
	--build-arg ROCM_VERSION=$rocm_version \
	-t rocm-dev:latest .

# Stages that FROM/COPY --from the local stage tags: never pass a pull flag
DOCKER_BUILDKIT=1 PODMAN_BUILDKIT=1 ${CT_TOOL} build $extra_args \
	--target stable-diffusion \
	--build-arg stable_diffusion_tag=$stable_diffusion_tag \
	-t stable-diffusion:latest .

DOCKER_BUILDKIT=1 PODMAN_BUILDKIT=1 ${CT_TOOL} build $extra_args \
	--target llama-cpp \
	--build-arg llama_build=$llama_build \
	-t llama-cpp:latest .

DOCKER_BUILDKIT=1 PODMAN_BUILDKIT=1 ${CT_TOOL} build $extra_args $base_pull_args \
	--target rocm-base \
	--build-arg ROCM_VERSION=$rocm_version \
	-t rocm-base:latest .

DOCKER_BUILDKIT=1 PODMAN_BUILDKIT=1 ${CT_TOOL} build $extra_args \
	--target llama-lxc \
	--build-arg llama_swap_build=$llama_swap_build \
	-t llama-lxc:latest .

set +e
