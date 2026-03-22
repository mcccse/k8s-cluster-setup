#!/usr/bin/env bash
# install_cilium.sh — installerar Cilium via Helm (Talos-optimerat)
set -euo pipefail

# ============================================================
# Konfiguration — ändra dessa variabler
# ============================================================
CILIUM_VERSION="${CILIUM_VERSION:-1.18.3}"
NAMESPACE="${NAMESPACE:-cilium-system}"
RELEASE="${RELEASE:-cilium}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-1.2.1}"

# K8S_SERVICE_HOST och K8S_SERVICE_PORT löses ut automatiskt från
# kubeconfig om de inte är satta explicit
K8S_SERVICE_HOST="${K8S_SERVICE_HOST:-}"
K8S_SERVICE_PORT="${K8S_SERVICE_PORT:-}"
# ============================================================

usage() {
  echo "Användning: $0"
  echo ""
  echo "Miljövariabler (alla har defaultvärden):"
  echo "  CILIUM_VERSION      Cilium Helm chart-version   (default: 1.18.3)"
  echo "  GATEWAY_API_VERSION Gateway API CRD-version     (default: 1.2.1)"
  echo "  NAMESPACE           Namespace för Cilium        (default: cilium-system)"
  echo "  RELEASE             Helm release-namn           (default: cilium)"
  echo "  K8S_SERVICE_HOST    Kubernetes API-host         (default: löses från kubeconfig)"
  echo "  K8S_SERVICE_PORT    Kubernetes API-port         (default: löses från kubeconfig)"
  echo ""
  echo "Exempel:"
  echo "  $0"
  echo "  CILIUM_VERSION=1.18.0 $0"
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

for cmd in helm kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ $cmd not found."
    exit 1
  fi
done

CONTEXT=$(kubectl config current-context 2>/dev/null || true)
if [[ -z "${CONTEXT}" ]]; then
  echo "❌ No active kubectl context found."
  exit 1
fi

# ============================================================
# Lös ut K8S_SERVICE_HOST och K8S_SERVICE_PORT från kubeconfig
# om de inte redan är satta
# ============================================================
if [[ -z "${K8S_SERVICE_HOST}" || -z "${K8S_SERVICE_PORT}" ]]; then
  _server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  if [[ -z "${_server}" ]]; then
    echo "❌ Kunde inte läsa server från kubeconfig."
    exit 1
  fi
  K8S_SERVICE_HOST="${K8S_SERVICE_HOST:-$(echo "${_server}" | sed 's|https://||' | cut -d: -f1)}"
  K8S_SERVICE_PORT="${K8S_SERVICE_PORT:-$(echo "${_server}" | sed 's|.*:||')}"
fi

if [[ -z "${K8S_SERVICE_HOST}" || -z "${K8S_SERVICE_PORT}" ]]; then
  echo "❌ Kunde inte bestämma K8S_SERVICE_HOST/PORT."
  echo "   Sätt dem explicit eller se till att KUBECONFIG är korrekt konfigurerat."
  exit 1
fi

echo "🔧 Konfiguration:"
echo "   Context:            ${CONTEXT}"
echo "   Cilium version:     ${CILIUM_VERSION}"
echo "   Gateway API CRDs:   ${GATEWAY_API_VERSION}"
echo "   Namespace:          ${NAMESPACE}"
echo "   k8sServiceHost:     ${K8S_SERVICE_HOST}"
echo "   k8sServicePort:     ${K8S_SERVICE_PORT}"
echo ""

read -r -p "Continue? (y/N) " confirm
[[ "${confirm}" =~ ^[yY]$ ]] || {
  echo "Aborted."
  exit 0
}

# ============================================================
# Steg 1: Gateway API CRDs
# Måste installeras INNAN Cilium startar med gatewayAPI.enabled=true
# ============================================================
echo ""
echo "📦 Installerar Gateway API CRDs v${GATEWAY_API_VERSION}..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GATEWAY_API_VERSION}/standard-install.yaml"

echo "⏳ Väntar på att Gateway API CRDs ska bli etablerade..."
kubectl wait --for=condition=Established \
  crd/gatewayclasses.gateway.networking.k8s.io \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io \
  --timeout=60s

# ============================================================
# Steg 2: Skapa namespace med privileged pod security
# ============================================================
echo ""
echo "📦 Skapar namespace ${NAMESPACE}..."
kubectl create ns "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite

# ============================================================
# Steg 3: Ta bort Flannel
# Talos installerar Flannel som standard-CNI. Vi tar bort det innan
# Cilium installeras för att undvika att två CNI:er körs parallellt.
# ============================================================
echo ""
echo "🗑️  Tar bort Flannel..."
for resource in \
  "daemonset/kube-flannel kube-system" \
  "configmap/kube-flannel-cfg kube-system" \
  "serviceaccount/flannel kube-system" \
  "clusterrole/flannel" \
  "clusterrolebinding/flannel"; do
  res=$(echo "$resource" | awk '{print $1}')
  ns=$(echo "$resource" | awk '{print $2}')
  ns_arg=""
  [[ -n "$ns" ]] && ns_arg="-n $ns"
  if kubectl get $res $ns_arg &>/dev/null 2>&1; then
    kubectl delete $res $ns_arg
    echo "   ✓ Borttagen: $res"
  else
    echo "   – Hittades inte: $res, hoppar över"
  fi
done

echo ""
echo "⏳ Väntar 5s på att Flannel-pods ska försvinna..."
sleep 5

# ============================================================
# Steg 4: Installera Cilium via Helm
# ============================================================
echo ""
echo "🚀 Installerar Cilium ${CILIUM_VERSION}..."
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

helm upgrade --install "${RELEASE}" cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace "${NAMESPACE}" \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set k8sServiceHost="${K8S_SERVICE_HOST}" \
  --set k8sServicePort="${K8S_SERVICE_PORT}" \
  --set encryption.enabled=true \
  --set encryption.type=wireguard \
  --set gatewayAPI.enabled=true \
  --set gatewayAPI.enableAlpn=true \
  --set-string gatewayAPI.gatewayClass.create="true" \
  --set envoy.securityContext.capabilities.keepCapNetBindService=true \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,port-distribution,icmp,http}" \
  --set hubble.metrics.enableOpenMetrics=true

