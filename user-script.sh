#!/bin/bash

set -e
set -u
set -x

trap cleanup SIGHUP SIGINT SIGTERM EXIT

function cleanup () {
    mv -v /root/.maascli.db ~ubuntu/ || true
    chown -f ubuntu:ubuntu -R ~ubuntu /tmp/juju-store-lock-*
}

# try not to kill some commands by session management
# it seems like a race condition with MAAS jobs in root user and snapped
# juju command's systemd scope
loginctl enable-linger root

export DEBIAN_FRONTEND=noninteractive
export JUJU_DATA=~ubuntu/.local/share/juju

MAAS_PPA='ppa:maas/2.9'

# proxy
if host squid-deb-proxy.lxd >/dev/null; then
    http_proxy="http://$(dig +short squid-deb-proxy.lxd):8000/"
    echo "Acquire::http::Proxy \"${http_proxy}\";" > /etc/apt/apt.conf
fi

# ppa
apt-add-repository -y "$MAAS_PPA"

apt-get update

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
  <forward mode='route'/>
  <ip address='192.168.151.1' netmask='255.255.255.0'/>
</network>
EOF
virsh net-autostart maas
virsh net-start maas

cat <<EOF | virsh net-define /dev/stdin
<network>
  <name>maas2</name>
  <bridge name='maas2' stp='off'/>
  <forward mode='route'/>
  <ip address='192.168.152.1' netmask='255.255.255.0'/>
</network>
EOF
virsh net-autostart maas2
virsh net-start maas2

cat <<EOF | virsh net-define /dev/stdin
<network>
  <name>maas3</name>
  <bridge name='maas3' stp='off'/>
  <forward mode='route'/>
  <ip address='192.168.153.1' netmask='255.255.255.0'/>
</network>
EOF
virsh net-autostart maas3
virsh net-start maas3

# enable SNAT for outgoing traffic
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# maas package install
echo maas-region-controller maas/default-maas-url string 192.168.151.1 \
    | debconf-set-selections
eatmydata apt-get install -y maas

# maas login as ubuntu/ubuntu
maas createadmin --username ubuntu --password ubuntu \
    --email ubuntu@localhost.localdomain

maas login admin http://localhost:5240/MAAS "$(maas apikey --username ubuntu)"

maas admin maas set-config name=enable_analytics value=false
maas admin maas set-config name=maas_name value='Demo'
maas admin maas set-config name=kernel_opts value='console=tty0 console=ttyS0,115200n8'
maas admin maas set-config name=completed_intro value=true

# configure network / DHCP
eatmydata apt-get install -y jq

maas admin zones create name=zone2
maas admin zones create name=zone3

maas admin subnet update 192.168.151.0/24 \
    gateway_ip=192.168.151.1 \
    dns_servers=192.168.151.1

maas admin subnet update 192.168.152.0/24 \
    gateway_ip=192.168.152.1 \
    dns_servers=192.168.152.1

maas admin subnet update 192.168.153.0/24 \
    gateway_ip=192.168.153.1 \
    dns_servers=192.168.153.1

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

fabric=$(maas admin subnets read | jq -r \
    '.[] | select(.cidr=="192.168.153.0/24").vlan.fabric')
maas admin ipranges create type=reserved \
    start_ip=192.168.153.1 end_ip=192.168.153.100
maas admin ipranges create type=dynamic \
    start_ip=192.168.153.201 end_ip=192.168.153.254
maas admin vlan update "$fabric" 0 dhcp_on=true primary_rack="$HOSTNAME"

maas admin spaces create name=space-first
fabric_id=$(maas admin subnets read | jq -r '.[] | select(.cidr=="192.168.151.0/24").vlan.fabric_id')
maas admin vlan update "$fabric_id" 0 space=space-first

fabric_id=$(maas admin subnets read | jq -r '.[] | select(.cidr=="192.168.152.0/24").vlan.fabric_id')
maas admin vlan update "$fabric_id" 0 space=space-first

