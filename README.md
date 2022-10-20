## rough estimated time

- maas: 15m
- openstack: 40m
- kubernetes: 18m

## prepare a bare metal instance

If you don't have any physical machine with 64GB of memory or more,
launch a baremetal instance with Ubuntu 20.04 LTS.

If you get "Your account is currently being verified", have a cup of
coffee.

```
Your account is currently being verified. Verification normally
takes less than 2 hours. Until your account is verified, you may not be
able to launch additional instances or create additional volumes. If you
are still receiving this message after more than 2 hours, please let us
know by writing to aws-verification@amazon.com. We appreciate your
patience.
```

## prepare ssh_config on your local machine

Write `~/.ssh/config`.

```
Host demo-maas
    Hostname 10.0.9.10
    User ubuntu
    ProxyJump demo-baremetal
    # IdentityFile /PATH/TO/YOUR/KEY

Host demo-baremetal
    Hostname <GLOBAL_IP_ADDRESS_OF_THE_INSTANCE>
    User ubuntu
    # IdentityFile /PATH/TO/YOUR/KEY
```

Then, SSH to the instance and import keys.

``` bash
[local] $ ssh demo-baremetal

[baremetal] $ ssh-import-id <Launchpad accounts>
```

## enable nested KVM

Enable it.

```bash
[baremetal] $ sudo rmmod kvm_intel

$ cat <<EOF | sudo tee /etc/modprobe.d/nested-kvm-intel.conf
options kvm_intel nested=1
EOF

$ sudo modprobe kvm_intel
```

Verify if it returns "Y".

```bash
$ cat /sys/module/kvm_intel/parameters/nested
-> Y
```


## prepare a LXD container to have a clean MAAS environment

Setup LXD on the bare metal to have a clean MAAS environment to be
confined in a container so you can reset the MAAS env without respawning
the bare metal instance.

```bash
[baremetal] $ cat <<EOF | sudo lxd init --preseed
config: {}
networks:
- config:
    ipv4.address: 10.0.9.1/24
    ipv4.nat: "true"
    ipv4.dhcp.ranges: 10.0.9.51-10.0.9.200
    ipv6.address: none
  description: ""
  name: lxdbr0
  type: ""
storage_pools:
- config: {}
  description: ""
  name: default
  driver: dir
profiles:
- config: {}
  description: ""
  devices:
    eth0:
      name: eth0
      network: lxdbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
cluster: null
EOF
```

## clone the repository

```bash
[baremetal] $ git clone https://github.com/nobuto-m/quick-maas.git
$ cd quick-maas
```


## run

Run the script to create the "quick-maas" LXD container to run MAAS and
MAAS Pod inside it. OpenStack, Kubernetes on top of OpenStack, and sample workload on top of Kubernetes will be deployed as a part of it.

```bash
[baremetal] $ ./run.sh
```


### how to access

SSH.

```bash
[local] $ ssh demo-maas
```

Open sshuttle for web browser.

```bash
[local] $ sshuttle -r demo-maas -N
```


## how to destroy the environment and rebuild

```bash
[baremetal] $ lxc delete --force quick-maas
[baremetal] $ ./run.sh
```
