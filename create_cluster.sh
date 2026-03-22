#!/usr/bin/env bash
# create_cluster.sh — genererar och applicerar ett CAPI/Talos/Hetzner-klustermanifest
set -euo pipefail

# ============================================================
# Konfiguration — ändra dessa variabler
# ============================================================
CLUSTER_NAME="${CLUSTER_NAME:-capi-hetzner}"
REGION="${REGION:-fsn1}"                   # fsn1, nbg1, hel1
CP_MACHINE_TYPE="${CP_MACHINE_TYPE:-cx23}" # cx23, cx32, cx42 ...
WORKER_MACHINE_TYPE="${WORKER_MACHINE_TYPE:-cx23}"
CP_REPLICAS="${CP_REPLICAS:-3}"
WORKER_REPLICAS="${WORKER_REPLICAS:-2}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.35.0}"
TALOS_VERSION="${TALOS_VERSION:-v1.12.4}"
TALOS_IMAGE_NAME="${TALOS_IMAGE_NAME:-talos-v1.12.4}" # caph-image-name label
HETZNER_SECRET="${HETZNER_SECRET:-hetzner}"
SSH_KEY_NAME="${SSH_KEY_NAME:-hcloudSSHKey}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/12}"
LB_TYPE="${LB_TYPE:-lb11}"
NAMESPACE="${NAMESPACE:-default}"
OUTPUT_DIR="${OUTPUT_DIR:-talos-config/${CLUSTER_NAME}}"
DRY_RUN="${DRY_RUN:-false}"
# ============================================================

