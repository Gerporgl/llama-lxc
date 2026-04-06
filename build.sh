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
	$command pull ghcr.io/mostlygeek/llama-swap:rocm
fi

DOCKER_BUILDKIT=1 PODMAN_BUILDKIT=1 $command build --target llama-lxc -t llama-lxc:latest .
