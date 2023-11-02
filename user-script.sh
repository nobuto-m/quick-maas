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
loginctl enable-linger root

export DEBIAN_FRONTEND=noninteractive
mkdir -p /root/.local/share/juju/ssh/ # LP: #2029515
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

maas admin pods create \
    type=virsh \
    cpu_over_commit_ratio=10 \
    memory_over_commit_ratio=1.5 \
    name=localhost \
    power_address="qemu+ssh://root@127.0.0.1/system"

# compose machines
## TODO: somehow lldpd in commissioning fails with num=8
num_machines=7
for _ in $(seq 1 "$num_machines"); do
    maas admin pod compose 1 \
        cores=8 \
        memory=11264 \
        storage='root:64'
done

# wait for a while until Pod machines will be booted
# but not too long so we can avoid LP: #2008454
sleep 15


# Allow the NVMe virtual drive with qemu commandline (outside of libvirt)
# https://github.com/coreos/bugs/issues/2083#issuecomment-380429909
echo '/var/lib/libvirt/images/*-nvme-* rwk,' > /etc/apparmor.d/local/abstractions/libvirt-qemu

for machine in $(virsh list --all --name); do
    virsh destroy "$machine"

    # NVMe SSD emulation
    # https://gitlab.com/libvirt/libvirt/-/issues/112
    virsh vol-create-as default --format raw \
        --allocation 0 \
        "${machine}-nvme-1" 16G

    # The NVMe drive will be handled by qemu outside of libvirt
    chown -v libvirt-qemu:kvm "/var/lib/libvirt/images/${machine}-nvme-1"

    virt-xml --edit \
        --qemu-commandline="-drive file=/var/lib/libvirt/images/${machine}-nvme-1,format=raw,if=none,id=NVME1" \
        "$machine"
    virt-xml --edit \
        --qemu-commandline="-device nvme,drive=NVME1,serial=${machine}_nvme1" \
        "$machine"

    # SATA SSD emulation
    for i in {a..c}; do
        virsh vol-create-as default --format raw \
            --allocation 0 \
            "${machine}-sata-${i}" 16G

        virsh attach-disk "$machine" \
            "/var/lib/libvirt/images/${machine}-sata-${i}" \
            "sd${i}" \
            --subdriver raw --targetbus sata \
            --serial "${machine}_${i}" \
            --config

        virt-xml --edit target="sd${i}" --disk "target.rotation_rate=1" "$machine"
    done

    # one more NIC
    virsh attach-interface "$machine" network maas --model virtio --config

    virsh start "$machine"
done

# juju
snap install --classic juju --channel 3.1
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

# add debugging for LP: #2030280
cat <<EOF | tee cloudinit-userdata.yaml
cloudinit-userdata: |
  preruncmd:
  - snap set lxd daemon.debug=true
  - systemctl restart snap.lxd.daemon.service
EOF

juju bootstrap maas maas-controller --debug \
    --model-default test-mode=true \
    --model-default logging-config='<root>=INFO;unit=DEBUG' \
    --model-default apt-http-proxy='http://192.168.151.1:8000/' \
    --model-default ./cloudinit-userdata.yaml # LP: #2030280
## TODO: host properties, proxy

# FIXME: LP: #2030280
juju model-defaults num-container-provision-workers=1

# LP: #2039156
juju deploy -m controller juju-dashboard --to 0
juju integrate -m controller controller:dashboard juju-dashboard:controller


# Ceph

juju add-model ceph maas