# ============================================================
# Vänta och verifiera
# ============================================================
echo ""
echo "⏳ Väntar på att Cilium ska bli redo..."
kubectl rollout status daemonset/cilium -n "${NAMESPACE}" --timeout=300s

echo ""
echo "🔄 Startar om Cilium-operatorn för att aktivera Gateway API-kontrollern..."
kubectl rollout restart deployment/cilium-operator -n "${NAMESPACE}"
kubectl rollout status deployment/cilium-operator -n "${NAMESPACE}" --timeout=120s

echo ""
echo "⏳ Väntar på att GatewayClass cilium ska bli Accepted..."
kubectl wait --for=condition=Accepted \
  gatewayclass/cilium \
  --timeout=120s

echo ""
echo "🔄 Startar om hubble-relay för att säkerställa korrekt nätverksanslutning..."
kubectl rollout restart deployment/hubble-relay -n "${NAMESPACE}"
kubectl rollout status deployment/hubble-relay -n "${NAMESPACE}" --timeout=120s

echo ""
echo "🔒 Krypteringsstatus:"
for pod in $(kubectl get pods -n "${NAMESPACE}" -l k8s-app=cilium -o name); do
  echo "   === $pod ==="
  kubectl exec -n "${NAMESPACE}" "$pod" -- cilium encrypt status
done

echo ""
echo "✅ Cilium installerat! Nodstatus:"
kubectl get nodes -o wide
echo ""
echo "   GatewayClass:"
kubectl get gatewayclass
echo ""
echo "   Verifiera vidare med:"
echo "   helm get values ${RELEASE} -n ${NAMESPACE}"
echo "   cilium connectivity test"
echo ""
echo "   Nästa steg:"
echo "   ./install_gateway.sh"
