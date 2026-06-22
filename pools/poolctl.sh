#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true

# Required env (export once to match your cluster)
: "${CLUSTER_NAME:?set CLUSTER_NAME}"
: "${KUBERNETES_VERSION:=v1.35.0}"
: "${TALOS_VERSION:=v1.12.4}"
: "${TALOS_IMAGE_NAME:=talos-v1.12.4}"
: "${SSH_KEY_NAME:=hcloudSSHKey}"
: "${NAMESPACE:=default}"

POOL="${POOL:-}"
MACHINE_TYPE="${MACHINE_TYPE:-}"
REPLICAS="${REPLICAS:-1}"
TAINTED="${TAINTED:-false}"

export CLUSTER_NAME KUBERNETES_VERSION TALOS_VERSION TALOS_IMAGE_NAME SSH_KEY_NAME NAMESPACE POOL MACHINE_TYPE REPLICAS TAINTED

tmpl_general="$(dirname "$0")/workers-general.tmpl.yaml"
tmpl_tainted="$(dirname "$0")/workers-tainted.tmpl.yaml"

case "${cmd}" in
render)
  [[ -n "${POOL}" && -n "${MACHINE_TYPE}" ]] || {
    echo "set POOL and MACHINE_TYPE"
    exit 1
  }
  if [[ "${TAINTED}" == "true" ]]; then
    envsubst <"${tmpl_tainted}"
  else
    envsubst <"${tmpl_general}"
  fi
  ;;
apply)
  [[ -n "${POOL}" && -n "${MACHINE_TYPE}" ]] || {
    echo "set POOL and MACHINE_TYPE"
    exit 1
  }
  if [[ "${TAINTED}" == "true" ]]; then
    envsubst <"${tmpl_tainted}" | kubectl apply -f -
  else
    envsubst <"${tmpl_general}" | kubectl apply -f -
  fi
  ;;
delete)
  [[ -n "${POOL}" ]] || {
    echo "set POOL"
    exit 1
  }
  kubectl delete machinedeployment "${CLUSTER_NAME}-workers-${POOL}" -n "${NAMESPACE}" --ignore-not-found
  kubectl delete talosconfigtemplate "${CLUSTER_NAME}-workers-${POOL}-tct" -n "${NAMESPACE}" --ignore-not-found
  kubectl delete hcloudmachinetemplate "${CLUSTER_NAME}-workers-${POOL}-mt" -n "${NAMESPACE}" --ignore-not-found
  ;;
scale)
  [[ -n "${POOL}" ]] || {
    echo "set POOL"
    exit 1
  }
  kubectl -n "${NAMESPACE}" scale machinedeployment "${CLUSTER_NAME}-workers-${POOL}" --replicas="${REPLICAS}"
  ;;
*)
  echo "Usage:"
  echo "  POOL=general MACHINE_TYPE=cpx31 REPLICAS=2 ./poolctl.sh apply"
  echo "  POOL=compute MACHINE_TYPE=ccx33 REPLICAS=0 TAINTED=true ./poolctl.sh apply"
  echo "  POOL=storage MACHINE_TYPE=cpx51 REPLICAS=0 TAINTED=true ./poolctl.sh apply"
  echo "  POOL=compute REPLICAS=3 ./poolctl.sh scale"
  echo "  POOL=compute ./poolctl.sh delete"
  exit 1
  ;;
esac