fabric_id=$(maas admin subnets read | jq -r '.[] | select(.cidr=="192.168.153.0/24").vlan.fabric_id')
maas admin vlan update "$fabric_id" 0 space=space-first

# wait image
time while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
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
        memory=11264 \
        storage='root:48,data1:16,data2:16,data3:16'
done

# wait for a while until Pod machines will be booted
sleep 30

i=0
for machine in $(virsh list --all --name | sort); do
    virsh destroy "$machine"

    # expose CPU model
    virt-xml --edit --cpu mode=host-passthrough "$machine"

    i=$((i + 1))
    system_id=$(maas admin machines read hostname="$machine" | jq -r '.[].system_id')

    case "$i" in
        1|2|3)
            virsh attach-interface "$machine" network maas --model virtio --config
        ;;
        4|5)
            maas admin machine update "$system_id" zone=zone2
            virt-xml --edit --network network=maas2 "$machine"
            virsh attach-interface "$machine" network maas2 --model virtio --config
        ;;
        6|7)
            maas admin machine update "$system_id" zone=zone3
            virt-xml --edit --network network=maas3 "$machine"
            virsh attach-interface "$machine" network maas3 --model virtio --config
        ;;
    esac

    virsh start "$machine"
    sleep 15
done

# juju
snap install --classic juju
snap install --classic juju-wait

snap install openstackclients
git clone https://github.com/openstack-charmers/openstack-bundles.git
cp -v openstack-bundles/stable/shared/openrc* ~ubuntu/
cp -v openstack-bundles/stable/openstack-base/bundle.yaml ~ubuntu/
cp -v openstack-bundles/stable/overlays/loadbalancer-octavia.yaml ~ubuntu/

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

maas admin tags create name=juju
maas admin tags create name=calico-rr

i=0
for machine in $(virsh list --all --name | sort); do
    i=$((i + 1))
    system_id=$(maas admin machines read hostname="$machine" | jq -r '.[].system_id')

    case "$i" in
        1)
            maas admin tag update-nodes juju add="$system_id"
        ;;
        2)
            maas admin tag update-nodes calico-rr add="$system_id"

            link_id=$(maas admin interfaces read "$system_id" | jq -r '.[] | select(.name=="ens4").links[].id')
            maas admin interface unlink-subnet "$system_id" ens4 id="$link_id"
            maas admin interface link-subnet "$system_id" ens4 \
                mode=STATIC subnet=192.168.151.0/24 ip_address=192.168.151.91
        ;;
        4)
            maas admin tag update-nodes calico-rr add="$system_id"

            link_id=$(maas admin interfaces read "$system_id" | jq -r '.[] | select(.name=="ens4").links[].id')
            maas admin interface unlink-subnet "$system_id" ens4 id="$link_id"
            maas admin interface link-subnet "$system_id" ens4 \
                mode=STATIC subnet=192.168.152.0/24 ip_address=192.168.152.91
        ;;
        6)
            maas admin tag update-nodes calico-rr add="$system_id"

            link_id=$(maas admin interfaces read "$system_id" | jq -r '.[] | select(.name=="ens4").links[].id')
            maas admin interface unlink-subnet "$system_id" ens4 id="$link_id"
            maas admin interface link-subnet "$system_id" ens4 \
                mode=STATIC subnet=192.168.153.0/24 ip_address=192.168.153.91
        ;;
    esac
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

juju bootstrap maas maas-controller --debug \
    --no-default-model \
    --bootstrap-constraints tags=juju \
    --model-default test-mode=true \
    --model-default logging-config='<root>=INFO;unit=DEBUG' \
    --model-default apt-http-proxy='http://192.168.151.1:8000/'

exit

## host properties, proxy

# deploy openstack

# strip pinned charm revisions
sed -i.bak -e 's/\(charm: cs:.*\)-[0-9]\+/\1/' ~ubuntu/bundle.yaml

openstack_origin=$(grep '&openstack-origin' ~ubuntu/bundle.yaml | NF)

