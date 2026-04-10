#!/bin/bash

mkdir -p /root/data

if [[ ! -f  "/root/data/config.yaml" ]]; then
    echo "Config file not found, copying default from app folder to root"
    cp /opt/llama/llama-swap/config.default.yaml /root/data/config.yaml
    chmod 644 /root/data/config.yaml
else
    echo "Config file is already setup in /root/data"
fi

if [[ ! -f  "/root/data/llama-swap-launcher" ]]; then
    echo "Llama-swap launcher file not found, copying default from app folder to root"
    cp /opt/llama/llama-swap/default-llama-swap-launcher /root/data/llama-swap-launcher
    chmod 755 /root/data/llama-swap-launcher
else
    echo "Llama-swap launcher is already setup in /root/data"
fi
