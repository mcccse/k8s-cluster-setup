#!/usr/bin/env bash
# install_argocd.sh — installerar Argo CD och applicerar root-app mot apps-repo
set -euo pipefail

# ============================================================
# Konfiguration — ändra dessa variabler
# ============================================================
ARGOCD_HELM_CHART_VERSION="${ARGOCD_HELM_CHART_VERSION:-9.4.10}"
APPS_REPO="${APPS_REPO:-https://github.com/your-org/apps}"
APPS_REVISION="${APPS_REVISION:-main}"
APPS_PATH="${APPS_PATH:-apps}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

# Autentisering mot apps-repo: "token" eller "ssh"
REPO_AUTH_METHOD="${REPO_AUTH_METHOD:-token}"

# HTTPS/token-autentisering
REPO_USERNAME="${REPO_USERNAME:-git}"
REPO_TOKEN="${REPO_TOKEN:-}" # GitHub/GitLab personal access token

# SSH-autentisering
REPO_SSH_KEY_PATH="${REPO_SSH_KEY_PATH:-${HOME}/.ssh/id_ed25519}"
# ============================================================

usage() {
  echo "Användning: $0 [flaggor]"
  echo ""
  echo "Miljövariabler (alla har defaultvärden):"
  echo "  ARGOCD_HELM_CHART_VERSION  Helm chart-version för Argo CD  (default: 9.4.10)"
  echo "  APPS_REPO                  URL till apps-repo               (default: https://github.com/your-org/apps)"
  echo "  APPS_REVISION              Branch/tag i apps-repo           (default: main)"
  echo "  APPS_PATH                  Sökväg till apps-katalogen       (default: apps)"
  echo "  ARGOCD_NAMESPACE           Namespace för Argo CD            (default: argocd)"
  echo "  REPO_AUTH_METHOD           Autentiseringsmetod: token/ssh   (default: token)"
  echo ""
  echo "  För REPO_AUTH_METHOD=token:"
  echo "  REPO_USERNAME              Git-användarnamn                 (default: git)"
  echo "  REPO_TOKEN                 Personal access token            (obligatorisk)"
  echo ""
  echo "  För REPO_AUTH_METHOD=ssh:"
  echo "  REPO_SSH_KEY_PATH          Sökväg till privat SSH-nyckel    (default: ~/.ssh/id_ed25519)"
  echo ""
  echo "Exempel:"
  echo "  REPO_AUTH_METHOD=token REPO_TOKEN=ghp_xxx APPS_REPO=https://github.com/org/apps $0"
  echo "  REPO_AUTH_METHOD=ssh REPO_SSH_KEY_PATH=~/.ssh/deploy_key APPS_REPO=git@github.com:org/apps $0"
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

# Validera att nödvändiga variabler är satta
if [[ "${REPO_AUTH_METHOD}" == "token" && -z "${REPO_TOKEN}" ]]; then
  echo "❌ REPO_TOKEN måste vara satt när REPO_AUTH_METHOD=token"
  exit 1
fi

if [[ "${REPO_AUTH_METHOD}" == "ssh" && ! -f "${REPO_SSH_KEY_PATH}" ]]; then
  echo "❌ SSH-nyckeln hittades inte: ${REPO_SSH_KEY_PATH}"
  exit 1
fi

echo "🔧 Konfiguration:"
echo "   Argo CD Helm chart: ${ARGOCD_HELM_CHART_VERSION}"
echo "   Apps-repo:          ${APPS_REPO}"
echo "   Revision:           ${APPS_REVISION}"
echo "   Path:               ${APPS_PATH}"
echo "   Namespace:          ${ARGOCD_NAMESPACE}"
echo "   Auth-metod:         ${REPO_AUTH_METHOD}"
echo ""

# Installera Argo CD med Helm
echo "📦 Lägger till Argo CD Helm-repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "🚀 Installerar Argo CD ${ARGOCD_HELM_CHART_VERSION}..."
helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NAMESPACE}" \
  --create-namespace \
  --version "${ARGOCD_HELM_CHART_VERSION}" \
  --wait

# Skapa repo-credentials secret
echo "🔑 Skapar repo-credentials (${REPO_AUTH_METHOD})..."

if [[ "${REPO_AUTH_METHOD}" == "token" ]]; then
  kubectl create secret generic argocd-repo-creds \
    --namespace "${ARGOCD_NAMESPACE}" \
    --from-literal=type=git \
    --from-literal=url="${APPS_REPO}" \
    --from-literal=username="${REPO_USERNAME}" \
    --from-literal=password="${REPO_TOKEN}" \
    --dry-run=client -o yaml |
    kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" --dry-run=client -o yaml |
    kubectl apply -f -

elif [[ "${REPO_AUTH_METHOD}" == "ssh" ]]; then
  kubectl create secret generic argocd-repo-creds \
    --namespace "${ARGOCD_NAMESPACE}" \
    --from-literal=type=git \
    --from-literal=url="${APPS_REPO}" \
    --from-file=sshPrivateKey="${REPO_SSH_KEY_PATH}" \
    --dry-run=client -o yaml |
    kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" --dry-run=client -o yaml |
    kubectl apply -f -

else
  echo "❌ Okänd REPO_AUTH_METHOD: ${REPO_AUTH_METHOD} (måste vara 'token' eller 'ssh')"
  exit 1
fi

# Applicera root-app
echo "🌱 Applicerar root-app mot ${APPS_REPO}..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: default
  source:
    repoURL: ${APPS_REPO}
    targetRevision: ${APPS_REVISION}
    path: ${APPS_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGOCD_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

echo ""
echo "✅ Argo CD installerat och root-app applicerad."
echo ""
echo "   Hämta initialt admin-lösenord:"
echo "   kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret \\"
echo "     -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "   Följ synk-status:"
echo "   kubectl get applications -n ${ARGOCD_NAMESPACE}"
