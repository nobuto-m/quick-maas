#!/bin/bash

set -e
set -u
set -x

trap cleanup SIGHUP SIGINT SIGTERM EXIT

function cleanup () {
    mv -b /root/.maascli.db ~ubuntu/ || true
    mv -b /root/.local ~ubuntu/ || true
    mv -b /root/.kube ~ubuntu/ || true
    mv -b /root/.ssh/id_* ~ubuntu/.ssh/ || true
    mv -b /root/* ~ubuntu/ || true
    chown -f ubuntu:ubuntu -R ~ubuntu
}

# try not to kill some commands by session management
# it seems like a race condition with MAAS jobs in root user and snapped
# juju command's systemd scope
# LP: #1921876, LP: #2058030
loginctl enable-linger root

export DEBIAN_FRONTEND=noninteractive
export HOME=/root 
cd ~/

MAAS_PPA='ppa:maas/3.4-next'

# proxy
if host squid-deb-proxy.lxd >/dev/null; then
    http_proxy="http://$(dig +short squid-deb-proxy.lxd):8000/"
    echo "Acquire::http::Proxy \"${http_proxy}\";" > /etc/apt/apt.conf
fi

# ppa
apt-add-repository -y "$MAAS_PPA"

apt-get update

# utils
eatmydata apt-get install -y tree jq

# KVM setup
eatmydata apt-get install -y libvirt-daemon-system
eatmydata apt-get install -y virtinst --no-install-recommends

cat >> /etc/libvirt/qemu.conf <<EOF

# Avoid the error in LXD containers:
# Unable to set XATTR trusted.libvirt.security.dac on
# /var/lib/libvirt/qemu/domain-*: Operation not permitted
remember_owner = 0
EOF

systemctl restart libvirtd.service

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
eatmydata apt-get install -y maas

# maas login as ubuntu/ubuntu
maas createadmin --username ubuntu --password ubuntu \
    --email ubuntu@localhost.localdomain

# LP: #2031842
sleep 30
maas login admin http://localhost:5240/MAAS "$(maas apikey --username ubuntu)"

ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
maas admin sshkeys create key="$(cat ~/.ssh/id_ed25519.pub)"

maas admin maas set-config name=enable_analytics value=false
maas admin maas set-config name=release_notifications value=false
maas admin maas set-config name=maas_name value='Demo'
maas admin maas set-config name=kernel_opts value='console=tty0 console=ttyS0,115200n8'
maas admin maas set-config name=completed_intro value=true

# configure network / DHCP
maas admin subnet update 192.168.151.0/24 \
    gateway_ip=192.168.151.1 \
    dns_servers=192.168.151.1

fabric=$(maas admin subnets read | jq -r \
    '.[] | select(.cidr=="192.168.151.0/24").vlan.fabric')
maas admin ipranges create type=reserved \
    start_ip=192.168.151.1 end_ip=192.168.151.80
maas admin ipranges create type=dynamic \
    start_ip=192.168.151.201 end_ip=192.168.151.254
maas admin vlan update "$fabric" 0 dhcp_on=true primary_rack="$HOSTNAME"

maas admin spaces create name=space-first
fabric_id=$(maas admin subnets read | jq -r '.[] | select(.cidr=="192.168.151.0/24").vlan.fabric_id')
maas admin vlan update "$fabric_id" 0 space=space-first

# wait image
time while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
    sleep 15
done

# add jammy image
# LP: #2031842
sleep 30
maas admin boot-source-selections create 1 os=ubuntu release=jammy arches=amd64 subarches='*' labels='*'
maas admin boot-resources import

# wait image again
while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
    sleep 15
done

sleep 120

# MAAS Pod
sudo -u maas -H ssh-keygen -t ed25519 -f ~maas/.ssh/id_ed25519 -N ''
install -m 0600 ~maas/.ssh/id_ed25519.pub /root/.ssh/authorized_keys

# "pod compose" is not going to be used
# but register the KVM host just for the UI demo purpose
maas admin pods create \
    type=virsh \
    cpu_over_commit_ratio=10 \
    memory_over_commit_ratio=1.5 \
    name=localhost \
    power_address='qemu+ssh://root@127.0.0.1/system'

# compose machines
num_machines=8
for i in $(seq 1 "$num_machines"); do

    case "$i" in
        6|7|8)
            memory=4096
        ;;
        5)
            memory=4096
        ;;
        *)
            memory=18432
        ;;
    esac

    # TODO: --boot uefi
    # Starting vTPM manufacturing as swtpm:swtpm
    # swtpm process terminated unexpectedly.
    # Could not start the TPM 2.
    # An error occurred. Authoring the TPM state failed.
    virt-install \
        --import --noreboot \
        --name "machine-$i"\
        --osinfo ubuntujammy \
        --boot network,hd \
        --vcpus cores=16 \
        --cpu host-passthrough,cache.mode=passthrough \
        --memory "$memory" \
        --disk size=64,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
        --disk size=16,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
        --disk size=16,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
        --disk size=16,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
        --network network=maas \
        --network network=maas

    maas admin machines create \
        hostname="machine-$i" \
        architecture=amd64 \
        mac_addresses="$(virsh dumpxml "machine-$i" | xmllint --xpath 'string(//mac/@address)' -)" \
        power_type=virsh \
        power_parameters_power_address='qemu+ssh://root@127.0.0.1/system' \
        power_parameters_power_id="machine-$i"
done

time while true; do
    maas_machines_statuses="$(maas admin machines read | jq -r '.[].status_name')"
    if echo "$maas_machines_statuses" | grep -w 'Failed commissioning'; then
        exit 1
    fi
    if [ "$(echo "$maas_machines_statuses" | grep -c -w 'Ready')" = "$num_machines" ]; then
        break
    fi
    sleep 15
done


# https://microstack.run/docs/multi-node-maas

maas admin tags create name=openstack-mysunbeam
maas admin tags create name=juju-controller
maas admin tags create name=infra
maas admin tags create name=control
maas admin tags create name=compute
maas admin tags create name=storage

maas admin ipranges create type=reserved \
    comment=mysunbeam-public-api \
    start_ip=192.168.151.81 end_ip=192.168.151.90
maas admin ipranges create type=reserved \
    comment=mysunbeam-internal-api \
    start_ip=192.168.151.91 end_ip=192.168.151.100

for i in $(seq 1 "$num_machines"); do
    system_id="$(maas admin machines read hostname="machine-$i" | jq -r '.[].system_id')"

    case "$i" in
        #6|7|8)  # HA
        6)  # no HA
            maas admin tag update-nodes openstack-mysunbeam add="$system_id"
            maas admin tag update-nodes juju-controller add="$system_id"
        ;;
        5)
            maas admin tag update-nodes openstack-mysunbeam add="$system_id"
            maas admin tag update-nodes infra add="$system_id"
        ;;
        1|2|3)
            maas admin tag update-nodes openstack-mysunbeam add="$system_id"
            maas admin tag update-nodes control add="$system_id"
            maas admin tag update-nodes compute add="$system_id"
            maas admin tag update-nodes storage add="$system_id"

            block_device_id="$(maas admin block-devices read "$system_id" | jq -r '.[] | select(.name=="sdb").id')"
            maas admin block-device add-tag "$system_id" "$block_device_id" tag=ceph

            # LP: #2066379
            interface_id="$(maas admin interfaces read "$system_id" | jq -r '.[] | select(.name=="enp2s0").id')"
            maas admin interface add-tag "$system_id" "$interface_id" tag='neutron:physnet1'
        ;;
    esac
done

snap install openstack --channel 2024.1/edge

sunbeam prepare-node-script --client | bash -x

# LP: #2066541
adduser ubuntu snap_daemon

sunbeam deployment add maas --name mysunbeam \
    --token "$(maas apikey --username ubuntu)" \
    --url 'http://192.168.151.1:5240/MAAS' \

sunbeam deployment space map space-first data
sunbeam deployment space map space-first internal
sunbeam deployment space map space-first management
sunbeam deployment space map space-first public
sunbeam deployment space map space-first storage
sunbeam deployment space map space-first storage-cluster

time sunbeam deployment validate

tail -n+3 /snap/openstack/current/etc/manifests/edge.yml >> manifest.yaml

time sunbeam cluster bootstrap --manifest manifest.yaml

sunbeam cluster deploy &
    time until juju status -m openstack-machines; do
        sleep 10
    done

    time until juju status -m openstack; do
        sleep 10
    done
    # LP: #2065490
    juju model-default --cloud mysunbeam-k8s logging-config='<root>=INFO;unit=DEBUG'
    juju model-config -m openstack logging-config='<root>=INFO;unit=DEBUG' \
        update-status-hook-interval=30m  # LP: #2067451
time wait -n

time sunbeam --verbose configure --openrc demo-openrc

time sunbeam openrc > admin-openrc

time sunbeam launch ubuntu --name test
