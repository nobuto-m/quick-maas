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

MAAS_PPA='ppa:maas/3.1'

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

maas admin maas set-config name=enable_analytics value=false
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
    --model-default test-mode=true \
    --model-default logging-config='<root>=INFO;unit=DEBUG' \
    --model-default apt-http-proxy='http://192.168.151.1:8000/'

## host properties, proxy

# deploy openstack

# strip pinned charm revisions and the cs: prefix
sed -i.bak -e 's/charm: cs:\(.*\)-[0-9]\+/charm: \1/' \
    ~ubuntu/bundle.yaml
sed -i.bak -e 's/charm: cs:\(.*\)/charm: \1/' \
    ~ubuntu/loadbalancer-octavia.yaml

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
openstack_origin='cloud:focal-xena'
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

# LP: #1948621, LP: #1874059, barbican-vault gets stuck sometimes
juju remove-relation vault:secrets barbican-vault:secrets-storage
juju run-action vault/leader --wait generate-root-ca
time juju-wait -w --max_wait 1800 \
    --exclude octavia \
    --exclude barbican-vault
juju add-relation vault:secrets barbican-vault:secrets-storage

# sync images
time juju run-action --wait glance-simplestreams-sync/leader sync-images

juju run-action --wait octavia/leader configure-resources
juju scp ~ubuntu/.ssh/id_rsa* octavia/leader:
time juju run-action --wait octavia-diskimage-retrofit/leader retrofit-image

# LP: #1961088
juju run --application octavia -- grep bind_ip /etc/octavia/octavia.conf
juju run --application octavia -- hooks/config-changed
juju run --application octavia -- grep bind_ip /etc/octavia/octavia.conf

# be nice to my SSD
juju model-config update-status-hook-interval=24h

# setup openstack

set +u
# shellcheck disable=SC1091
. ~ubuntu/openrc
set -u

openstack role add \
    --user admin --user-domain admin_domain \
    --project admin --project-domain admin_domain \
    load-balancer_admin

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

openstack project create \
    --domain default \
    demo-project

openstack user create \
    --project demo-project \
    --password "$OS_PASSWORD" \
    demo-user

openstack role add \
    --user demo-user \
    --user-domain default \
    --project demo-project \
    member

openstack network create \
    --project demo-project \
    demo-net

openstack subnet create \
    --project demo-project \
    --network demo-net \
    --subnet-range 10.5.6.0/24 \
    demo-net_subnet

openstack router create \
    --project demo-project \
    demo-router

openstack router set --external-gateway ext_net demo-router

openstack router add subnet demo-router demo-net_subnet

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

juju download --no-progress kubernetes-core - | tee kubernetes-core.bundle >/dev/null
eatmydata apt-get install -y unzip
unzip -p kubernetes-core.bundle bundle.yaml > ~ubuntu/k8s_bundle.yaml

# LP: #1936842
sed -i.bak -e 's/lxd:0/0/' ~ubuntu/k8s_bundle.yaml

# https://github.com/charmed-kubernetes/bundle/blob/master/overlays/openstack-lb-overlay.yaml
cat > ~ubuntu/openstack-lb-overlay.yaml <<EOF
machines:
  '0':
    constraints: cores=2 mem=4G root-disk=16G  # mem=8G originally
  '1':
    constraints: cores=2 mem=4G root-disk=16G
applications:
  kubernetes-control-plane:
    constraints: cores=2 mem=4G root-disk=16G
  kubernetes-worker:
    constraints: cores=2 mem=4G root-disk=16G
  openstack-integrator:
    annotations:
      gui-x: "600"
      gui-y: "300"
    charm: openstack-integrator
    num_units: 1
    trust: true
    to:
    - '0'
    options:
      lb-floating-network: ext_net
relations:
  - ['openstack-integrator:loadbalancer', 'kubernetes-control-plane:loadbalancer']
  - ['openstack-integrator:clients', 'kubernetes-control-plane:openstack']
  - ['openstack-integrator:clients', 'kubernetes-worker:openstack']
EOF

juju deploy --trust ~ubuntu/k8s_bundle.yaml \
    --overlay ~ubuntu/openstack-lb-overlay.yaml

snap install kubectl --classic

time juju-wait -w --max_wait 2700

mkdir ~ubuntu/.kube/
juju run --unit kubernetes-control-plane/leader 'cat ~ubuntu/config' | tee ~ubuntu/.kube/config

juju run-action --wait kubernetes-worker/leader microbot replicas=3

#juju_model=k8s-on-openstack
#controller_uuid=$(juju show-model "$juju_model" --format json \
#    | jq -r ".\"$juju_model\" | .\"controller-uuid\"")
#model_uuid=$(juju show-model "$juju_model" --format json \
#    | jq -r ".\"$juju_model\" | .\"model-uuid\"")
#
#openstack security group rule create "juju-${controller_uuid}-${model_uuid}" \
#    --remote-ip "$(openstack subnet show internal_subnet -f value -c cidr)" \
#    --protocol tcp \
#    --dst-port 30000:32767
#
#kubectl expose deployment microbot --type=LoadBalancer --name=microbot-lb

kubectl wait deployment --all --for condition=Available=True --timeout=15m
kubectl --kubeconfig ~ubuntu/.kube/config get -o wide all

juju switch openstack
juju models
