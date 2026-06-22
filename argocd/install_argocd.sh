#!/usr/bin/env bash
# install_argocd.sh — installerar Argo CD och applicerar root-app mot klusterspecifik path
set -euo pipefail

# ============================================================
# Konfiguration
# ============================================================
ARGOCD_HELM_CHART_VERSION="${ARGOCD_HELM_CHART_VERSION:-9.4.10}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

CLUSTER_NAME="${CLUSTER_NAME:-demo}"

APPS_REPO="${APPS_REPO:-http://gitea-http.gitea.svc.cluster.local:3000/admin/app-of-apps.git}"
APPS_REVISION="${APPS_REVISION:-main}"
APPS_PATH="${APPS_PATH:-clusters/${CLUSTER_NAME}}"

# Auth-metoder:
# - none  : publikt repo
# - token : username/password eller PAT
# - ssh   : SSH deploy key
REPO_AUTH_METHOD="${REPO_AUTH_METHOD:-none}"

# För token-auth
REPO_USERNAME="${REPO_USERNAME:-git}"
REPO_TOKEN="${REPO_TOKEN:-}"

# För ssh-auth
REPO_SSH_KEY_PATH="${REPO_SSH_KEY_PATH:-${HOME}/.ssh/id_ed25519}"

# Om repo körs över intern HTTP i klustret
REPO_INSECURE="${REPO_INSECURE:-true}"

# AppProject / root app
ARGOCD_PROJECT="${ARGOCD_PROJECT:-platform}"
ROOT_APP_NAME="${ROOT_APP_NAME:-${CLUSTER_NAME}-root}"

usage() {
  cat <<EOF
Användning: $0

Miljövariabler:
  ARGOCD_HELM_CHART_VERSION   Helm chart-version för Argo CD
  ARGOCD_NAMESPACE            Namespace för Argo CD
  CLUSTER_NAME                Klusternamn, t.ex. demo
  APPS_REPO                   URL till GitOps-repo
  APPS_REVISION               Branch/tag
  APPS_PATH                   Path i repo (default: clusters/\${CLUSTER_NAME})
  REPO_AUTH_METHOD            none | token | ssh
  REPO_USERNAME               Användare för token-auth
  REPO_TOKEN                  Token/lösenord för token-auth
  REPO_SSH_KEY_PATH           Privat SSH-nyckel för ssh-auth
  REPO_INSECURE               true/false för intern HTTP utan TLS
  ARGOCD_PROJECT              AppProject-namn
  ROOT_APP_NAME               Namn på root-applikationen

Exempel:
  CLUSTER_NAME=demo \\
  APPS_REPO=http://gitea-http.gitea.svc.cluster.local:3000/admin/app-of-apps.git \\
  REPO_AUTH_METHOD=none \\
  $0
EOF
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl not found in PATH"
  exit 1
}

command -v helm >/dev/null 2>&1 || {
  echo "helm not found in PATH"
  exit 1
}

case "${REPO_AUTH_METHOD}" in
none) ;;
token)
  if [[ -z "${REPO_TOKEN}" ]]; then
    echo "REPO_TOKEN måste vara satt när REPO_AUTH_METHOD=token"
    exit 1
  fi
  ;;
ssh)
  if [[ ! -f "${REPO_SSH_KEY_PATH}" ]]; then
    echo "SSH-nyckeln hittades inte: ${REPO_SSH_KEY_PATH}"
    exit 1
  fi
  ;;
*)
  echo "Okänd REPO_AUTH_METHOD: ${REPO_AUTH_METHOD} (måste vara none, token eller ssh)"
  exit 1
  ;;
esac

echo "Konfiguration:"
echo "  Argo CD chart version : ${ARGOCD_HELM_CHART_VERSION}"
echo "  Namespace             : ${ARGOCD_NAMESPACE}"
echo "  Cluster               : ${CLUSTER_NAME}"
echo "  Apps repo             : ${APPS_REPO}"
echo "  Revision              : ${APPS_REVISION}"
echo "  Path                  : ${APPS_PATH}"
echo "  Repo auth             : ${REPO_AUTH_METHOD}"
echo "  Repo insecure         : ${REPO_INSECURE}"
echo "  AppProject            : ${ARGOCD_PROJECT}"
echo "  Root app              : ${ROOT_APP_NAME}"
echo

echo "Lägger till Argo CD Helm-repo..."
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "Installerar Argo CD ${ARGOCD_HELM_CHART_VERSION}..."
helm upgrade --install argocd argo/argo-cd \
  --namespace "${ARGOCD_NAMESPACE}" \
  --create-namespace \
  --version "${ARGOCD_HELM_CHART_VERSION}" \
  --wait

echo "Skapar AppProject ${ARGOCD_PROJECT}..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${ARGOCD_PROJECT}
  namespace: ${ARGOCD_NAMESPACE}
spec:
  description: Platform apps for cluster ${CLUSTER_NAME}
  sourceRepos:
    - ${APPS_REPO}
  destinations:
    - namespace: "*"
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
EOF

echo "Skapar repo-secret (${REPO_AUTH_METHOD})..."

if [[ "${REPO_AUTH_METHOD}" == "none" ]]; then
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-repo-creds
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${APPS_REPO}
  insecure: "${REPO_INSECURE}"
EOF

elif [[ "${REPO_AUTH_METHOD}" == "token" ]]; then
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-repo-creds
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${APPS_REPO}
  username: ${REPO_USERNAME}
  password: ${REPO_TOKEN}
  insecure: "${REPO_INSECURE}"
EOF

elif [[ "${REPO_AUTH_METHOD}" == "ssh" ]]; then
  SSH_KEY_CONTENT="$(cat "${REPO_SSH_KEY_PATH}")"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-repo-creds
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${APPS_REPO}
  sshPrivateKey: |
$(printf '%s\n' "${SSH_KEY_CONTENT}" | sed 's/^/    /')
  insecure: "${REPO_INSECURE}"
EOF
fi

echo "Applicerar root-app ${ROOT_APP_NAME}..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ROOT_APP_NAME}
  namespace: ${ARGOCD_NAMESPACE}
spec:
  project: ${ARGOCD_PROJECT}
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
    syncOptions:
      - CreateNamespace=true
EOF

echo
echo "Argo CD installerat och root-app applicerad."
echo
echo "Initialt admin-lösenord:"
echo "kubectl -n ${ARGOCD_NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo
echo "Visa applications:"
echo "kubectl get applications -n ${ARGOCD_NAMESPACE}"
