#!/bin/bash

set -e
set -u
set -x

trap cleanup SIGHUP SIGINT SIGTERM EXIT

function cleanup () {
    mv /root/.maascli.db ~ubuntu/ || true
    mv /root/.local ~ubuntu/ || true
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
    # LP: #1965554 - "Connection was closed cleanly" can happen
    time maas admin pod compose 1 \
        cores=8 \
        memory=11264 \
        storage='root:64,data1:16,data2:16,data3:16'
done

# wait for a while until Pod machines will be booted
# but not too long so we can avoid LP: #2008454
sleep 15

for machine in $(virsh list --all --name); do
    virsh destroy "$machine"

    # one more NIC
    virsh attach-interface "$machine" network maas --model virtio --config

    virsh start "$machine"
done

# juju
snap install juju
snap install --classic juju-wait

snap install vault
snap install openstackclients
git clone https://github.com/openstack-charmers/openstack-bundles.git
cp -v openstack-bundles/stable/shared/openrc* ./
cp -v openstack-bundles/development/openstack-base-jammy-yoga/bundle.yaml ./
cp -v openstack-bundles/stable/overlays/loadbalancer-octavia.yaml ./

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

## host properties, proxy

# deploy openstack

mkdir certs/
(cd certs/;
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

cat > overlay-options.yaml <<EOF
applications:
  nova-cloud-controller:
    options:
      console-access-protocol: 'novnc'
  nova-compute:
    options:
      aa-profile-mode: enforce
  ceph-mon:
    options:
      # LP: #1929262
      config-flags: '{"mon":{"auth allow insecure global id reclaim":"false"}}'
  ceph-osd:
    options:
      aa-profile-mode: complain
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
EOF

openstack_origin='distro'
cat > overlay-octavia-options.yaml <<EOF
applications:
  barbican-mysql-router:
    charm: ch:mysql-router
    channel: 8.0/stable
  barbican:
    charm: ch:barbican
    channel: yoga/stable
    options:
      openstack-origin: "$openstack_origin"
  barbican-vault:
    charm: ch:barbican-vault
    channel: yoga/stable
  octavia-ovn-chassis:
    charm: ch:ovn-chassis
    channel: 22.03/stable
  octavia-mysql-router:
    charm: ch:mysql-router
    channel: 8.0/stable
  octavia:
    charm: ch:octavia
    channel: yoga/stable
    options:
      openstack-origin: "$openstack_origin"
      lb-mgmt-issuing-cacert: include-base64://./certs/issuing_ca.pem
      lb-mgmt-issuing-ca-private-key: include-base64://./certs/issuing_ca_key.pem
      lb-mgmt-issuing-ca-key-passphrase: foobar
      lb-mgmt-controller-cacert: include-base64://./certs/controller_ca.pem
      lb-mgmt-controller-cert: include-base64://./certs/controller_cert_bundle.pem
      # debugging purpose
      amp-ssh-key-name: amp_ssh_pub_key
      amp-ssh-pub-key: include-base64://./.ssh/id_ed25519.pub
  octavia-dashboard:
    charm: ch:octavia-dashboard
    channel: yoga/stable
  glance-simplestreams-sync:
    charm: ch:glance-simplestreams-sync
    channel: yoga/stable
    annotations:
      gui-x: '-160'
      gui-y: '1550'
    options:
      mirror_list: |
        [{url: 'http://cloud-images.ubuntu.com/releases/', name_prefix: 'ubuntu:released', path: 'streams/v1/index.sjson', max: 1,
        item_filters: ['release=jammy', 'arch~(x86_64|amd64)', 'ftype~(disk1.img|disk.img)']}]
  octavia-diskimage-retrofit:
    charm: ch:octavia-diskimage-retrofit
    channel: yoga/stable
EOF

cat > overlay-designate.yaml <<EOF
applications:
  neutron-api:
    options:
      reverse-dns-lookup: true
      ipv4-ptr-zone-prefix-size: 24
  designate:
    charm: ch:designate
    channel: yoga/stable
    num_units: 1
    options:
      openstack-origin: "$openstack_origin"
      nameservers: 'ns1.admin.openstack.example.com.'
    to:
    - lxd:1
  designate-mysql-router:
    charm: ch:mysql-router
    channel: 8.0/stable
  designate-bind:
    charm: ch:designate-bind
    channel: yoga/stable
    num_units: 1
    options:
      allowed_nets: '10.0.0.0/8;172.16.0.0/12;192.168.0.0/16'
    to:
    - lxd:2
  memcached:
    charm: ch:memcached
    num_units: 1
    to:
    - lxd:2

relations:
- - designate:shared-db
  - designate-mysql-router:shared-db
- - designate-mysql-router:db-router
  - mysql-innodb-cluster:db-router
- - designate:dnsaas
  - neutron-api:external-dns
- - keystone:identity-service
  - designate:identity-service
- - rabbitmq-server:amqp
  - designate:amqp
- - designate:dns-backend
  - designate-bind:dns-backend
- - memcached:cache
  - designate:coordinator-memcached
- - designate:certificates
  - vault:certificates
EOF

juju add-model openstack

# FIXME: LP: #2030280
juju model-config num-container-provision-workers=1

# LP: #2039156
juju deploy -m controller juju-dashboard --to 0 --base ubuntu@22.04  # LP: #2054375
juju integrate -m controller controller:dashboard juju-dashboard:controller

juju deploy ./bundle.yaml \
    --overlay ./overlay-options.yaml \
    --overlay ./loadbalancer-octavia.yaml \
    --overlay ./overlay-octavia-options.yaml \
    --overlay ./overlay-designate.yaml

# restarting mysql during tls enablement can cause db_init failures
# LP: #1984048
juju remove-relation vault:certificates mysql-innodb-cluster:certificates

time juju-wait -w --max_wait 5400 \
    --exclude vault \
    --exclude neutron-api-plugin-ovn \
    --exclude ovn-central \
    --exclude ovn-chassis \
    --exclude octavia \
    --exclude octavia-ovn-chassis \
    --exclude barbican-vault

# LP: #1948621, LP: #1874059, barbican-vault gets stuck sometimes
juju remove-relation vault:secrets barbican-vault:secrets-storage

VAULT_ADDR="http://$(juju exec --unit vault/leader -- network-get certificates --ingress-address):8200"
export VAULT_ADDR

vault_init_output="$(vault operator init -key-shares=1 -key-threshold=1 -format json)"
vault operator unseal -format json "$(echo "$vault_init_output" | jq -r .unseal_keys_b64[])"

VAULT_TOKEN="$(echo "$vault_init_output" | jq -r .root_token)"
export VAULT_TOKEN

juju run --format=yaml vault/leader --wait=10m authorize-charm \
    token="$(vault token create -ttl=10m -format json | jq -r .auth.client_token)"
juju run --format=yaml vault/leader --wait=10m generate-root-ca
time juju-wait -w --max_wait 1800 \
    --exclude octavia \
    --exclude barbican-vault
juju integrate vault:secrets barbican-vault:secrets-storage

# sync images
time juju run --format=yaml glance-simplestreams-sync/leader --wait=30m sync-images

# make sure the model is settled before running octavia's
# configure-resources to avoid:
# running setup_hm_port on juju-2eb009-2-lxd-3.maas
# Neutron API not available yet, deferring port discovery. ("('neutron',
# 'ports', InternalServerError())")
# LP: #1984192
time juju-wait -w --max_wait 1800 \
    --exclude octavia
juju scp ~/.ssh/id_ed25519* octavia/leader:
time juju run --format=yaml octavia/leader --wait=20m configure-resources
time juju run --format=yaml octavia-diskimage-retrofit/leader --wait=30m retrofit-image

# be nice to my SSD
juju model-config update-status-hook-interval=24h

# setup openstack

set +u
# LP: #1995971
sed -i 's/juju run /juju exec /' openrc*
# shellcheck disable=SC1091
. openrc
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
cat ~/.ssh/id_ed25519.pub | openstack keypair create --public-key /dev/stdin mykey

openstack zone create \
    --email dns-admin@openstack.example.com \
    admin.openstack.example.com.

openstack recordset create \
    admin.openstack.example.com. \
    --type A \
    --record "$(juju exec --unit designate-bind/leader -- network-get dns-backend --ingress-address)" \
    ns1

openstack zone create \
    --email dns-admin@openstack.example.com \
    admin-tenant.openstack.example.com.

openstack network set \
    --dns-domain admin-tenant.openstack.example.com. \
    internal

#openstack security group rule create \
#    --protocol icmp \
#    "$(openstack security group list --project admin --project-domain admin_domain -f value -c ID)"
#
#openstack security group rule create \
#    --protocol tcp --dst-port 22 \
#    "$(openstack security group list --project admin --project-domain admin_domain -f value -c ID)"
#
#openstack server create \
#    --flavor m1.custom \
#    --image-property os_version=20.04 \
#    --network internal \
#    --key-name mykey \
#    --wait \
#    my-instance1
#
#openstack floating ip create \
#    --port "$(openstack port list --server my-instance1 -f value -c ID)" \
#    ext_net

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

juju model-defaults --region "openstack/${OS_REGION_NAME}" \
    test-mode=true \
    logging-config='<root>=INFO;unit=DEBUG' \
    apt-http-proxy='http://192.168.151.1:8000/' \
    network="$(openstack network show internal -f value -c id)"
    # network: to exclude lb-mgmt-net which is visible from the admin tenant

juju add-model k8s-on-openstack "openstack/${OS_REGION_NAME}"
juju set-model-constraints allocate-public-ip=true # LP: #1947555

juju download --no-progress kubernetes-core - | tee kubernetes-core.bundle >/dev/null
eatmydata apt-get install -y unzip
unzip -p kubernetes-core.bundle bundle.yaml > k8s_bundle.yaml

# LP: #1919296
sed -i.bak -e 's/lxd:0/0/' k8s_bundle.yaml

# https://github.com/charmed-kubernetes/bundle/blob/master/overlays/openstack-lb-overlay.yaml
cat > openstack-lb-overlay.yaml <<EOF
machines:
  '0':
    constraints: cores=2 mem=4G root-disk=16G  # mem=8G originally
  '1':
    constraints: cores=2 mem=4G root-disk=16G
applications:
  kubeapi-load-balancer: null                            # excludes the kubeapi-load-balancer
  kubernetes-control-plane:
    constraints: cores=2 mem=4G root-disk=16G
    options:
      allow-privileged: "true"
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
  openstack-cloud-controller:
    charm: openstack-cloud-controller
  cinder-csi:
    charm: cinder-csi
relations:
  - [openstack-cloud-controller:certificates,            easyrsa:client]
  - [openstack-cloud-controller:kube-control,            kubernetes-control-plane:kube-control]
  - [openstack-cloud-controller:external-cloud-provider, kubernetes-control-plane:external-cloud-provider]
  - [openstack-cloud-controller:openstack,               openstack-integrator:clients]
  - [easyrsa:client,                                     cinder-csi:certificates]
  - [kubernetes-control-plane:kube-control,              cinder-csi:kube-control]
  - [openstack-integrator:clients,                       cinder-csi:openstack]
  # https://github.com/charmed-kubernetes/bundle/pull/895
  - [kubernetes-control-plane:loadbalancer-external,     openstack-integrator:lb-consumers]
EOF

juju deploy --trust ./k8s_bundle.yaml \
    --overlay ./openstack-lb-overlay.yaml

snap install kubectl --classic

time juju-wait -w --max_wait 3600

mkdir ~ubuntu/.kube/
juju exec --unit kubernetes-control-plane/leader 'cat ~ubuntu/config' | tee ~ubuntu/.kube/config

juju run --format=yaml kubernetes-worker/leader --wait=30m microbot replicas=3

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

kubectl --kubeconfig ~ubuntu/.kube/config wait deployment --all --for condition=Available=True --timeout=15m
kubectl --kubeconfig ~ubuntu/.kube/config get -o wide all

juju switch openstack
juju models
