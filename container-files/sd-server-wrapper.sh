#!/bin/bash

# By default, we use stable-ui
# Can be changed to use the default ui by calling /opt/stable-diffusion/sd-server in your config.yaml
# Or anything else
cd /opt/stable-diffusion && exec ./sd-server --serve-html-path /opt/stable-ui/index.html "$@"