#!/bin/bash

set -e
set -u
set -x

trap "chown -f ubuntu:ubuntu -R ~ubuntu /tmp/juju-store-lock-*" SIGHUP SIGINT SIGTERM EXIT

export DEBIAN_FRONTEND=noninteractive
export JUJU_DATA=~ubuntu/.local/share/juju

# proxy
if host squid-deb-proxy.lxd >/dev/null; then
    http_proxy="http://$(dig +short squid-deb-proxy.lxd):8000/"
    echo "Acquire::http::Proxy \"${http_proxy}\";" > /etc/apt/apt.conf
fi

# ppa
apt-add-repository -y ppa:maas/2.9

apt-get update

# metrics
eatmydata apt-get install -y prometheus-node-exporter
snap install prometheus-libvirt-exporter
snap connect prometheus-libvirt-exporter:libvirt

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

maas login admin http://localhost:5240/MAAS "$(maas apikey --username ubuntu)"

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

sleep 120

# MAAS Pod
sudo -u maas ssh-keygen -f ~maas/.ssh/id_rsa -N ''
install -m 0600 ~maas/.ssh/id_rsa.pub /root/.ssh/authorized_keys

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
        memory=8192 \
        storage='root:48,data1:16,data2:16,data3:16'
done

# wait for a while until Pod machines will be booted
sleep 30

for machine in $(virsh list --all --name); do
    virsh destroy "$machine"

    # expose CPU model
    virt-xml --edit --cpu mode=host-passthrough "$machine"

    # one more NIC
    virsh attach-interface "$machine" network maas --model virtio --config

    virsh start "$machine"
done

# juju
snap install --classic juju
snap install --classic juju-wait

while true; do
    maas_machines="$(maas admin machines read)"
    if echo "$maas_machines" | jq -r '.[].status_name' | grep -w 'Failed commissioning'; then
        exit 1
    fi
    if [ "$(echo "$maas_machines" | jq -r '.[].status_name' | grep -c -w 'Ready')" = "$num_machines" ]; then
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

sudo -u ubuntu -H ssh-keygen -f ~ubuntu/.ssh/id_rsa -N ''

# FIXME: remove "focal" when it becomes the default
juju bootstrap maas maas-controller --debug \
    --bootstrap-series focal \
    --model-default apt-http-proxy='http://192.168.151.1:8000/'

## host properties, proxy

# deploy openstack

juju deploy openstack-base
juju status --format json | jq -r '.applications | keys[]' \
    | xargs -L1 -t juju upgrade-charm || true

## FIXME: confirming if race condition is reproducible with the latest one
juju upgrade-charm ovn-central --switch cs:~openstack-charmers-next/ovn-central
juju upgrade-charm ovn-chassis --switch cs:~openstack-charmers-next/ovn-chassis

juju config nova-cloud-controller console-access-protocol=novnc
juju config ovn-chassis bridge-interface-mappings='br-ex:ens10'

juju config neutron-api-plugin-ovn dns-servers='8.8.8.8,8.8.4.4'
juju config neutron-api \
    enable-ml2-dns=true \
    dns-domain=openstack.internal.

# TODO: discuss the necessity of vault itself
juju config vault totally-unsecure-auto-unlock=true
juju config vault auto-generate-root-ca-cert=true

juju deploy --to lxd:2 glance-simplestreams-sync
juju config glance-simplestreams-sync mirror_list="
    [{url: 'http://cloud-images.ubuntu.com/releases/', name_prefix: 'ubuntu:released', path: 'streams/v1/index.sjson', max: 1,
    item_filters: ['release=focal', 'arch~(x86_64|amd64)', 'ftype~(disk1.img|disk.img)']}]
    "
juju add-relation glance-simplestreams-sync:identity-service keystone:identity-service
juju add-relation glance-simplestreams-sync:certificates vault:certificates

time juju-wait -w

# sync images
juju run-action --wait glance-simplestreams-sync/leader sync-images

# be nice to my SSD
juju model-config update-status-hook-interval=24h

# setup openstack

snap install openstackclients --channel latest/edge

git clone https://github.com/openstack-charmers/openstack-bundles.git

cp -v openstack-bundles/stable/shared/openrc* ~ubuntu/

# TODO: remove this workaround
# redirection ">" doesn't work with Juju CLI, LP: #1849753
# https://github.com/openstack-charmers/openstack-charm-testing/pull/70
sed -i -e "s@.*leader-get root-ca.*@juju run \$_juju_model_arg --unit vault/leader 'leader-get root-ca' | tee \$_root_ca >/dev/null 2>\&1@" ~ubuntu/openrc

set +u
# shellcheck disable=SC1091
. ~ubuntu/openrc
set -u

openstack network create --external \
    --provider-network-type flat \
    --provider-physical-network physnet1 \
    ext_net

openstack subnet create \
    --network ext_net \
    --subnet-range 192.168.151.0/24 \
    --gateway 192.168.151.1 \
    --allocation-pool start=192.168.151.51,end=192.168.151.100 \
    ext_net_subnet

openstack network create internal

openstack subnet create \
    --network internal \
    --subnet-range 10.5.5.0/24 \
    internal_subnet

openstack router create provider-router

openstack router set --external-gateway ext_net provider-router

openstack router add subnet provider-router internal_subnet

openstack flavor create --vcpu 4 --ram 4096 --disk 20 m1.custom

openstack keypair create --public-key ~ubuntu/.ssh/id_rsa.pub mykey


# bootstrap on openstack

cat <<EOF | juju add-cloud -c maas-controller --client openstack /dev/stdin
clouds:
  openstack:
    type: openstack
    auth-types: [userpass]
    regions:
      ${OS_REGION_NAME}:
        endpoint: $OS_AUTH_URL
    ca-certificates:
    - |
$(sed -e 's/^/      /' "$OS_CACERT")
EOF

cat <<EOF | juju add-credential -c maas-controller --client openstack -f /dev/stdin
credentials:
  openstack:
    $OS_USERNAME:
      auth-type: userpass
      domain-name: ""
      password: $OS_PASSWORD
      project-domain-name: $OS_PROJECT_DOMAIN_NAME
      tenant-id: ""
      tenant-name: $OS_PROJECT_NAME
      user-domain-name: $OS_USER_DOMAIN_NAME
      username: $OS_USERNAME
      version: "$OS_IDENTITY_API_VERSION"
EOF

juju model-defaults "openstack/${OS_REGION_NAME}" \
    apt-http-proxy='http://192.168.151.1:8000/' \
    network="$(openstack network show internal -f value -c id)" \
    external-network="$(openstack network show ext_net -f value -c id)"
    # LP: #1797924
    # LP: #1891227 # remove when 2.8.7 is released

juju add-model kubernetes "openstack/${OS_REGION_NAME}"

juju deploy kubernetes-core

time juju-wait -w

juju run-action --wait kubernetes-worker/0 microbot replicas=3