mkdir ~ubuntu/certs
(cd ~ubuntu/certs;
    # https://opendev.org/openstack/charm-octavia#amphora-provider-required-configuration
    mkdir -p demoCA/newcerts
    touch demoCA/index.txt
    touch demoCA/index.txt.attr
    openssl genrsa -passout pass:foobar -des3 -out issuing_ca_key.pem 2048
    openssl req -x509 -passin pass:foobar -new -nodes -key issuing_ca_key.pem \
        -config /etc/ssl/openssl.cnf \
        -subj "/C=US/ST=Somestate/O=Org/CN=www.example.com" \
        -days 360 \
        -out issuing_ca.pem

    openssl genrsa -passout pass:foobar -des3 -out controller_ca_key.pem 2048
    openssl req -x509 -passin pass:foobar -new -nodes \
            -key controller_ca_key.pem \
        -config /etc/ssl/openssl.cnf \
        -subj "/C=US/ST=Somestate/O=Org/CN=www.example.com" \
        -days 360 \
        -out controller_ca.pem
    openssl req \
        -newkey rsa:2048 -nodes -keyout controller_key.pem \
        -subj "/C=US/ST=Somestate/O=Org/CN=www.example.com" \
        -out controller.csr
    openssl ca -passin pass:foobar -config /etc/ssl/openssl.cnf \
        -cert controller_ca.pem -keyfile controller_ca_key.pem \
        -create_serial -batch \
        -in controller.csr -days 360 -out controller_cert.pem
    cat controller_cert.pem controller_key.pem > controller_cert_bundle.pem
)

cat > ~ubuntu/overlay-options.yaml <<EOF
applications:
  nova-cloud-controller:
    options:
      console-access-protocol: 'novnc'
  openstack-dashboard:
    options:
      webroot: /
      allow-password-autocompletion: true
  ovn-chassis:
    options:
      bridge-interface-mappings: 'br-ex:ens10'
  neutron-api-plugin-ovn:
    options:
      dns-servers: '8.8.8.8,8.8.4.4'
  neutron-api:
    options:
      # https://github.com/openstack-charmers/openstack-bundles/pull/218/files
      enable-ml2-port-security: true
      enable-ml2-dns: true
      dns-domain: 'openstack.internal.'
  vault:
    options:
      # only for testing and demo purpose
      totally-unsecure-auto-unlock: true
EOF

cat > ~ubuntu/overlay-octavia-options.yaml <<EOF
applications:
  barbican:
    options:
      openstack-origin: "$openstack_origin"
  octavia:
    # LP: #1927960
    charm: cs:~openstack-charmers-next/octavia
    options:
      openstack-origin: "$openstack_origin"
      lb-mgmt-issuing-cacert: include-base64://./certs/issuing_ca.pem
      lb-mgmt-issuing-ca-private-key: include-base64://./certs/issuing_ca_key.pem
      lb-mgmt-issuing-ca-key-passphrase: foobar
      lb-mgmt-controller-cacert: include-base64://./certs/controller_ca.pem
      lb-mgmt-controller-cert: include-base64://./certs/controller_cert_bundle.pem
      # debugging purpose
      amp-ssh-key-name: amp_ssh_pub_key
      amp-ssh-pub-key: include-base64://./.ssh/id_rsa.pub
  glance-simplestreams-sync:
    annotations:
      gui-x: '-160'
      gui-y: '1550'
    options:
      mirror_list: |
        [{url: 'http://cloud-images.ubuntu.com/releases/', name_prefix: 'ubuntu:released', path: 'streams/v1/index.sjson', max: 1,
        item_filters: ['release=focal', 'arch~(x86_64|amd64)', 'ftype~(disk1.img|disk.img)']}]
EOF

