#!/bin/bash

set -e
set -u
set -x

export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/snap/bin"
export JUJU_DATA=~ubuntu/.local/share/juju

# proxy
if host squid-deb-proxy.lxd >/dev/null; then
    http_proxy="http://$(dig +short squid-deb-proxy.lxd):8000/"
    echo "Acquire::http::Proxy \"${http_proxy}\";" > /etc/apt/apt.conf
else
    http_proxy=
fi

# ppa
apt-add-repository -y ppa:maas/stable

apt-get update

# KVM setup
eatmydata apt-get install -y libvirt-bin
eatmydata apt-get install -y virtinst --no-install-recommends

virsh net-destroy default
virsh net-autostart --disable default

virsh pool-define-as default dir --target /var/lib/libvirt/images
virsh pool-autostart default
virsh pool-start default

cat <<EOF | virsh net-define /dev/stdin
<network>
  <name>maas</name>
  <bridge name='maas' stp='off'/>
  <forward mode='nat'/>
  <ip address='192.168.151.1' netmask='255.255.255.0'/>
</network>
EOF
virsh net-autostart maas
virsh net-start maas

# maas package install
echo maas-region-controller maas/default-maas-url string 192.168.151.1 \
    | debconf-set-selections
eatmydata apt-get install -y maas || true

# bump limit for avahi-daemon
sed -i -e 's/^rlimit-nproc/#\0/' /etc/avahi/avahi-daemon.conf

# try maas package install again
eatmydata apt-get install -y maas

# maas login as ubuntu/ubuntu
maas createadmin --username ubuntu --password ubuntu \
    --email ubuntu@localhost.localdomain

maas login admin http://localhost:5240/MAAS "$(maas apikey --username ubuntu)"

maas admin boot-source-selection update 1 1 release=bionic
#maas admin boot-source-selections create 1 os=ubuntu release=xenial arches=amd64 subarches=* labels=*

# start importing image
if [ -n "$http_proxy" ]; then
    maas admin maas set-config name=http_proxy value="$http_proxy"
    maas admin boot-resources stop-import
    while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
        sleep 15
    done
fi
maas admin boot-resources import

maas admin maas set-config name=maas_name value='Demo'

maas admin maas set-config name=kernel_opts value='console=tty0 console=ttyS0,115200n8'

maas admin maas set-config name=completed_intro value=true

# configure network / DHCP
eatmydata apt-get install -y jq

maas admin subnet update 192.168.151.0/24 \
    gateway_ip=192.168.151.1 \
    dns_servers=192.168.151.1

fabric=$(maas admin subnets read | jq -r \
    '.[] | select(.cidr=="192.168.151.0/24").vlan.fabric')
maas admin ipranges create type=reserved \
    start_ip=192.168.151.1 end_ip=192.168.151.100
maas admin ipranges create type=dynamic \
    start_ip=192.168.151.201 end_ip=192.168.151.254
maas admin vlan update "$fabric" 0 dhcp_on=true primary_rack="$HOSTNAME"

maas admin spaces create name=space-first
fabric_id=$(maas admin subnets read | jq -r '.[] | select(.cidr=="192.168.151.0/24").vlan.fabric_id')
maas admin vlan update "$fabric_id" 0 space=space-first

# wait image
while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
    sleep 15
done

# MAAS Pod
sudo -u maas ssh-keygen -f ~maas/.ssh/id_rsa -N ''
install -m 0600 ~maas/.ssh/id_rsa.pub /root/.ssh/authorized_keys

maas admin pods create \
    type=virsh \
    cpu_over_commit_ratio=10 \
    memory_over_commit_ratio=1.0 \
    name=localhost \
    power_address="qemu+ssh://root@127.0.0.1/system"

# compose machines
for i in {1..6}; do
    maas admin pod compose 1 \
        cores=8 \
        memory=8192 \
        storage='default:64'
done

# wait for a while until Pod machines will be booted
sleep 15

