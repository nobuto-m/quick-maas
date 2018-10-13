#!/bin/bash

set -e
set -u

cd "$(dirname "$0")"

lxc profile create quick-maas 2>/dev/null || true
# 10GB is too small to host VMs
lxc profile device add quick-maas root disk path=/ pool=default size=800GB 2>/dev/null || true
lxc profile device add quick-maas kvm unix-char path=/dev/kvm 2>/dev/null || true

lxc init ubuntu:xenial quick-maas \
    -p default -p quick-maas \
    -c security.privileged=true \
    -c user.user-data="$(cat user-script.sh)"

lxc network attach lxdbr0 quick-maas eth0 eth0
lxc config device set quick-maas eth0 ipv4.address 10.0.10.10

lxc start quick-maas
lxc file push -p --uid 1000 --gid 1000 ~/.ssh/authorized_keys quick-maas/home/ubuntu/.ssh/
sleep 5
lxc exec quick-maas -- tail -f -n+1 /var/log/cloud-init-output.log
