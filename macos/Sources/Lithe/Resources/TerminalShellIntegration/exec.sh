#!/bin/sh
# exec retains this PID; rc-spawned child shells must not activate the parent.
LITHE_VENV_ROOT_PID=$$
export LITHE_VENV_ROOT_PID
exec "$@"