for machine in $(virsh list --all --name); do
    virsh destroy "$machine"

    # expose CPU model
    virt-xml --edit --cpu mode=host-passthrough "$machine"

    # one more NIC
    virsh attach-interface "$machine" network maas --model virtio --config

    # use SATA bus
    disk_source=$(virsh dumpxml "$machine" | grep '<source file' | cut -d "'" -f2)
    virsh detach-disk "$machine" vda --config
    virsh attach-disk "$machine" "$disk_source" sda \
        --targetbus sata --config

    # one more disk
    virsh vol-create-as default "${machine}_sdb" 64000000000
    virsh attach-disk "$machine" "/var/lib/libvirt/images/${machine}_sdb" sdb \
        --targetbus sata --config

    virsh start "$machine"
done

# juju
eatmydata apt-get install -y squashfuse

# try snap install twice due to an error:
# - Setup snap "core" (3017) security profiles (cannot setup udev for
#   snap "core": cannot reload udev rules: exit status 2
snap install --classic juju || snap install --classic juju
snap install --classic juju-wait

while [ "$(maas admin machines read | jq -r '.[].status_name' | grep -c -w Ready)" != '6' ]; do
    sleep 15
done

# bootstrap
cat > clouds.yaml <<EOF
clouds:
  maas:
    type: maas
    auth-types: [oauth1]
    endpoint: http://192.168.151.1:5240/MAAS
EOF
juju add-cloud maas -f clouds.yaml

cat > credentials.yaml <<EOF
credentials:
  maas:
    maas-credential:
      auth-type: oauth1
      maas-oauth: $(maas apikey --username ubuntu)
EOF
juju add-credential maas -f credentials.yaml

sudo -u ubuntu -H ssh-keygen -f ~ubuntu/.ssh/id_rsa -N ''

if [ -n "$http_proxy" ]; then
    juju bootstrap maas maas-controller --debug \
        --model-default apt-http-proxy="$http_proxy"
else
    juju bootstrap maas maas-controller --debug
fi

## host properties, proxy

# deploy openstack

juju deploy openstack-base
juju config keystone preferred-api-version=3
juju config nova-cloud-controller console-access-protocol=novnc
juju config neutron-gateway data-port='br-ex:ens7'

juju add-unit neutron-gateway
juju config neutron-gateway dns-servers='8.8.8.8,8.8.4.4'
juju config neutron-api \
    enable-l3ha=true \
    l2-population=false \
    dhcp-agents-per-network=2 \
    enable-ml2-dns=true \
    dns-domain=openstack.internal


juju deploy --to lxd:0 --series disco --force glance-simplestreams-sync # LP: #1790904
juju config glance-simplestreams-sync mirror_list="
    [{url: 'http://cloud-images.ubuntu.com/releases/', name_prefix: 'ubuntu:released', path: 'streams/v1/index.sjson', max: 1,
    item_filters: ['release=bionic', 'arch~(x86_64|amd64)', 'ftype~(disk1.img|disk.img)']}]
    "
juju add-relation keystone glance-simplestreams-sync


time juju-wait -w


# setup openstack
apt-get install -y python-openstackclient


. ~ubuntu/openrc

~ubuntu/neutron-ext-net-ksv3 --network-type flat \
    -g 192.168.151.1 -c 192.168.151.0/24 \
    -f 192.168.151.51:192.168.151.100 \
    ext_net

~ubuntu/neutron-tenant-net-ksv3 -p admin -r provider-router \
    internal 10.5.5.0/24

openstack flavor create --vcpu 4 --ram 4096 --disk 20 m1.custom

openstack keypair create --public-key ~ubuntu/.ssh/id_rsa.pub mykey


# bootstrap on openstack
. ~ubuntu/openrc
if [ -n "$http_proxy" ]; then
    juju bootstrap openstack --debug \
        --model-default apt-http-proxy="$http_proxy" \
        --model-default use-floating-ip=true \
        --model-default network="$(openstack network show internal -f value -c id)" # LP: #1797924
else
    juju bootstrap openstack --debug \
        --model-default use-floating-ip=true \
        --model-default network="$(openstack network show internal -f value -c id)" # LP: #1797924
fi

juju deploy kubernetes-core

time juju-wait -w

juju run-action --wait kubernetes-worker/0 microbot replicas=3

# fix permission
chown ubuntu:ubuntu -R ~ubuntu/.local/
chown ubuntu:ubuntu /tmp/juju-store-lock-*