# LP: #2031637
git clone https://review.opendev.org/openstack/charm-ceph-osd
(cd charm-ceph-osd/ && git fetch https://review.opendev.org/openstack/charm-ceph-osd refs/changes/66/898966/4 && git checkout FETCH_HEAD)

juju deploy ./bundle.yaml


# COS

juju add-model cos-microk8s
juju deploy ./microk8s_bundle.yaml

time juju-wait -w --max_wait 1800

juju exec --unit microk8s/leader -- \
    microk8s enable metallb:192.168.151.81-192.168.151.100

# TODO: check if enabling ingress and rbac add-ons are necessary

snap install kubectl --classic
mkdir ~/.kube/
juju exec --unit microk8s/leader -- microk8s config | tee ~/.kube/config

juju add-k8s \
    --client --controller maas-controller \
    --context-name microk8s \
    cos-microk8s

juju add-model cos cos-microk8s

git clone --depth=1 https://github.com/canonical/cos-lite-bundle.git

juju deploy cos-lite --trust \
    --overlay ./cos-lite-bundle/overlays/offers-overlay.yaml \
    --overlay ./overlay-customize-cos-lite.yaml

# https://github.com/canonical/cos-lite-bundle/issues/86
#    --overlay ./storage-small-overlay.yaml


# Ceph post-deployment

time juju-wait -w --max_wait 5400 \
    --exclude vault \
    --exclude ceph-dashboard

VAULT_ADDR="http://$(juju exec --unit vault/leader -- network-get certificates --ingress-address):8200"
export VAULT_ADDR

vault_init_output="$(vault operator init -key-shares=1 -key-threshold=1 -format json)"
vault operator unseal -format json "$(echo "$vault_init_output" | jq -r .unseal_keys_b64[])"

VAULT_TOKEN="$(echo "$vault_init_output" | jq -r .root_token)"
export VAULT_TOKEN

# wait until Vault HA status settles, LP: #1987677
until vault status -format json | jq -r --exit-status .leader_cluster_address; do
    sleep 1
done

juju run --format=yaml vault/leader --wait=10m authorize-charm \
    token="$(vault token create -ttl=10m -format json | jq -r .auth.client_token)"
juju run --format=yaml vault/leader --wait=10m generate-root-ca
#time juju-wait -w --max_wait 1800 --retry_errors 3  # LP: #2040351
time juju-wait -w --max_wait 1800

# LP: #2040274
# LP: #2042419
juju exec --unit ceph-mon/leader '
    ceph osd pool application disable ceph-iscsi unknown --yes-i-really-mean-it
    ceph osd pool application disable iscsi unknown --yes-i-really-mean-it
    ceph osd pool application enable ceph-iscsi rbd
    ceph osd pool application enable iscsi rados
'


# COS post-deployment

time juju-wait -w --max_wait 300 -m cos

# https://github.com/canonical/grafana-agent-operator/issues/20
juju deploy -m controller grafana-agent --channel latest/edge
juju integrate -m controller controller:juju-info grafana-agent:juju-info
juju consume -m controller cos.prometheus-receive-remote-write cos-prometheus-receive-remote-write
juju integrate -m controller grafana-agent:send-remote-write cos-prometheus-receive-remote-write:receive-remote-write

# LP: #2041773 - no metrics integration
juju consume -m controller cos.grafana-dashboards cos-grafana-dashboards
juju integrate -m controller grafana-agent:grafana-dashboards-provider cos-grafana-dashboards:grafana-dashboard

# LP: #2038495 - log spamming
#juju consume -m controller cos.loki-logging cos-loki-logging
#juju integrate -m controller grafana-agent:logging-consumer cos-loki-logging:logging

juju deploy ./bundle.yaml \
    --overlay ./overlay-consume-cos.yaml

juju deploy -m cos-microk8s ./microk8s_bundle.yaml \
    --overlay ./microk8s-consume-cos.yaml

time juju-wait -m cos-microk8s -w --max_wait 1800
time juju-wait -w --max_wait 1800

# be nice to my SSD
juju model-config update-status-hook-interval=24h

# LP: #2042405 - manually enable the optional RBD per-image IO statistics
juju exec --unit ceph-mon/leader 'ceph config set mgr mgr/prometheus/rbd_stats_pools "*"'

juju run --format=yaml ceph-iscsi/leader --wait=10m create-target \
   client-initiatorname=iqn.2004-10.com.ubuntu:01:de21d53afe31 \
   client-username=testclient \
   client-password=12to16characters \
   image-size=3G \
   image-name=disk_1 \
   rbd-pool-name=ceph-iscsi \
   ec-rbd-metadata-pool='' # LP: #2042419

# do some activities in the Ceph cluster to have some metrics generated
juju exec --unit ceph-mon/leader -- ceph osd pool create scbench 32 32
juju exec --unit ceph-mon/leader -- ceph osd pool application enable scbench test
juju exec --unit ceph-mon/leader -- rados bench -p scbench 60 write -b 4096


# print the access info
juju status -m controller
# LP: #2039155
timeout 5 juju dashboard || true

juju status ceph-loadbalancer
juju run ceph-dashboard/leader add-user \
    username=admin role=administrator

juju show-unit -m cos catalogue/0 --format json \
    | jq -r '."catalogue/0"."relation-info"[]."application-data".url'
juju run -m cos grafana/leader get-admin-password

juju models
