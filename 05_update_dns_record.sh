#!/usr/bin/env bash

# My setup is using octodns
# this automates the insert/update

DNS_DIR="../infra/dns"
PUBLIC_LB=$(kubectl get gateway shared-gateway -n gateway --no-headers | awk '{print $3}')

bash "${DNS_DIR}/dns-upsert-a.sh" \
  --zone "${CLUSTER_NAME}" \
  --name "*.${CLUSTER_NAME}" \
  --file "config/${DNS_ZONE}.yaml" \
  --ip "${PUBLIC_LB}"
