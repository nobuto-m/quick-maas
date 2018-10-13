#!/bin/bash

set -e
set -u
set -x

export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/snap/bin"
export JUJU_DATA='/root/.local/share/juju'

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
eatmydata apt-get install -y virt-host^
eatmydata apt-get install -y virtinst --no-install-recommends

virsh net-destroy default
virsh net-autostart --disable default

virsh pool-define-as default dir --target /var/lib/libvirt/images
virsh pool-autostart default
virsh pool-start default

cat <<EOF | virsh net-define /dev/stdin
<network>
  <name>maas</name>
  <bridge name='maas'/>
  <forward mode='nat'/>
  <ip address='192.168.151.1' netmask='255.255.255.0'/>
</network>
EOF
virsh net-autostart maas
virsh net-start maas

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

# explicitly set xenial, LP: #1767137
maas admin boot-source-selection update 1 1 release=xenial

# start importing image
if [ -n "$http_proxy" ]; then
    maas admin maas set-config name=http_proxy value="$http_proxy"
    maas admin boot-resources stop-import
    while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
        sleep 15
    done
    maas admin boot-resources import
fi

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
sleep 30

# MAAS Pod
sudo -u maas ssh-keygen -f ~maas/.ssh/id_rsa -N ''
install -m 0600 ~maas/.ssh/id_rsa.pub /root/.ssh/authorized_keys

maas admin pods create \
    type=virsh \
    name=localhost \
    power_address="qemu+ssh://root@localhost/system"

# compose machines
for i in {1..6}; do
    maas admin pod compose 1 \
        cores=8 \
        memory=32768 \
        storage='default:64'
done

# wait for a while until Pod machines will be booted
sleep 15

for machine in $(virsh list --all --name); do
    virsh destroy "$machine"

    # expose CPU model
    virt-xml --edit --cpu mode=host-passthrough

    # one more NIC
    virsh attach-interface "$machine" network maas --model virtio --config

    # virt-xml --edit --disk target_bus=sata
    # one more disk
    virsh vol-create-as default "${machine}_sdb" 64G
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

while [ "$(maas admin machines read | jq -r '.[].status_name' | grep -c -w Ready)" != '6' ]; do
    sleep 15
done

# bootstrap
cat > clouds.yaml <<EOF
clouds:
  maas:
    type: maas
    auth-types: [oauth1]
    endpoint: http://192.168.151.1/MAAS
EOF
sudo -u ubuntu -H juju add-cloud maas -f clouds.yaml

cat > credentials.yaml <<EOF
credentials:
  maas:
    maas-credential:
      auth-type: oauth1
      maas-oauth: $(maas apikey --username ubuntu)
EOF
sudo -u ubuntu -H juju add-credential maas -f credentials.yaml

sudo -u ubuntu -H ssh-keygen -f ~ubuntu/.ssh/id_rsa -N ''

sudo -u ubuntu -H juju bootstrap maas maas-controller --debug \
    --bootstrap-series xenial


# To remove
sudo -u ubuntu -H juju deploy openstack-base-51

#sudo -u ubuntu -H juju config ceph-osd osd-devices='/dev/vdb' ## TODO
sudo -u ubuntu -H juju config neutron-gateway data-port='br-ex:ens8'
