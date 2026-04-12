#!/bin/bash

set -e

if [[ "$CT_TOOL" == "" ]]; then
	podman=$(podman -v 2>/dev/null | grep -c -i podman)
	if [ "$podman" == "1" ]; then
		CT_TOOL=podman
	else
		CT_TOOL=docker
		echo "You are NOT using podman! Good luck!"
	fi
fi


if [[ "$CT_TOOL" == "podman " ]]; then
	extra_args="--pull=newer"
else
	if [[ "$1" == "pull" ]]; then
		echo "Force pulling new base images..."
		extra_args="--pull"
	fi
fi

export llama_build=$(curl -s https://api.github.com/repos/ggml-org/llama.cpp/releases/latest | jq -r '.tag_name')
export stable_diffusion_tag=$(curl -s https://api.github.com/repos/leejet/stable-diffusion.cpp/releases/latest | jq -r '.tag_name') && \
#export stable_diffusion_tag=master-560-e8323ca
export llama_swap_version=$(curl -s https://api.github.com/repos/mostlygeek/llama-swap/releases/latest | jq -r '.tag_name')

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

DOCKER_BUILDKIT=1 PODMAN_BUILDKIT=1 ${CT_TOOL} build $extra_args \
	--target llama-lxc \
	--build-arg llama_build=$llama_build \
	--build-arg stable_diffusion_tag=$stable_diffusion_tag \
	--build-arg llama_swap_build=$llama_swap_build \
	-t llama-lxc:latest .

set +e