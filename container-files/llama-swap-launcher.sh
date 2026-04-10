#!/bin/bash

# Allow to set additional llama-swap launch options
# such as tls certificates
# This resides on the /root/data volume so it can
# be persited between container base image refresh.
exec llama-swap --config /root/data/config.yaml --watch-config "$@"
