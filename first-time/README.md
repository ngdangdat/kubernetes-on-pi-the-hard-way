
# Table of Contents

1.  [Notes](#orga1dca2f)
2.  [Initial hardware setup](#org0d37567)
3.  [Outline](#org46b3011)
4.  [Download and extract binaries](#orgbc24bd5)
5.  [Organize to-be-used computer resources](#org54731c4)
6.  [Setup Certificate Authority (CA) certificates](#org0265d28)
    1.  [Distribute keys](#org12c3077)
7.  [Generate `kubeconfig` file for authentication](#org6201f99)
    1.  [kubelet](#org43426b9)
    2.  [kube-controller-manager](#org3f9f705)
    3.  [kube-scheduler](#org8736c20)
    4.  [`admin` user](#org6214021)
    5.  [Distribute authentication config files](#org664c322)
8.  [Generating the Data Encryption Config and Key](#org765144d)
9.  [Bootstrap etcd cluster](#org3067510)
10. [Bootstrap the Kubernetes Control Plane](#orga500a3e)
    1.  [Prerequisites](#orgb79ac8f)
    2.  [Provision Control Plane](#orgc137b2b)
        1.  [Kube Controller Binaries](#orgba9bfd6)
        2.  [Configure API server](#org2caa98e)
        3.  [`kube-apiserver.service` unit file](#orgf475d59)
        4.  [Configure Kubernetes Controller Manager](#orgbb95406)
        5.  [Configure Kubernetes Scheduler](#org31e0889)
        6.  [Start controller services](#org83b80b2)
    3.  [RBAC for kubelet authorization](#orgd81e901)
    4.  [Verification from the operation machine](#org672a665)
11. [Bootstrap Worker Nodes](#org848240f)
    1.  [Prerequisites](#org50e38c4)
    2.  [Setup on each node](#org3b0dde6)
    3.  [Configure CNI networking](#org09340de)
    4.  [Configure `containerd`](#orga4be877)
    5.  [Configure `kubelet`](#org12b7067)
    6.  [Start services](#org0df204f)



<a id="orga1dca2f"></a>

# Notes

Based on: [Kubernetes The Hard Way by kelseyhightower](https://github.com/kelseyhightower/kubernetes-the-hard-way)
Changes

-   Remove kube-proxy, use Cillium instead

Other references

-   [Check `cgroup` version](https://unix.stackexchange.com/questions/471476/how-do-i-check-cgroup-v2-is-installed-on-my-machine)


<a id="org0d37567"></a>

# Initial hardware setup

-   01 x server node: Orange Pi Zero 3
    -   server: 4 CPU 2 GiB memory
-   02 x worker node: Raspberry Pi 4B
    -   node-0: 4 CPU 8GiB memory
    -   node-1: 4 CPU 4GiB memory


<a id="org46b3011"></a>

# Outline

-   Download binaries to
    -   downloads
        -   arm64
        -   amd64
-   Use symlink to setup for each node


<a id="orgbc24bd5"></a>

# Download and extract binaries

Download

    for ARCH in arm64 amd64;
    do
        mkdir -p downloads/${ARCH}
        wget -q --show-progress \
             --https-only \
             --timestamping \
             -P downloads/${ARCH} \
             -i downloads.${ARCH}.txt
    done

Extract, put into places and make executable

    for ARCH in amd64 arm64;
    do
        mkdir -p downloads/${ARCH}/{client,cni-plugins,controller,worker}
        tar -xvf downloads/${ARCH}/crictl-v1.33.0-linux-${ARCH}.tar.gz \
            -C downloads/${ARCH}/worker/
        tar -xvf downloads/${ARCH}/containerd-2.1.0-rc.0-linux-${ARCH}.tar.gz \
            --strip-components 1 \
            -C downloads/${ARCH}/worker/
        tar -xvf downloads/${ARCH}/cni-plugins-linux-${ARCH}-v1.7.1.tgz \
            -C downloads/${ARCH}/cni-plugins/
        tar -xvf downloads/${ARCH}/etcd-v3.6.0-rc.4-linux-${ARCH}.tar.gz \
            -C downloads/${ARCH}/ \
            --strip-components 1 \
            etcd-v3.6.0-rc.4-linux-${ARCH}/etcdctl \
            etcd-v3.6.0-rc.4-linux-${ARCH}/etcd
        mv downloads/${ARCH}/{etcdctl,kubectl} downloads/${ARCH}/client/
        mv downloads/${ARCH}/{etcd,kube-apiserver,kube-controller-manager,kube-scheduler} \
           downloads/${ARCH}/controller/
        mv downloads/${ARCH}/kubelet downloads/${ARCH}/worker/
        mv downloads/${ARCH}/runc.${ARCH} downloads/${ARCH}/worker/runc
        chmod +x downloads/${ARCH}/worker/{kubelet,runc}
        chmod +x downloads/${ARCH}/client/kubectl
        chmod +x downloads/${ARCH}/controller/kube-{apiserver,controller-manager,scheduler}
    done


<a id="org54731c4"></a>

# Organize to-be-used computer resources

Setup SSH, hostname

    cp machines.txt{.template,}
    # example
    # 192.168.68.106 server.kubernetes.local server
    # 192.168.68.111 node-0.kubernetes.local node-0 10.200.0.0/24
    # 192.168.68.112 node-1.kubernetes.local node-1 10.200.1.0/24
    
    ln -s $(pwd)/secrets/sshkey /home/ndd/.ssh/homelab
    
    while read IP FQDN HOST SUBNET; do
        CMD="sed -i 's/^127.0.1.1.*/127.0.1.1\t${FQDN} ${HOST}/' /etc/hosts"
        ssh -i secrets/sshkey -n root@${IP} "$CMD"
        ssh -i secrets/sshkey -n root@${IP} hostnamectl set-hostname ${HOST}
        ssh -i secrets/sshkey -n root@${IP} systemctl restart systemd-hostnamed
    done < machines.txt
    
    # verify
    while read IP FQDN HOST SUBNET; do
        ssh -i secrets/sshkey -n root@${IP} hostname --fqdn
    done < machines.txt
    # output
    server.kubernetes.local
    node-0.kubernetes.local
    node-1.kubernetes.local

Setup `/etc/hosts` file

    echo "# Homelab" > hosts
    while read IP FQDN HOST SUBNET; do
        ENTRY="${IP} ${FQDN} ${HOST}"
        echo $ENTRY >> hosts
    done < machines.txt
    # optional
    cat hosts >> /etc/hosts

Verify

    for host in server node-0 node-1
    do ssh -i secrets/sshkey root@${host} hostname
    done

Add host file to remote machines

    while read IP FQDN HOST SUBNET; do
        scp -i secrets/sshkey hosts root@${HOST}:~/
        ssh -i secrets/sshkey -n \
            root@${HOST} "cat hosts >> /etc/hosts && rm hosts"
    done < machines.txt


<a id="org0265d28"></a>

# Setup Certificate Authority (CA) certificates

Check `ca.conf` file and adjust for your setup (remove kube-proxy section)

    mkdir -p secrets/certs
    ln -s $(pwd)/ca.conf $(pwd)/secrets/certs/ca.conf
    openssl genrsa -out secrets/certs/ca.key 4096
    openssl req -x509 -new -sha512 -noenc \
            -key secrets/certs/ca.key -days 3653 \
            -config secrets/certs/ca.conf \
            -out secrets/certs/ca.crt
    # output
    ls -lah secrets/certs
    total 20K
    drwxr-xr-x. 2 ndd ndd 4.0K May  2 18:45 .
    drwxr-xr-x. 3 ndd ndd 4.0K May  2 18:45 ..
    lrwxrwxrwx. 1 ndd ndd   67 May  2 18:45 ca.conf -> /home/ndd/station/k8s-homelab/kubernetes-on-pi-the-hard-way/ca.conf
    -rw-r--r--. 1 ndd ndd 1.9K May  2 18:45 ca.crt
    -rw-------. 1 ndd ndd 3.2K May  2 18:45 ca.key

Create components certificates and private keys

    certs=(
        "admin" "node-0" "node-1"
        "kube-scheduler"
        "kube-controller-manager"
        "kube-api-server"
        "service-accounts"
    )
    CERTDIR=secrets/certs
    for i in ${certs[*]}; do
        openssl genrsa -out "${CERTDIR}/${i}.key" 4096
    
        openssl req -new -key "${CERTDIR}/${i}.key" -sha256 \
                -config "${CERTDIR}/ca.conf" -section ${i} \
                -out "${CERTDIR}/${i}.csr"
    
        openssl x509 -req -days 3653 -in "${CERTDIR}/${i}.csr" \
                -copy_extensions copyall \
                -sha256 -CA "${CERTDIR}/ca.crt" \
                -CAkey "${CERTDIR}/ca.key" \
                -CAcreateserial \
                -out "${CERTDIR}/${i}.crt"
    done

Check

    ls -1 secrets/certs
    admin.crt
    admin.csr
    admin.key
    ca.conf
    ca.crt
    ca.key
    ca.srl
    kube-api-server.crt
    kube-api-server.csr
    kube-api-server.key
    kube-controller-manager.crt
    kube-controller-manager.csr
    kube-controller-manager.key
    kube-scheduler.crt
    kube-scheduler.csr
    kube-scheduler.key
    node-0.crt
    node-0.csr
    node-0.key
    node-1.crt
    node-1.csr
    node-1.key
    service-accounts.crt
    service-accounts.csr
    service-accounts.key


<a id="org12c3077"></a>

## Distribute keys

Worker nodes

    for host in node-0 node-1; do
        ssh -i secrets/sshkey root@${host} mkdir /var/lib/kubelet/
    
        scp -i secrets/sshkey secrets/certs/ca.crt root@${host}:/var/lib/kubelet/
    
        scp -i secrets/sshkey secrets/certs/${host}.crt \
            root@${host}:/var/lib/kubelet/kubelet.crt
    
        scp -i secrets/sshkey secrets/certs/${host}.key \
            root@${host}:/var/lib/kubelet/kubelet.key
    done

Server node

    scp -i secrets/sshkey \
        secrets/certs/ca.key secrets/certs/ca.crt \
        secrets/certs/kube-api-server.key secrets/certs/kube-api-server.crt \
        secrets/certs/service-accounts.key secrets/certs/service-accounts.crt \
        root@server:~/


<a id="org6201f99"></a>

# Generate `kubeconfig` file for authentication

    AUTHDIR="secrets/kubernetes-auth"
    mkdir -p ${AUTHDIR}

**Note**: kube-proxy is skipped


<a id="org43426b9"></a>

## kubelet

    CERTDIR="secrets/certs"
    AUTHDIR="secrets/kubernetes-auth"
    for host in node-0 node-1; do
        kubectl config set-cluster homelab \
                --certificate-authority=${CERTDIR}/ca.crt \
                --embed-certs=true \
                --server=https://server.kubernetes.local:6443 \
                --kubeconfig=${AUTHDIR}/${host}.kubeconfig
    
        kubectl config set-credentials system:node:${host} \
                --client-certificate=${CERTDIR}/${host}.crt \
                --client-key=${CERTDIR}/${host}.key \
                --embed-certs=true \
                --kubeconfig=${AUTHDIR}/${host}.kubeconfig
    
        kubectl config set-context default \
                --cluster=homelab \
                --user=system:node:${host} \
                --kubeconfig=${AUTHDIR}/${host}.kubeconfig
    
        kubectl config use-context default \
                --kubeconfig=${AUTHDIR}/${host}.kubeconfig
    done


<a id="org3f9f705"></a>

## kube-controller-manager

    CERTDIR="secrets/certs"
    AUTHDIR="secrets/kubernetes-auth"
    kubectl config set-cluster homelab \
              --certificate-authority=${CERTDIR}/ca.crt \
              --embed-certs=true \
              --server=https://server.kubernetes.local:6443 \
              --kubeconfig=${AUTHDIR}/kube-controller-manager.kubeconfig
    
      kubectl config set-credentials system:kube-controller-manager \
              --client-certificate=${CERTDIR}/kube-controller-manager.crt \
              --client-key=${CERTDIR}/kube-controller-manager.key \
              --embed-certs=true \
              --kubeconfig=${AUTHDIR}/kube-controller-manager.kubeconfig
    
      kubectl config set-context default \
              --cluster=homelab \
              --user=system:kube-controller-manager \
              --kubeconfig=${AUTHDIR}/kube-controller-manager.kubeconfig
    
      kubectl config use-context default \
              --kubeconfig=${AUTHDIR}/kube-controller-manager.kubeconfig


<a id="org8736c20"></a>

## kube-scheduler

    CERTDIR="secrets/certs"
    AUTHDIR="secrets/kubernetes-auth"
    kubectl config set-cluster homelab \
              --certificate-authority=${CERTDIR}/ca.crt \
              --embed-certs=true \
              --server=https://server.kubernetes.local:6443 \
              --kubeconfig=${AUTHDIR}/kube-scheduler.kubeconfig
    
      kubectl config set-credentials system:kube-scheduler \
              --client-certificate=${CERTDIR}/kube-scheduler.crt \
              --client-key=${CERTDIR}/kube-scheduler.key \
              --embed-certs=true \
              --kubeconfig=${AUTHDIR}/kube-scheduler.kubeconfig
    
      kubectl config set-context default \
              --cluster=homelab \
              --user=system:kube-scheduler \
              --kubeconfig=${AUTHDIR}/kube-scheduler.kubeconfig
    
      kubectl config use-context default \
              --kubeconfig=${AUTHDIR}/kube-scheduler.kubeconfig


<a id="org6214021"></a>

## `admin` user

    CERTDIR="secrets/certs"
    AUTHDIR="secrets/kubernetes-auth"
    kubectl config set-cluster homelab \
              --certificate-authority=${CERTDIR}/ca.crt \
              --embed-certs=true \
              --server=https://127.0.0.1:6443 \
              --kubeconfig=${AUTHDIR}/admin.kubeconfig
    
      kubectl config set-credentials admin \
              --client-certificate=${CERTDIR}/admin.crt \
              --client-key=${CERTDIR}/admin.key \
              --embed-certs=true \
              --kubeconfig=${AUTHDIR}/admin.kubeconfig
    
      kubectl config set-context default \
              --cluster=homelab \
              --user=admin \
              --kubeconfig=${AUTHDIR}/admin.kubeconfig
    
      kubectl config use-context default \
              --kubeconfig=${AUTHDIR}/admin.kubeconfig


<a id="org664c322"></a>

## Distribute authentication config files

worker nodes

    CERTDIR="secrets/certs"
    AUTHDIR="secrets/kubernetes-auth"
    for host in node-0 node-1; do
        ssh -i secrets/sshkey root@${host} "mkdir -p /var/lib/kubelet"
        scp -i secrets/sshkey ${AUTHDIR}/${host}.kubeconfig \
            root@${host}:/var/lib/kubelet/kubeconfig
    done

server node

    CERTDIR="secrets/certs"
    AUTHDIR="secrets/kubernetes-auth"
    scp -i secrets/sshkey ${AUTHDIR}/admin.kubeconfig \
          ${AUTHDIR}/kube-controller-manager.kubeconfig \
          ${AUTHDIR}/kube-scheduler.kubeconfig \
          root@server:~/


<a id="org765144d"></a>

# Generating the Data Encryption Config and Key

Generate random key

    export ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

Replace key

    envsubst < configs-templates/encryption-config.yaml > configs/encryption-config.yaml

Copy config file

    scp -i secrets/sshkey configs/encryption-config.yaml root@server:~/


<a id="org3067510"></a>

# Bootstrap etcd cluster

    export ARCH="arm64"
    scp -i secrets/sshkey \
          downloads/${ARCH}/controller/etcd \
          downloads/${ARCH}/client/etcdctl \
          units/etcd.service \
          root@server:~/

Jump to server node

    ssh -i secrets/sshkey root@server

Move binaries

    mv etcd etcdctl /usr/local/bin/

Configuration

    mkdir -p /etc/etcd /var/lib/etcd
    chmod 700 /var/lib/etcd
    cp ca.crt kube-api-server.key kube-api-server.crt \
      /etc/etcd/

`systemd` service unit file

    mv etcd.service /etc/systemd/system/

Start service

    systemctl daemon-reload
    systemctl enable etcd
    systemctl start etcd


<a id="orga500a3e"></a>

# Bootstrap the Kubernetes Control Plane


<a id="orgb79ac8f"></a>

## Prerequisites

Copy

    ARCH="arm64"
    scp -i secrets/sshkey \
          downloads/${ARCH}/controller/kube-apiserver \
          downloads/${ARCH}/controller/kube-controller-manager \
          downloads/${ARCH}/controller/kube-scheduler \
          downloads/${ARCH}/client/kubectl \
          units/kube-apiserver.service \
          units/kube-controller-manager.service \
          units/kube-scheduler.service \
          configs/kube-scheduler.yaml \
          configs/kube-apiserver-to-kubelet.yaml \
          root@server:~/

Jump to server

    ssh -i secrets/sshkey root@server

Make config dir

    mkdir -p /etc/kubernetes/config


<a id="orgc137b2b"></a>

## Provision Control Plane


<a id="orgba9bfd6"></a>

### Kube Controller Binaries

Install binaries

    mv kube-apiserver \
       kube-controller-manager \
       kube-scheduler kubectl \
       /usr/local/bin/


<a id="org2caa98e"></a>

### Configure API server

    mkdir -p /var/lib/kubernetes/
    
    mv ca.crt ca.key \
       kube-api-server.key kube-api-server.crt \
       service-accounts.key service-accounts.crt \
       encryption-config.yaml \
       /var/lib/kubernetes/


<a id="orgf475d59"></a>

### `kube-apiserver.service` unit file

    mv kube-apiserver.service \
       /etc/systemd/system/kube-apiserver.service


<a id="orgbb95406"></a>

### Configure Kubernetes Controller Manager

    mv kube-controller-manager.kubeconfig /var/lib/kubernetes/
    mv kube-controller-manager.service /etc/systemd/system/


<a id="org31e0889"></a>

### Configure Kubernetes Scheduler

    mv kube-scheduler.kubeconfig /var/lib/kubernetes/
    mv kube-scheduler.yaml /etc/kubernetes/config/
    mv kube-scheduler.service /etc/systemd/system/


<a id="org83b80b2"></a>

### Start controller services

Start systemd services

    systemctl daemon-reload
    
    systemctl enable kube-apiserver \
              kube-controller-manager kube-scheduler
    
    systemctl start kube-apiserver \
              kube-controller-manager kube-scheduler

Verification 0: systemd service (server node)

    systemctl is-active kube-apiserver
    systemctl is-active kube-controller-manager
    systemctl is-active kube-scheduler

Verification 1: Cluster info dumping (server node)

    kubectl cluster-info \
            --kubeconfig admin.kubeconfig


<a id="orgd81e901"></a>

## RBAC for kubelet authorization

This is operation on server node

    ssh root@server

Apply using kubectl and `admin.kubeconfig` authentication file

    kubectl apply -f kube-apiserver-to-kubelet.yaml \
            --kubeconfig admin.kubeconfig


<a id="org672a665"></a>

## Verification from the operation machine

    curl --cacert secrets/certs/ca.crt \
         https://server.kubernetes.local:6443/version
    # output
    {
        "major": "1",
        "minor": "33",
        "emulationMajor": "1",
        "emulationMinor": "33",
        "minCompatibilityMajor": "1",
        "minCompatibilityMinor": "32",
        "gitVersion": "v1.33.0",
        "gitCommit": "60a317eadfcb839692a68eab88b2096f4d708f4f",
        "gitTreeState": "clean",
        "buildDate": "2025-04-23T13:00:14Z",
        "goVersion": "go1.24.2",
        "compiler": "gc",
        "platform": "linux/arm64"
    }


<a id="org848240f"></a>

# Bootstrap Worker Nodes


<a id="org50e38c4"></a>

## Prerequisites

Copy files

    for HOST in node-0 node-1; do
        scp -i secrets/sshkey configs/kubelet-config.yaml root@${HOST}:~/
    done

    ARCH="arm64"
    for HOST in node-0 node-1; do
        scp -i secrets/sshkey \
            downloads/${ARCH}/worker/* \
            downloads/${ARCH}/client/kubectl \
            configs/99-loopback.conf \
            configs/containerd-config.toml \
            units/containerd.service \
            units/kubelet.service \
            root@${HOST}:~/
    done

    ARCH="arm64"
    for HOST in node-0 node-1; do
        scp -i secrets/sshkey \
            downloads/${ARCH}/cni-plugins/* \
            root@${HOST}:~/cni-plugins/
    done


<a id="org3b0dde6"></a>

## Setup on each node

Jump

    HOST="node-0"
    ssh -i secrets/sshkey root@$HOST

Install modules

    apt-get update
    apt-get -y install socat conntrack ipset kmod

Disable swap for good (hard to allocate memory when swap is involved). Reference: <https://serverfault.com/questions/1093773/how-to-permanently-remove-dev-zram0-as-swap-in-armbian>

    sed -i 's/# SWAP=false/SWAP=false/g' /etc/default/armbian-zram-config
    reboot
    # verification
    swapon --show

Installation directories

    mkdir -p \
          /etc/cni/net.d \
          /opt/cni/bin \
          /var/lib/kubelet \
          /var/lib/kubernetes \
          /var/run/kubernetes

Worker binaries

    mv crictl kubelet runc \
       /usr/local/bin/
    mv containerd containerd-shim-runc-v2 containerd-stress /bin/
    mv cni-plugins/* /opt/cni/bin/


<a id="org09340de"></a>

## Configure CNI networking

Copy configuration files

    mv 99-loopback.conf /etc/cni/net.d/

Load and configure `br-netfilter` kernel module

    modprobe br-netfilter
    echo "br-netfilter" >> /etc/modules-load.d/modules.conf
    
    echo "net.bridge.bridge-nf-call-iptables = 1" \
         >> /etc/sysctl.d/kubernetes.conf
    echo "net.bridge.bridge-nf-call-ip6tables = 1" \
         >> /etc/sysctl.d/kubernetes.conf
    sysctl -p /etc/sysctl.d/kubernetes.conf


<a id="orga4be877"></a>

## Configure `containerd`

    mkdir -p /etc/containerd/
    mv containerd-config.toml /etc/containerd/config.toml
    mv containerd.service /etc/systemd/system/


<a id="org12b7067"></a>

## Configure `kubelet`

    mv kubelet-config.yaml /var/lib/kubelet/kubelet-config.yaml
    mv kubelet.service /etc/systemd/system/


<a id="org0df204f"></a>

## Start services

    systemctl daemon-reload
    systemctl enable containerd kubelet
    systemctl start containerd kubelet

