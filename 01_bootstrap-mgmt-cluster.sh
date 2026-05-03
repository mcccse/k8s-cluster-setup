#!/usr/bin/env bash

MGMT_CLUSTER="${MGMT_CLUSTER:-mgmt}"

kind create cluster --name "${MGMT_CLUSTER}" &&
  clusterctl init \
    --core cluster-api \
    --infrastructure hetzner \
    --bootstrap talos \
    --control-plane talos &&
  kubectl create secret generic hetzner \
    --from-literal=hcloud="${HCLOUD_TOKEN}" \
    --from-literal=hcloud-ssh-key-name="${SSH_KEY_NAME}" \
    --from-literal=hcloudSSHKey="${SSH_KEY_NAME}" \
    -n default \
    --dry-run=client -o yaml | kubectl apply -f - &&
  kubectl patch secret hetzner \
    -n default \
    -p '{"metadata":{"labels":{"clusterctl.cluster.x-k8s.io/move":""}}}'
