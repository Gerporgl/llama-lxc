#!/bin/bash

set -e

podman=$(podman -v 2>/dev/null | grep -c -i podman)
if [ "$podman" == "1" ]; then
	command=podman
else
	command=docker
	echo "You are NOT using podman! Good luck!"
fi


if [[ "$1" == "pull" ]]; then
	echo "Pulling new base image..."
	extra_arg="--no-cache"
else
	extra_arg=""
fi

export llama_build=$(curl -s https://api.github.com/repos/ggml-org/llama.cpp/releases/latest | jq -r '.tag_name')
export stable_diffusion_tag=$(curl -s https://api.github.com/repos/leejet/stable-diffusion.cpp/releases/latest | jq -r '.tag_name') && \
echo $llama_build > llama_version.txt
echo $stable_diffusion_tag > sd_version.txt
echo llama_build=$llama_build
echo stable_diffusion_tag=$stable_diffusion_tag

if [[ "$llama_build" == "" || "$llama_build" == "stable_diffusion_tag" ]]; then
	echo "ERROR: Unable to get the latest builds info!"
	exit 1
fi

DOCKER_BUILDKIT=1 PODMAN_BUILDKIT=1 $command build $extra_arg \
	--pull=newer \
	--target llama-lxc \
	--build-arg llama_build=$llama_build \
	--build-arg stable_diffusion_tag=$stable_diffusion_tag \
	-t llama-lxc:latest .

set +e