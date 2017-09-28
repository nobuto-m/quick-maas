#!/bin/bash

set -e
set -u

cd "$(dirname "$0")"

lxc launch ubuntu:xenial quick-maas \
    -c security.privileged=true \
    -c user.user-data="$(cat user-script.sh)"

sleep 3
lxc exec quick-maas -- tail -f /var/log/cloud-init-output.log
