#!/usr/bin/env bash
# install-cilium.sh — removes Flannel and installs Cilium (Talos-optimized)
set -euo pipefail

CILIUM_VERSION="${CILIUM_VERSION:-}"
K8S_SERVICE_HOST="${K8S_SERVICE_HOST:-localhost}"
K8S_SERVICE_PORT="${K8S_SERVICE_PORT:-7445}"

# ============================================================
# Preflight checks
# ============================================================
if ! command -v cilium &>/dev/null; then
  echo "❌ cilium CLI not found. Install from https://github.com/cilium/cilium-cli/releases"
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

echo "🔧 Configuration:"
echo "   Context:          ${CONTEXT}"
echo "   Cilium CLI:       $(cilium version --client 2>/dev/null | head -1)"
echo "   k8sServiceHost:   ${K8S_SERVICE_HOST}"
echo "   k8sServicePort:   ${K8S_SERVICE_PORT}"
[[ -n "${CILIUM_VERSION}" ]] && echo "   Cilium version:   ${CILIUM_VERSION}" || echo "   Cilium version:   latest stable"
echo ""

read -r -p "Continue? (y/N) " confirm
[[ "${confirm}" =~ ^[yY]$ ]] || {
  echo "Aborted."
  exit 0
}

# ============================================================
# Remove Flannel
# ============================================================
delete_if_exists() {
  local resource="$1"
  local name="$2"
  local args=("${resource}" "${name}")
  [[ -n "${3:-}" ]] && args+=("-n" "$3")

  if kubectl get "${args[@]}" &>/dev/null 2>&1; then
    kubectl delete "${args[@]}"
    echo "   ✓ Deleted: ${resource}/${name}"
  else
    echo "   – Not found: ${resource}/${name}, skipping"
  fi
}

echo ""
echo "🗑️  Removing Flannel..."
delete_if_exists daemonset kube-flannel kube-system
delete_if_exists configmap kube-flannel-cfg kube-system
delete_if_exists serviceaccount flannel kube-system
delete_if_exists clusterrole flannel
delete_if_exists clusterrolebinding flannel

echo ""
echo "⏳ Waiting 5s for Flannel pods to disappear..."
sleep 5

# ============================================================
# Install Cilium
# ============================================================
echo ""
echo "🚀 Installing Cilium..."

cilium_args=(
  "--set" "ipam.mode=kubernetes"
  "--set" "kubeProxyReplacement=true"
  "--set" "securityContext.capabilities.ciliumAgent={CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
  "--set" "securityContext.capabilities.cleanCiliumState={NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
  "--set" "cgroup.autoMount.enabled=false"
  "--set" "cgroup.hostRoot=/sys/fs/cgroup"
  "--set" "k8sServiceHost=${K8S_SERVICE_HOST}"
  "--set" "k8sServicePort=${K8S_SERVICE_PORT}"
)

[[ -n "${CILIUM_VERSION}" ]] && cilium_args+=("--version" "${CILIUM_VERSION}")

cilium install "${cilium_args[@]}"

# ============================================================
# Wait and verify
# ============================================================
echo ""
echo "⏳ Waiting for Cilium to become ready..."
cilium status --wait

echo ""
echo "✅ Cilium installed! Node status:"
kubectl get nodes -o wide
