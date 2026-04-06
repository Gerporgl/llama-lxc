#!/bin/bash

# llama-server seems to load its library dynamically looking at the current working folder
# so our idea to put those in /usr/local/lib does not work, even if ld.conf.d already has
# a search location for that, and LD_LIBRARY_PATH show that it does not work as well
# and it is also not a good idea to have these library system wide since other program
# may want their own 
cd /opt/llama && exec ./llama-server "$@"