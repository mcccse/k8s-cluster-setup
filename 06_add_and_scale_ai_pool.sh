#!/usr/bin/env bash

POOL=ai MACHINE_TYPE=ccx33 REPLICAS=0 ./pools/poolctl.sh apply &&
  POOL=ai REPLICAS=1 ./pools/poolctl.sh scale

# Ensure CCM is installed on the workload cluster and providerID is patched on new nodes
OLD_KUBECONFIG="${KUBECONFIG:-}"
export KUBECONFIG="talos-config/${CLUSTER_NAME}/kubeconfig"
printf 'y\n' | ./install_hccm.sh
export KUBECONFIG="${OLD_KUBECONFIG}"

# Force providerID on pool nodes to match HCloudMachine (handles wrong/non-empty providerIDs too)
MGMT_KUBECONFIG="${OLD_KUBECONFIG}"
WORKLOAD_KUBECONFIG="talos-config/${CLUSTER_NAME}/kubeconfig"
mapfile -t HCMS < <(KUBECONFIG="${MGMT_KUBECONFIG}" kubectl -n default get hcloudmachine \
  -l "cluster.x-k8s.io/deployment-name=${CLUSTER_NAME}-workers-ai" -o json |
  jq -r '.items[] | select(.status.providerID!=null and .status.providerID!="") | "\(.metadata.name) \(.status.providerID)"')
for line in "${HCMS[@]}"; do
  name="${line%% *}"
  pid="${line#* }"
  if KUBECONFIG="${WORKLOAD_KUBECONFIG}" kubectl get node "$name" >/dev/null 2>&1; then
    curr=$(KUBECONFIG="${WORKLOAD_KUBECONFIG}" kubectl get node "$name" -o jsonpath='{.spec.providerID}' || true)
    if [[ "${curr}" != "${pid}" ]]; then
      KUBECONFIG="${WORKLOAD_KUBECONFIG}" kubectl patch node "$name" --type=merge -p "{\"spec\":{\"providerID\":\"${pid}\"}}"
    fi
  fi
done

sleep 5
clusterctl describe cluster demo -n default | grep "${CLUSTER_NAME}-workers-ai"
