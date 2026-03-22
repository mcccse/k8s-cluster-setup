#!/usr/bin/env bash
# get_credentials.sh — hämtar talosconfig och kubeconfig från Kubernetes efter att klustret är uppe
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-capi-hetzner}"
NAMESPACE="${NAMESPACE:-default}"
OUTPUT_DIR="${OUTPUT_DIR:-talos-config/${CLUSTER_NAME}}"

usage() {
  echo "Användning: $0"
  echo ""
  echo "Miljövariabler:"
  echo "  CLUSTER_NAME   Klusternamn   (default: capi-hetzner)"
  echo "  NAMESPACE      Namespace     (default: default)"
  echo "  OUTPUT_DIR     Utdatakatalog (default: talos-config/<klusternamn>)"
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

mkdir -p "${OUTPUT_DIR}"

echo "🔑 Hämtar talosconfig för ${CLUSTER_NAME}..."
kubectl get secret "${CLUSTER_NAME}-talosconfig" \
  -n "${NAMESPACE}" \
  -o jsonpath='{.data.talosconfig}' | base64 -d \
  >"${OUTPUT_DIR}/talosconfig"
echo "   ✅ Sparad: ${OUTPUT_DIR}/talosconfig"

echo "📋 Hämtar kubeconfig för ${CLUSTER_NAME}..."
clusterctl get kubeconfig "${CLUSTER_NAME}" \
  -n "${NAMESPACE}" \
  >"${OUTPUT_DIR}/kubeconfig"
echo "   ✅ Sparad: ${OUTPUT_DIR}/kubeconfig"

echo ""
echo "Använd klustret med:"
echo "   export KUBECONFIG=${OUTPUT_DIR}/kubeconfig"
echo "   kubectl get nodes"
echo ""
echo "Använd talosctl med:"
echo "   export TALOSCONFIG=${OUTPUT_DIR}/talosconfig"
echo "   talosctl get members"
