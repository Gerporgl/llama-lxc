#!/bin/bash


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

DOCKER_BUILDKIT=1 PODMAN_BUILDKIT=1 $command build $extra_arg --target rocm-runtimes -t rocm:runtimes .
DOCKER_BUILDKIT=1 PODMAN_BUILDKIT=1 $command build $extra_arg --target rocm-dev -t rocm:dev .
DOCKER_BUILDKIT=1 PODMAN_BUILDKIT=1 $command build $extra_arg --target stable-diffusion -t stable-diffusion:latest .
