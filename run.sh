#!/bin/bash

set -e
set -u

cd "$(dirname "$0")"

lxc profile create quick-maas 2>/dev/null || true
# 10GB is too small to host VMs
lxc profile device add quick-maas root disk path=/ pool=default size=300GB 2>/dev/null || true
lxc profile device add quick-maas kvm unix-char path=/dev/kvm 2>/dev/null || true
lxc profile device add quick-maas vhost-net unix-char path=/dev/vhost-net mode=0600 2>/dev/null || true
lxc profile set quick-maas security.nesting true
lxc profile set quick-maas boot.autostart false

# FIXME: might be effective Juju CLI terminated scenario?
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled

lxc init ubuntu:focal quick-maas \
    -p default -p quick-maas \
    -c user.user-data="$(cat user-script.sh)"

lxc network attach lxdbr0 quick-maas eth0 eth0
lxc config device set quick-maas eth0 ipv4.address 10.0.9.10

lxc start quick-maas

sleep 15

lxc file push -p --uid 1000 --gid 1000 --mode 0600 ~/.ssh/authorized_keys quick-maas/home/ubuntu/.ssh/

lxc exec quick-maas -- tail -f -n+1 /var/log/cloud-init-output.log