usage() {
  echo "Användning: $0 [flaggor]"
  echo ""
  echo "Miljövariabler (alla har defaultvärden):"
  echo "  CLUSTER_NAME          Klusternamn                (default: capi-hetzner)"
  echo "  REGION                Hetzner-region             (default: fsn1)"
  echo "  CP_MACHINE_TYPE       Control plane maskintyp    (default: cx23)"
  echo "  WORKER_MACHINE_TYPE   Worker maskintyp           (default: cx23)"
  echo "  CP_REPLICAS           Antal control plane-noder  (default: 3)"
  echo "  WORKER_REPLICAS       Antal workers              (default: 2)"
  echo "  KUBERNETES_VERSION    Kubernetes-version         (default: v1.35.0)"
  echo "  TALOS_VERSION         Talos-version              (default: v1.12.4)"
  echo "  TALOS_IMAGE_NAME      caph-image-name label      (default: talos-v1.12.4)"
  echo "  DRY_RUN               Generera manifest, applicera inte (default: false)"
  echo ""
  echo "Exempel:"
  echo "  $0"
  echo "  CLUSTER_NAME=prod REGION=nbg1 CP_REPLICAS=3 WORKER_REPLICAS=5 $0"
  echo "  DRY_RUN=true $0"
  exit 0
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

MANIFEST="${OUTPUT_DIR}/${CLUSTER_NAME}-cluster.yaml"

echo "🔧 Konfiguration:"
echo "   Kluster:        ${CLUSTER_NAME}"
echo "   Region:         ${REGION}"
echo "   Control plane:  ${CP_REPLICAS}x ${CP_MACHINE_TYPE}"
echo "   Workers:        ${WORKER_REPLICAS}x ${WORKER_MACHINE_TYPE}"
echo "   Kubernetes:     ${KUBERNETES_VERSION}"
echo "   Talos:          ${TALOS_VERSION} (image: ${TALOS_IMAGE_NAME})"
echo "   Namespace:      ${NAMESPACE}"
echo "   Manifest:       ${MANIFEST}"
echo "   Dry run:        ${DRY_RUN}"
echo ""

read -r -p "Continue? (y/N) " confirm
[[ "${confirm}" =~ ^[yY]$ ]] || {
  echo "Aborted."
  exit 0
}

# Generera manifest
echo "📝 Genererar manifest: ${MANIFEST}"
mkdir -p "${OUTPUT_DIR}"
cat >"${MANIFEST}" <<YAML
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${NAMESPACE}
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
        - ${POD_CIDR}
    services:
      cidrBlocks:
        - ${SERVICE_CIDR}
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1alpha3
    kind: TalosControlPlane
    name: ${CLUSTER_NAME}-cp
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: HetznerCluster
    name: ${CLUSTER_NAME}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HetznerCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${NAMESPACE}
spec:
  controlPlaneRegions:
    - ${REGION}
  controlPlaneLoadBalancer:
    enabled: true
    type: ${LB_TYPE}
    region: ${REGION}
    algorithm: round_robin
    port: 6443
  controlPlaneEndpoint:
    host: ""
    port: 6443
  hetznerSecretRef:
    name: ${HETZNER_SECRET}
    key:
      hcloudToken: hcloud
  sshKeys:
    hcloud:
      - name: ${SSH_KEY_NAME}
---
apiVersion: controlplane.cluster.x-k8s.io/v1alpha3
kind: TalosControlPlane
metadata:
  name: ${CLUSTER_NAME}-cp
  namespace: ${NAMESPACE}
spec:
  replicas: ${CP_REPLICAS}
  version: ${KUBERNETES_VERSION}
  infrastructureTemplate:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: HCloudMachineTemplate
    name: ${CLUSTER_NAME}-cp-mt
  controlPlaneConfig:
    controlplane:
      generateType: controlplane
      talosVersion: ${TALOS_VERSION}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HCloudMachineTemplate
metadata:
  name: ${CLUSTER_NAME}-cp-mt
  namespace: ${NAMESPACE}
spec:
  template:
    spec:
      type: ${CP_MACHINE_TYPE}
      imageName: ${TALOS_IMAGE_NAME}
      sshKeys:
        - name: ${SSH_KEY_NAME}
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: ${CLUSTER_NAME}-workers
  namespace: ${NAMESPACE}
spec:
  clusterName: ${CLUSTER_NAME}
  replicas: ${WORKER_REPLICAS}
  selector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: ${CLUSTER_NAME}
  template:
    metadata:
      labels:
        cluster.x-k8s.io/cluster-name: ${CLUSTER_NAME}
    spec:
      clusterName: ${CLUSTER_NAME}
      version: ${KUBERNETES_VERSION}
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1alpha3
          kind: TalosConfigTemplate
          name: ${CLUSTER_NAME}-workers-tct
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: HCloudMachineTemplate
        name: ${CLUSTER_NAME}-workers-mt
---
apiVersion: bootstrap.cluster.x-k8s.io/v1alpha3
kind: TalosConfigTemplate
metadata:
  name: ${CLUSTER_NAME}-workers-tct
  namespace: ${NAMESPACE}
spec:
  template:
    spec:
      generateType: worker
      talosVersion: ${TALOS_VERSION}
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HCloudMachineTemplate
metadata:
  name: ${CLUSTER_NAME}-workers-mt
  namespace: ${NAMESPACE}
spec:
  template:
    spec:
      type: ${WORKER_MACHINE_TYPE}
      imageName: ${TALOS_IMAGE_NAME}
      sshKeys:
        - name: ${SSH_KEY_NAME}
YAML

echo "✅ Manifest genererat: ${MANIFEST}"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "🔍 Dry run — applicerar inte. Kör utan DRY_RUN=true för att applicera."
  exit 0
fi

echo "🚀 Applicerar manifest..."
kubectl apply -f "${MANIFEST}"

echo ""
echo "⏳ Följ provisioneringen med:"
echo "   clusterctl describe cluster ${CLUSTER_NAME} -n ${NAMESPACE}"
echo "   kubectl get machines -n ${NAMESPACE}"
echo "   kubectl get hetznercluster -n ${NAMESPACE}"
echo ""
echo "🔑 När klustret är klart, hämta credentials och installera Cilium:"
echo "   ./get_credentials.sh"
echo "   KUBECONFIG=${OUTPUT_DIR}/kubeconfig ./install_cilium.sh"
