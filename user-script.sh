#!/bin/bash

set -e
set -u
set -x

export DEBIAN_FRONTEND=noninteractive

# proxy
if host squid-deb-proxy.lxd >/dev/null; then
    http_proxy='http://squid-deb-proxy.lxd:8000/'
    echo "Acquire::http::Proxy \"${http_proxy}\";" > /etc/apt/apt.conf
fi

apt-get update

# KVM setup
eatmydata apt-get install -y virt-host^

virsh pool-define-as default dir --target /var/lib/libvirt/images
virsh pool-autostart default
virsh pool-start default

cat <<EOF | virsh net-define /dev/stdin
<network>
  <name>maas</name>
  <bridge name='maas'/>
  <ip address='192.168.151.1' netmask='255.255.255.0'/>
</network>
EOF
virsh net-autostart maas
virsh net-start maas

cat <<EOF | virsh net-define /dev/stdin
<network>
  <name>maas-ext</name>
  <bridge name='maas-ext'/>
  <ip address='192.168.152.1' netmask='255.255.255.0'/>
</network>
EOF
virsh net-autostart maas-ext
virsh net-start maas-ext

# maas package install
echo maas-region-controller maas/default-maas-url string 192.168.151.1 \
    | sudo debconf-set-selections
eatmydata apt-get install -y maas || true

# bump limit for avahi-daemon
sed -i -e 's/^rlimit-nproc/#\0/' /etc/avahi/avahi-daemon.conf

# try maas package install again
eatmydata apt-get install -y maas

# maas login as ubuntu/ubuntu
maas createadmin --username ubuntu --password ubuntu \
    --email ubuntu@localhost.localdomain

maas login admin http://localhost/MAAS "$(sudo maas apikey --username ubuntu)"

# start importing image
if [ -n "$http_proxy" ]; then
    maas admin maas set-config name=http_proxy value="$http_proxy"
    maas admin boot-resources import
fi
maas admin maas set-config name=completed_intro value=true

# configure DHCP
eatmydata apt-get install -y jq

fabric=$(maas admin subnets read | jq -r \
    '.[] | select(.cidr=="192.168.151.0/24").vlan.fabric')
maas admin ipranges create type=reserved \
    start_ip=192.168.151.1 end_ip=192.168.151.100
maas admin ipranges create type=dynamic \
    start_ip=192.168.151.201 end_ip=192.168.151.254
maas admin vlan update "$fabric" 0 dhcp_on=true primary_rack="$HOSTNAME"

fabric=$(maas admin subnets read | jq -r \
    '.[] | select(.cidr=="192.168.152.0/24").vlan.fabric')
maas admin ipranges create type=reserved \
    start_ip=192.168.152.1 end_ip=192.168.152.100
maas admin ipranges create type=dynamic \
    start_ip=192.168.152.201 end_ip=192.168.152.254
maas admin vlan update "$fabric" 0 dhcp_on=true primary_rack="$HOSTNAME"

# wait image
while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
    sleep 15
done
sleep 30

# MAAS Pod
sudo -u maas ssh-keygen -f ~maas/.ssh/id_rsa -N ''
install -m 0600 ~maas/.ssh/id_rsa.pub /root/.ssh/authorized_keys

maas admin pods create \
    type=virsh \
    name=localhost \
    power_address="qemu+ssh://root@localhost/system"

# compose machines
for i in {1..4}; do
    maas admin pod compose 1 \
        cores=2 \
        memory=2048 \
        storage='default:8'
done

# juju
eatmydata apt-get install -y squashfuse
snap install --classic juju

juju add-cloud maas /dev/stdin <<EOF
clouds:
  maas:
    type: maas
    auth-types: [oauth1]
    endpoint: http://192.168.151.1/MAAS
EOF

juju add-credential maas -f /dev/stdin <<EOF
credentials:
  maas:
    maas-credential:
      auth-type: oauth1
      maas-oauth: $(sudo maas apikey --username ubuntu)
EOF

juju bootstrap maas maas-controller --debug
