#!/bin/bash

set -e
set -u

export DEBIAN_FRONTEND=noninteractive

# wait online
#while [ "$(systemctl is-active network-online.target)" != 'active' ]; do
#    sleep 5
#done

# proxy
if host squid-deb-proxy.lxd >/dev/null; then
    http_proxy='http://squid-deb-proxy.lxd:8000/'
    echo "Acquire::http::Proxy \"${http_proxy}\";" > /etc/apt/apt.conf
fi

# package install
apt-get update
eatmydata apt-get install -y maas || true

# bump limit for avahi-daemon
sed -i -e 's/^rlimit-nproc/#\0/' /etc/avahi/avahi-daemon.conf

# try package install again
eatmydata apt-get install -y maas

# maas login
maas createadmin --username ubuntu --password ubuntu \
    --email ubuntu@localhost.localdomain

maas login admin http://localhost/MAAS "$(sudo maas apikey --username ubuntu)"

# import image
if [ -n "$http_proxy" ]; then
    maas admin maas set-config name=http_proxy value="$http_proxy"
    maas admin boot-resources import
fi

echo
echo 'Waiting for images to be imported...'
while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
    sleep 5
done
