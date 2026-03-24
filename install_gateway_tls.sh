#!/usr/bin/env bash
# install_gateway_tls.sh — lägger till TLS på shared Gateway via cert-manager
# Steg 2 av 2: kräver att install_gateway.sh körts och HTTP fungerar
set -euo pipefail

# ============================================================
# Konfiguration
# ============================================================
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-1.20.0}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-gateway}"
GATEWAY_NAME="${GATEWAY_NAME:-shared-gateway}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
LETSENCRYPT_ENV="${LETSENCRYPT_ENV:-staging}" # staging eller production
TLS_HOSTNAMES="${TLS_HOSTNAMES:-}" # Kommaseparerade FQDNs för certifikatet (http-01 stöder ej wildcard)
# ============================================================

usage() {
  echo "Användning: $0"
  echo ""
  echo "Miljövariabler:"
  echo "  CERT_MANAGER_VERSION   cert-manager Helm chart-version  (default: 1.20.0)"
  echo "  GATEWAY_NAMESPACE      Namespace för Gateway             (default: gateway)"
  echo "  GATEWAY_NAME           Namn på shared Gateway            (default: shared-gateway)"
  echo "  LETSENCRYPT_EMAIL      E-post till Let's Encrypt         (obligatorisk)"
  echo "  LETSENCRYPT_ENV        staging eller production           (default: staging)"
  echo "  TLS_HOSTNAMES          Kommaseparerade FQDNs för cert    (obligatorisk, ej wildcard)"
  echo ""
  echo "Exempel:"
  echo "  LETSENCRYPT_EMAIL=ops@example.com TLS_HOSTNAMES=min-app.example.com $0"
  echo "  LETSENCRYPT_EMAIL=ops@example.com LETSENCRYPT_ENV=production TLS_HOSTNAMES=min-app.example.com,api.example.com $0"
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

if [[ -z "${LETSENCRYPT_EMAIL}" ]]; then
  echo "❌ LETSENCRYPT_EMAIL måste vara satt"
  echo "   Exempel: LETSENCRYPT_EMAIL=ops@example.com $0"
  exit 1
fi

if ! kubectl get gateway "${GATEWAY_NAME}" -n "${GATEWAY_NAMESPACE}" &>/dev/null 2>&1; then
  echo "❌ Gateway '${GATEWAY_NAME}' hittades inte i namespace '${GATEWAY_NAMESPACE}'."
  echo "   Kör install_gateway.sh och verifiera att HTTP fungerar innan du kör detta script."
  exit 1
fi

if [[ -z "${TLS_HOSTNAMES}" ]]; then
  echo "❌ TLS_HOSTNAMES måste vara satt till kommaseparerade FQDNs för certifikatet (http-01 stöder inte wildcard)."
  echo "   Exempel: TLS_HOSTNAMES=min-app.example.com,api.example.com $0"
  exit 1
fi

echo "🔧 Konfiguration:"
echo "   Context:               ${CONTEXT}"
echo "   cert-manager version:  ${CERT_MANAGER_VERSION}"
echo "   Gateway namespace:     ${GATEWAY_NAMESPACE}"
echo "   Gateway namn:          ${GATEWAY_NAME}"
echo "   Let's Encrypt email:   ${LETSENCRYPT_EMAIL}"
echo "   Let's Encrypt env:     ${LETSENCRYPT_ENV}"
echo ""
if [[ "${LETSENCRYPT_ENV}" == "production" ]]; then
  echo "   ⚠️  Du kör mot Let's Encrypt PRODUCTION."
  echo "      Certifikat utfärdas på riktigt och rate limits gäller."
  echo "      Kontrollera att DNS är korrekt satt innan du fortsätter."
  echo ""
fi

read -r -p "Continue? (y/N) " confirm
[[ "${confirm}" =~ ^[yY]$ ]] || {
  echo "Aborted."
  exit 0
}

# ============================================================
# Steg 1: Installera cert-manager
# ============================================================
echo ""
echo "🔐 Installerar cert-manager ${CERT_MANAGER_VERSION}..."
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --set config.enableGatewayAPI=true

echo "⏳ Väntar på att cert-manager ska bli redo..."
kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s
kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s

# ============================================================
# Steg 2: Skapa ClusterIssuers
# ============================================================
echo ""
echo "📜 Skapar Let's Encrypt ClusterIssuers..."
kubectl apply -f - <<EOF
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: ${GATEWAY_NAME}
                namespace: ${GATEWAY_NAMESPACE}
                kind: Gateway
                sectionName: http
                sectionName: http
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-production-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: ${GATEWAY_NAME}
                namespace: ${GATEWAY_NAMESPACE}
                kind: Gateway
EOF

echo "⏳ Väntar på att ClusterIssuers ska bli redo..."
kubectl wait --for=condition=Ready \
  clusterissuer/letsencrypt-staging \
  clusterissuer/letsencrypt-production \
  --timeout=60s

# ============================================================
# Steg 3: Skapa Certificate för angivna hostnames (HTTP-01)
# ============================================================
echo ""
echo "📜 Skapar Certificate ${GATEWAY_NAME}-tls för: ${TLS_HOSTNAMES}"
DNS_NAMES_YAML=""
IFS=',' read -ra _hosts <<< "${TLS_HOSTNAMES}"
for h in "${_hosts[@]}"; do
  h_trimmed="$(echo "$h" | xargs)"
  [[ -z "$h_trimmed" ]] && continue
  DNS_NAMES_YAML="${DNS_NAMES_YAML}      - ${h_trimmed}\n"
done
if [[ -z "${DNS_NAMES_YAML}" ]]; then
  echo "❌ Inga giltiga hostnames i TLS_HOSTNAMES"
  exit 1
fi
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${GATEWAY_NAME}-tls
  namespace: ${GATEWAY_NAMESPACE}
spec:
  secretName: ${GATEWAY_NAME}-tls
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-${LETSENCRYPT_ENV}
  dnsNames:
$(printf "%b" "${DNS_NAMES_YAML}")
EOF

echo "⏳ Väntar på att Certificate ska bli redo (detta kan ta flera minuter)..."
kubectl wait --for=condition=Ready \
  certificate/${GATEWAY_NAME}-tls \
  -n ${GATEWAY_NAMESPACE} \
  --timeout=10m || true

# ============================================================
# Steg 4: Uppdatera Gateway med HTTPS-listener
# ============================================================
echo ""
echo "🔒 Uppdaterar Gateway med HTTPS-listener..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${GATEWAY_NAMESPACE}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-${LETSENCRYPT_ENV}
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      protocol: HTTPS
      port: 443
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - name: ${GATEWAY_NAME}-tls
            namespace: ${GATEWAY_NAMESPACE}
EOF

echo ""
echo "✅ TLS aktiverat på Gateway!"
echo ""
echo "   cert-manager kommer nu automatiskt utfärda certifikat för domäner"
echo "   som har HTTPRoutes kopplade till ${GATEWAY_NAME}."
echo ""
echo "   Kontrollera att certifikat utfärdas:"
echo "   kubectl get certificate -A"
echo "   kubectl describe certificate ${GATEWAY_NAME}-tls -n ${GATEWAY_NAMESPACE}"
echo ""
echo "   För att testa HTTPS på en befintlig HTTPRoute, lägg till redirect HTTP→HTTPS:"
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
echo "       - matches:"
echo "           - path:"
echo "               type: PathPrefix"
echo "               value: /"
echo "         filters:"
echo "           - type: RequestRedirect"
echo "             requestRedirect:"
echo "               scheme: https"
echo "               statusCode: 301"
echo "       - matches:"
echo "           - path:"
echo "               type: PathPrefix"
echo "               value: /"
echo "         backendRefs:"
echo "           - name: min-app-service"
echo "             port: 8080"
echo "   ROUTE"
echo ""
if [[ "${LETSENCRYPT_ENV}" == "staging" ]]; then
  echo "   ℹ️  Du kör med Let's Encrypt STAGING."
  echo "      Certifikaten är giltiga men inte betrodda av browsers."
  echo "      När allt fungerar, kör om med LETSENCRYPT_ENV=production."
fi
