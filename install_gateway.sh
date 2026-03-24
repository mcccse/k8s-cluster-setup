#!/usr/bin/env bash
# install_gateway.sh — skapar shared Gateway (HTTP, ingen TLS)
# Steg 1 av 2: verifiera att Gateway och routing fungerar innan TLS läggs till
set -euo pipefail

# ============================================================
# Konfiguration
# ============================================================
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-gateway}"
GATEWAY_NAME="${GATEWAY_NAME:-shared-gateway}"
# ============================================================

usage() {
  echo "Användning: $0"
  echo ""
  echo "Miljövariabler:"
  echo "  GATEWAY_NAMESPACE   Namespace för Gateway   (default: gateway)"
  echo "  GATEWAY_NAME        Namn på shared Gateway  (default: shared-gateway)"
  echo ""
  echo "Exempel:"
  echo "  $0"
  echo "  GATEWAY_NAME=my-gateway $0"
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

# ============================================================
# Preflight checks
# ============================================================
if kubectl config current-context | grep -q "kind-"; then
  echo "⚠️  Du verkar stå i ett kind-kluster (management). Byt till workload-klustret:"
  echo "   export KUBECONFIG=talos-config/\${CLUSTER_NAME}/kubeconfig"
  exit 1
fi

if ! command -v kubectl &>/dev/null; then
  echo "❌ kubectl not found."
  exit 1
fi

CONTEXT=$(kubectl config current-context 2>/dev/null || true)
if [[ -z "${CONTEXT}" ]]; then
  echo "❌ No active kubectl context found."
  exit 1
fi

if ! kubectl get gatewayclass cilium &>/dev/null 2>&1; then
  echo "❌ GatewayClass 'cilium' hittades inte."
  echo "   Kör install_cilium.sh innan install_gateway.sh."
  exit 1
fi

echo "🔧 Konfiguration:"
echo "   Context:            ${CONTEXT}"
echo "   Gateway namespace:  ${GATEWAY_NAMESPACE}"
echo "   Gateway namn:       ${GATEWAY_NAME}"
echo ""

read -r -p "Continue? (y/N) " confirm
[[ "${confirm}" =~ ^[yY]$ ]] || {
  echo "Aborted."
  exit 0
}

# ============================================================
# Skapa namespace och Gateway
# ============================================================
echo ""
echo "🚪 Skapar namespace ${GATEWAY_NAMESPACE}..."
kubectl create namespace "${GATEWAY_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "🚪 Skapar shared Gateway (HTTP)..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${GATEWAY_NAMESPACE}
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
EOF

kubectl rollout restart deployment/hcloud-cloud-controller-manager -n hccm-system

echo ""
echo "✅ Gateway skapad!"
echo ""
echo "   Hetzner LB kan ta 1-2 minuter att få en IP. Bevaka med:"
echo "   kubectl get gateway ${GATEWAY_NAME} -n ${GATEWAY_NAMESPACE} -w"
echo ""
echo "   Hämta IP när den är klar:"
echo "   kubectl get gateway ${GATEWAY_NAME} -n ${GATEWAY_NAMESPACE} \\"
echo "     -o jsonpath='{.status.addresses[0].value}'"
echo ""
echo "   Testa med en HTTPRoute:"
echo ""
echo "   kubectl apply -f - <<'ROUTE'"
echo "   apiVersion: gateway.networking.k8s.io/v1"
echo "   kind: HTTPRoute"
echo "   metadata:"
echo "     name: min-app"
echo "     namespace: min-app-namespace"
echo "   spec:"
echo "     parentRefs:"
echo "       - name: ${GATEWAY_NAME}"
echo "         namespace: ${GATEWAY_NAMESPACE}"
echo "     hostnames:"
echo "       - min-app.example.com"
echo "     rules:"
echo "       - backendRefs:"
echo "           - name: min-app-service"
echo "             port: 8080"
echo "   ROUTE"
echo ""
echo "   När HTTP fungerar, lägg till TLS med:"
echo "   ./install_gateway_tls.sh"
