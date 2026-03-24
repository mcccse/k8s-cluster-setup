#!/usr/bin/env bash
# install_hccm.sh — installerar Hetzner Cloud Controller Manager (CCM)
# CCM hanterar node lifecycle och LoadBalancer-services mot Hetzner Cloud API
set -euo pipefail

# ============================================================
# Konfiguration
# ============================================================
HCCM_VERSION="${HCCM_VERSION:-1.30.1}"
NAMESPACE="${NAMESPACE:-hccm-system}"
RELEASE="${RELEASE:-hccm}"
REGION="${REGION:-fsn1}" # fsn1, nbg1, hel1 — används för LB location

# Hetzner API-token — hämtas från miljövariabel eller befintligt secret
HCLOUD_TOKEN="${HCLOUD_TOKEN:-}"
# ============================================================

usage() {
  echo "Användning: $0"
  echo ""
  echo "Miljövariabler:"
  echo "  HCCM_VERSION    Helm chart-version för CCM    (default: 1.30.1)"
  echo "  HCLOUD_TOKEN    Hetzner API-token             (obligatorisk om secret saknas)"
  echo "  NAMESPACE       Namespace                     (default: hccm-system)"
  echo "  RELEASE         Helm release-namn             (default: hccm)"
  echo "  REGION          Hetzner-region för LBs        (default: fsn1)"
  echo ""
  echo "Exempel:"
  echo "  HCLOUD_TOKEN=xxx REGION=hel1 $0"
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

for cmd in helm kubectl hcloud jq; do
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

# Kontrollera att vi har ett API-token antingen via env eller befintligt secret
if [[ -z "${HCLOUD_TOKEN}" ]]; then
  if ! kubectl get secret hcloud -n "${NAMESPACE}" &>/dev/null 2>&1; then
    echo "❌ HCLOUD_TOKEN måste vara satt, eller så måste secret 'hcloud' finnas i ${NAMESPACE}"
    echo "   Exempel: HCLOUD_TOKEN=xxx $0"
    exit 1
  fi
  echo "   Använder befintligt secret 'hcloud' i namespace ${NAMESPACE}"
fi

echo "🔧 Konfiguration:"
echo "   Context:        ${CONTEXT}"
echo "   CCM version:    ${HCCM_VERSION}"
echo "   Namespace:      ${NAMESPACE}"
echo "   Region:         ${REGION}"
echo ""

read -r -p "Continue? (y/N) " confirm
[[ "${confirm}" =~ ^[yY]$ ]] || {
  echo "Aborted."
  exit 0
}

# ============================================================
# Skapa namespace
# ============================================================
kubectl create ns "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ============================================================
# Skapa secret om token är satt explicit
# ============================================================
if [[ -n "${HCLOUD_TOKEN}" ]]; then
  echo ""
  echo "🔑 Skapar hcloud secret..."
  kubectl create secret generic hcloud \
    --from-literal=token="${HCLOUD_TOKEN}" \
    -n "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ============================================================
# Installera Hetzner CCM via Helm
# ============================================================
echo ""
echo "🚀 Installerar Hetzner Cloud Controller Manager ${HCCM_VERSION}..."
helm repo add hcloud https://charts.hetzner.cloud >/dev/null 2>&1 || true
helm repo update hcloud >/dev/null

helm upgrade --install "${RELEASE}" hcloud/hcloud-cloud-controller-manager \
  --namespace "${NAMESPACE}" \
  --version "${HCCM_VERSION}" \
  --set networking.enabled=false \
  --set-string env.HCLOUD_LOAD_BALANCERS_USE_PRIVATE_IP.value="false" \
  --set-string env.HCLOUD_LOAD_BALANCERS_LOCATION.value="${REGION}"

# ============================================================
# Vänta och verifiera
# ============================================================
echo ""
echo "⏳ Väntar på att CCM ska bli redo..."
kubectl rollout status deployment/hcloud-cloud-controller-manager \
  -n "${NAMESPACE}" --timeout=120s

# ============================================================
# Sätt ProviderID på noder
# Talos sätter inte ProviderID automatiskt — vi hämtar server-IDs
# från Hetzner och patchar noderna manuellt
# ============================================================
echo ""
echo "🔗 Sätter ProviderID på noder..."

# Hämta alla noder utan ProviderID
NODES=$(kubectl get nodes -o json |
  jq -r '.items[] | select(.spec.providerID == null or .spec.providerID == "") | .metadata.name')

if [[ -z "${NODES}" ]]; then
  echo "   Alla noder har redan ProviderID, hoppar över."
else
  # Hämta server-lista från Hetzner
  SERVERS=$(hcloud server list -o json)

  while IFS= read -r node; do
    # Matcha nodnamn mot servernamn i Hetzner
    SERVER_ID=$(echo "${SERVERS}" |
      jq -r --arg name "${node}" '.[] | select(.name == $name) | .id')

    if [[ -z "${SERVER_ID}" ]]; then
      echo "   ⚠️  Hittade ingen Hetzner-server för nod: ${node}"
      echo "      Kontrollera att nodnamnet matchar servernamnet i Hetzner."
    else
      kubectl patch node "${node}" \
        --type merge \
        -p "{\"spec\":{\"providerID\":\"hcloud://${SERVER_ID}\"}}"
      echo "   ✅ ${node} → hcloud://${SERVER_ID}"
    fi
  done <<<"${NODES}"
fi

echo ""
echo "✅ Hetzner CCM installerat!"
echo ""
echo "   Noder:"
kubectl get nodes -o custom-columns="NAME:.metadata.name,PROVIDERID:.spec.providerID,STATUS:.status.conditions[-1].type"
echo ""
echo "   LoadBalancer-services får nu externa IP-adresser automatiskt"
echo "   i region ${REGION}."
echo ""
echo "   Nästa steg:"
echo "   ./install_gateway.sh"
