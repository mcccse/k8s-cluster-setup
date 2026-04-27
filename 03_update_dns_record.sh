#!/usr/bin/env bash

# My setup is using octodns
# this automates the insert/update

DNS_DIR="../infra/dns"
KUBEAPI_LB=$(hcloud load-balancer list | grep "${CLUSTER_NAME}" | awk '{print $4}')

bash "${DNS_DIR}/dns-upsert-a.sh" \
  --zone "${CLUSTER_NAME}" \
  --name "kubeapi.${CLUSTER_NAME}" \
  --file "config/${DNS_ZONE}.yaml" \
  --ip "${KUBEAPI_LB}"
