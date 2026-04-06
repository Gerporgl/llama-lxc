#!/bin/bash

mkdir -p /root/data

if [[ ! -f  "/root/data/config.yaml" ]]; then
    echo "Config file not found, copying default from app folder to root"
    cp /root/config.default.yaml /root/data/config.yaml
else
    echo "Config file is already setup in /root/data"
fi
