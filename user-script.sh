#!/bin/bash

set -e
set -u
set -x

trap cleanup SIGHUP SIGINT SIGTERM EXIT

function cleanup () {
    mv /root/.maascli.db ~ubuntu/ || true
    mv /root/.local ~ubuntu/ || true
    mv /root/.kube ~ubuntu/ || true
    mv /root/.ssh/id_* ~ubuntu/.ssh/ || true
    mv /root/* ~ubuntu/ || true
    chown -f ubuntu:ubuntu -R ~ubuntu
}

# try not to kill some commands by session management
# it seems like a race condition with MAAS jobs in root user and snapped
# juju command's systemd scope
# LP: #1921876, LP: #2058030
loginctl enable-linger root

export DEBIAN_FRONTEND=noninteractive
mkdir -p /root/.local/share/juju/ssh/ # LP: #2029515
cd ~/

MAAS_PPA='ppa:maas/3.5-next'

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
    start_ip=192.168.151.1 end_ip=192.168.151.100
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
#sleep 30

# "Boot source selection with this Boot source, Os and Release already exists."
#maas admin boot-source-selections create 1 os=ubuntu release=jammy arches=amd64 subarches='*' labels='*'
#maas admin boot-resources import

# wait image again
#while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
#    sleep 15
#done

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
        --memory 16384 \
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

# juju
snap install juju
snap install --classic juju-wait

snap install vault

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

# bootstrap
cat > clouds.yaml <<EOF
clouds:
  maas:
    type: maas
    auth-types: [oauth1]
    endpoint: http://192.168.151.1:5240/MAAS
EOF
juju add-cloud --client maas -f clouds.yaml

cat > credentials.yaml <<EOF
credentials:
  maas:
    maas-credential:
      auth-type: oauth1
      maas-oauth: $(maas apikey --username ubuntu)
EOF
juju add-credential --client maas -f credentials.yaml

juju bootstrap maas maas-controller --debug \
    --model-default test-mode=true \
    --model-default disable-telemetry=true \
    --model-default logging-config='<root>=INFO;unit=DEBUG' \
    --model-default apt-http-proxy='http://192.168.151.1:8000/'
## TODO: host properties, proxy

# FIXME: LP: #2030280
juju model-defaults num-container-provision-workers=1

# LP: #2039156
juju deploy -m controller juju-dashboard --to 0 --base ubuntu@22.04  # LP: #2054375
juju integrate -m controller controller:dashboard juju-dashboard:controller


# Ceph

juju add-model ceph maas

juju deploy ./bundle.yaml

time juju-wait -m ceph -w --max_wait 5400

juju exec --unit ceph-osd/0 '
    set -x
    ls -alF /etc/ceph/
    ls -alF /etc/alternatives/ceph.conf
    update-alternatives --display ceph.conf
    cat "$(readlink -f /etc/ceph/ceph.conf)"
'

juju deploy ./bundle.yaml --overlay ./microk8s.yaml

time juju-wait -m ceph -w --max_wait 5400

juju exec --unit ceph-osd/0 '
    set -x
    ls -alF /etc/ceph/
    ls -alF /etc/alternatives/ceph.conf
    update-alternatives --display ceph.conf
    cat "$(readlink -f /etc/ceph/ceph.conf)"
'

# be nice to my SSD
juju model-config update-status-hook-interval=24h

juju models
