#!/bin/bash

set -e
set -u

cd "$(dirname "$0")"

lxc profile create quick-maas 2>/dev/null || true
lxc profile device add quick-maas kvm unix-char path=/dev/kvm 2>/dev/null || true
lxc profile device add quick-maas vsock unix-char path=/dev/vsock 2>/dev/null || true
lxc profile device add quick-maas vhost-vsock unix-char path=/dev/vhost-vsock 2>/dev/null || true
lxc profile set quick-maas security.nesting true
lxc profile set quick-maas boot.autostart false

lxc init ubuntu:jammy quick-maas \
    -p default -p quick-maas \
    -c user.user-data="$(cat user-script.sh)"

lxc network attach lxdbr0 quick-maas eth0 eth0
lxc config device set quick-maas eth0 ipv4.address 10.0.9.10
lxc config device add quick-maas proxy-ssh proxy \
    listen=tcp:0.0.0.0:10910 connect=tcp:127.0.0.1:22

lxc start quick-maas

sleep 15

lxc file push -p --uid 1000 --gid 1000 --mode 0600 ~/.ssh/authorized_keys quick-maas/home/ubuntu/.ssh/

if which ts >/dev/null; then
    lxc exec -t quick-maas -- tail -f -n+1 /var/log/cloud-init-output.log | ts
else
    lxc exec -t quick-maas -- tail -f -n+1 /var/log/cloud-init-output.log
fi
