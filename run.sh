#!/bin/bash

set -e
set -u

cd "$(dirname "$0")"

lxc profile create quick-maas 2>/dev/null || true
# 10GB is too small to host VMs
lxc profile device add quick-maas root disk path=/ pool=default size=50GB 2>/dev/null || true

lxc launch ubuntu:xenial quick-maas \
    -p default -p quick-maas \
    -c security.privileged=true \
    -c security.nesting=true \
    -c raw.lxc='lxc.aa_profile=unconfined' \
    -c user.user-data="$(cat user-script.sh)"

sleep 5
lxc exec quick-maas -- tail -f -n+1 /var/log/cloud-init-output.log