# Octavia with cloud:focal-wallaby may have some race conditions
# like LP: #1931734
openstack_origin='distro'
cat > ~ubuntu/overlay-release.yaml <<EOF
applications:
  ceph-mon:
    options:
      source: "$openstack_origin"
  ceph-osd:
    options:
      source: "$openstack_origin"
  ceph-radosgw:
    options:
      source: "$openstack_origin"
  ovn-central:
    options:
      source: "$openstack_origin"

  barbican:
    options:
      openstack-origin: "$openstack_origin"
  cinder:
    options:
      openstack-origin: "$openstack_origin"
  glance:
    options:
      openstack-origin: "$openstack_origin"
  keystone:
    options:
      openstack-origin: "$openstack_origin"
  neutron-api:
    options:
      openstack-origin: "$openstack_origin"
  nova-cloud-controller:
    options:
      openstack-origin: "$openstack_origin"
  nova-compute:
    options:
      openstack-origin: "$openstack_origin"
  octavia:
    options:
      openstack-origin: "$openstack_origin"
  openstack-dashboard:
    options:
      openstack-origin: "$openstack_origin"
  placement:
    options:
      openstack-origin: "$openstack_origin"
EOF

juju add-model openstack
juju deploy ~ubuntu/bundle.yaml \
    --overlay ~ubuntu/overlay-options.yaml \
    --overlay ~ubuntu/loadbalancer-octavia.yaml \
    --overlay ~ubuntu/overlay-octavia-options.yaml \
    --overlay ~ubuntu/overlay-release.yaml

time juju-wait -w --max_wait 4500 \
    --exclude vault \
    --exclude neutron-api-plugin-ovn \
    --exclude ovn-central \
    --exclude ovn-chassis \
    --exclude octavia \
    --exclude octavia-ovn-chassis \
    --exclude barbican-vault

juju run-action vault/leader --wait generate-root-ca
time juju-wait -w --max_wait 1800 \
    --exclude octavia

# sync images
time juju run-action --wait glance-simplestreams-sync/leader sync-images

juju run-action --wait octavia/leader configure-resources
time juju run-action --wait octavia-diskimage-retrofit/leader retrofit-image

# be nice to my SSD
juju model-config update-status-hook-interval=24h

# setup openstack

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

# use stdout and stdin to bypass the confinement to read other users' home directory
# shellcheck disable=SC2002
cat ~ubuntu/.ssh/id_rsa.pub | openstack keypair create --public-key /dev/stdin mykey

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
    test-mode=true \
    logging-config='<root>=INFO;unit=DEBUG' \
    apt-http-proxy='http://192.168.151.1:8000/' \
    network="$(openstack network show internal -f value -c id)"
    # network: to exclude lb-mgmt-net which is visible from the admin tenant

juju add-model k8s-on-openstack "openstack/${OS_REGION_NAME}"
juju set-model-constraints allocate-public-ip=true # LP: #1947555

wget -O ~ubuntu/k8s_bundle.yaml https://api.jujucharms.com/charmstore/v5/bundle/kubernetes-core/archive/bundle.yaml

# LP: #1936842
sed -i.bak -e 's/lxd:0/0/' ~ubuntu/k8s_bundle.yaml

# https://github.com/charmed-kubernetes/bundle/blob/master/overlays/openstack-lb-overlay.yaml
cat > ~ubuntu/openstack-lb-overlay.yaml <<EOF
applications:
  openstack-integrator:
    annotations:
      gui-x: "600"
      gui-y: "300"
    charm: cs:~containers/openstack-integrator
    num_units: 1
    trust: true
    to:
    - '0'
    options:
      lb-floating-network: ext_net
relations:
  - ['openstack-integrator:loadbalancer', 'kubernetes-master:loadbalancer']
  - ['openstack-integrator:clients', 'kubernetes-master:openstack']
  - ['openstack-integrator:clients', 'kubernetes-worker:openstack']
EOF

juju deploy --trust ~ubuntu/k8s_bundle.yaml \
    --overlay ~ubuntu/openstack-lb-overlay.yaml

snap install kubectl --classic

time juju-wait -w --max_wait 2700

mkdir ~ubuntu/.kube/
juju run --unit kubernetes-master/leader 'cat ~ubuntu/config' | tee ~ubuntu/.kube/config

juju run-action --wait kubernetes-worker/leader microbot replicas=3

kubectl --kubeconfig ~ubuntu/.kube/config get -o wide pods,services,ingress

juju switch openstack
juju models
