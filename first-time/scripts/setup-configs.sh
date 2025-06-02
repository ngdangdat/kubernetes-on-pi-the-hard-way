#!/bin/bash

set -eux

### CONFIGURATIONS
# replace key
export ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
envsubst < configs-templates/encryption-config.yaml \
         > configs/encryption-config.yaml

cp \
    configs-templates/{kube-scheduler.yaml,kube-apiserver-to-kubelet.yaml} \
    configs-templates/{kubelet-config.yaml \
    configs-templates/99-loopback.conf \
    configs
