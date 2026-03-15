# Talos cluster on Hetzner med Cluster API

<!--toc:start-->
## Innehållsförteckning

- [Talos cluster on Hetzner med Cluster API](#talos-cluster-on-hetzner-med-cluster-api)
  - [Innehållsförteckning](#innehållsförteckning)
  - [Arkitekturöversikt](#arkitekturöversikt)
  - [Förutsättningar](#förutsättningar)
    - [Konton och nycklar](#konton-och-nycklar)
    - [Miljövariabler](#miljövariabler)
    - [Verktyg som behövs](#verktyg-som-behövs)
  - [Engångsinställningar](#engångsinställningar)
    - [Skapa Talos-snapshot på Hetzner](#skapa-talos-snapshot-på-hetzner)
  - [Skapa kluster](#skapa-kluster)
    - [1. Skapa lokalt management-kluster](#1-skapa-lokalt-management-kluster)
    - [2. Initiera Cluster API](#2-initiera-cluster-api)
    - [3. Skapa Hetzner credentials-secret](#3-skapa-hetzner-credentials-secret)
    - [4. Generera Talos-konfiguration](#4-generera-talos-konfiguration)
    - [5. Skapa Talos-konfigurationssecrets](#5-skapa-talos-konfigurationssecrets)
    - [6. Skapa klustret](#6-skapa-klustret)
    - [7. Uppdatera DNS](#7-uppdatera-dns)
    - [8. Hämta kubeconfig](#8-hämta-kubeconfig)
    - [9. Installera Cilium CNI](#9-installera-cilium-cni)
  - [Daglig drift](#daglig-drift)
    - [Uppgradera Kubernetes-versionen](#uppgradera-kubernetes-versionen)
    - [Uppgradera Cluster API-providers](#uppgradera-cluster-api-providers)
    - [Rotera Talos-certifikat](#rotera-talos-certifikat)
    - [Ta bort klustret](#ta-bort-klustret)
  - [Felsökning och återställning](#felsökning-och-återställning)
    - [Vanliga felsökningskommandon](#vanliga-felsökningskommandon)
    - [Återskapa management-klustret](#återskapa-management-klustret)
    - [Nyttiga kommandon (snabbreferens)](#nyttiga-kommandon-snabbreferens)
  - [Skala klustret](#skala-klustret)
    - [Skala control plane](#skala-control-plane)
    - [Skala workers (befintlig pool)](#skala-workers-befintlig-pool)
    - [Lägga till en nodpool med annan hårdvara](#lägga-till-en-nodpool-med-annan-hårdvara)
      - [**Steg 1: Generera manifest utan att applicera**](#steg-1-generera-manifest-utan-att-applicera)
      - [**Steg 2: Kopiera ut worker-blocken ur det genererade manifestet**](#steg-2-kopiera-ut-worker-blocken-ur-det-genererade-manifestet)
      - [**Steg 3: Byt namn och lägg till labels**](#steg-3-byt-namn-och-lägg-till-labels)
      - [**Steg 4: Applicera**](#steg-4-applicera)
    - [Styra workloads till en specifik pool](#styra-workloads-till-en-specifik-pool)
    - [Ta bort en nodpool](#ta-bort-en-nodpool)
  - [Anteckningar](#anteckningar)
<!--toc:end-->

---

## Arkitekturöversikt

Det här upplägget använder **Cluster API (CAPI)** för att provisionera ett
Kubernetes-kluster på Hetzner Cloud.

```
┌─────────────────────────────────┐       ┌────────────────────────────────────┐
│       Lokalt (din dator)        │       │         Hetzner Cloud              │
│                                 │       │                                    │
│  ┌──────────────────────────┐   │       │  ┌──────────────────────────────┐  │
│  │  Management-kluster      │   │       │  │  Workload-kluster (Talos)    │  │
│  │  (kind)                  │──────────▶   │                              │  │
│  │                          │   │       │  │  control-plane nodes         │  │
│  │  - Cluster API           │   │       │  │  worker nodes                │  │
│  │  - Hetzner provider      │   │       │  │  load balancer               │  │
│  └──────────────────────────┘   │       │  └──────────────────────────────┘  │
│                                 │       │                                    │
│  kubectl, clusterctl,           │       │  Det faktiska Kubernetes-          │
│  talosctl (körs lokalt)         │       │  klustret dina applikationer       │
│                                 │       │  kör på                            │
└─────────────────────────────────┘       └────────────────────────────────────┘
```

**Management-klustret** är ett tillfälligt lokalt kluster (kind)
vars enda uppgift är att köra Cluster API-kontrollerna som skapar och sköter
workload-klustret på Hetzner.
Det körs bara på din dator och behöver inte vara igång konstant,
men utan det kan du
inte göra ändringar i kluster-resurser via CAPI.

**Workload-klustret** är det riktiga Talos-klustret på Hetzner
som dina applikationer kör på.

---

## Förutsättningar

### Konton och nycklar

- Hetzner API-token
- Hetzner SSH-nyckel (uppladdad till Hetzner)
- DNS-domän för Kubernetes API-endpointen

### Miljövariabler

Exportera dessa innan du kör något:

```bash
export CLUSTER_TOPOLOGY=true
export HCLOUD_TOKEN="<din hetzner-token>"
export SSH_KEY_NAME="<namn på din uppladdade ssh-nyckel>"
export CLUSTER_NAME="capi-hetzner"
export DNS_ZONE="example.com"
export DNS_API_NAME="kubeapi"
```

### Verktyg som behövs

| Verktyg | Syfte |
| --- | --- |
| `clusterctl` | Hanterar Cluster API |
| `cilium` | Installerar/verifierar Cilium CNI |
| `curl` | Commando Line http requests |
| `docker` | Container RunTime på din lokala dator |
| `kind` | Skapar management-klustret lokalt |
| `kubectl` | Kommunicerar med Kubernetes |
| `helm` | Installerar Helm-charts |
| `jq` | JSON-bearbetning |
| `hcloud` | Hetzner CLI |
| `talosctl` | Hanterar Talos-noder |

**Valfria bekvämlighetsverktyg:** `kubectx`, `kubens`

---

## Engångsinställningar

### Skapa Talos-snapshot på Hetzner

Innan du kan skapa ett kluster behöver du en Talos OS-snapshot i ditt Hetzner-konto.
Den används för automatisk installation av servrar.

Se `create_talos_snapshot.md` för instruktioner.

---

## Skapa kluster

Alla `kubectl`-kommandon i det här avsnittet körs **mot management-klustret** om
inget annat anges.

### 1. Skapa lokalt management-kluster

```bash
kind create cluster --name capi-management
```

Verifiera:

```bash
kubectl cluster-info
```

---

### 2. Initiera Cluster API

Installera Cluster API och Hetzner-providern:

```bash
clusterctl init \
  --core cluster-api \
  --infrastructure hetzner \
  --bootstrap talos \
  --control-plane talos
```

Verifiera att alla providers är installerade:

```bash
kubectl get providers -A
```

---

### 3. Skapa Hetzner credentials-secret

```bash
kubectl create secret generic hetzner \
  --from-literal=hcloud="${HCLOUD_TOKEN}" \
  --from-literal=hcloud-ssh-key-name="${SSH_KEY_NAME}" \
  --from-literal=hcloudSSHKey="${SSH_KEY_NAME}" \
  -n default \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl patch secret hetzner -p '{"metadata":{"labels":{"clusterctl.cluster.x-k8s.io/move":""}}}'
```

---

### 4. Generera Talos-konfiguration

```bash
mkdir -p talos-config

talosctl gen config "${CLUSTER_NAME}" \
  https://"${DNS_API_NAME}"."${CLUSTER_NAME}"."${DNS_ZONE}":6443 \
  --output-dir talos-config/"${CLUSTER_NAME}" \
  --with-docs=false \
  --with-examples=false
```

Detta genererar tre filer i nuvarande katalog:

| Fil | Syfte |
| --- | --- |
| `controlplane.yaml` | Konfiguration för control-plane-noder |
| `worker.yaml` | Konfiguration för worker-noder |
| `talosconfig` | Klientkonfiguration för `talosctl` – spara denna säkert |

---

### 5. Skapa Talos-konfigurationssecrets

***obsolete*** dubbelkolla och radera 5.

```bash
kubectl create secret generic ${CLUSTER_NAME}-talos-cp \
  --from-file=talos-config/${CLUSTER_NAME}/controlplane.yaml

kubectl create secret generic ${CLUSTER_NAME}-talos-worker \
  --from-file=talos-config/${CLUSTER_NAME}/worker.yaml
```

---

### 6. Skapa klustret

```bash
./create-cluster.sh
```

Följ förloppet:

```bash
kubectl get cluster,machine -A
```

---

### 7. Uppdatera DNS

Skapa en DNS-post för Kubernetes API-endpointen:

```bash
echo "${DNS_API_NAME}.${CLUSTER_NAME}.${DNS_ZONE}"
```

Peka den på IP-adressen för control plane load balancern på Hetzner.
Du hittar IP-adressen i Hetzner Cloud Console eller via:

```bash
hcloud load-balancer list
```

---

### 8. Hämta kubeconfig

```bash
clusterctl get kubeconfig ${CLUSTER_NAME} -n default > talos-config/${CLUSTER_NAME}/kubeconfig
```

Använd workload-klustret:

```bash
export KUBECONFIG=talos-config/${CLUSTER_NAME}/kubeconfig
kubectl get nodes
```

> Från och med nu kör du `kubectl` mot **workload-klustret på Hetzner**,
> inte mot management-klustret.

---

### 9. Installera Cilium CNI

```bash
./install_cilium.sh
```

Verifiera (mot workload-klustret):

```bash
kubectl get pods -n kube-system
```

---

## Daglig drift

### Uppgradera Kubernetes-versionen

Redigera Kubernetes-versionen i kluster-manifestet:

```yaml
spec:
  topology:
    version: v1.30.2
```

Applicera ändringen (mot management-klustret):

```bash
kubectl apply -f cluster.yaml
```

Följ utrullningen:

```bash
kubectl get machines
kubectl get nodes -w
```

---

### Uppgradera Cluster API-providers

Kontrollera tillgängliga uppgraderingar:

```bash
clusterctl upgrade plan
```

Genomför uppgraderingen:

```bash
clusterctl upgrade apply
```

Verifiera provider-versioner:

```bash
kubectl get providers -A
```

---

### Rotera Talos-certifikat

Talos-certifikat gäller normalt ett år. Kontrollera utgångsdatum:

```bash
talosctl -n <node-ip> get certs
```

> **Obs:** `rotate-ca` roterar CA-certifikaten för hela klustret – det är en ingripande
> operation som påverkar alla noder. Planera en underhållsperiod och se till att du har
> tillgång till `talosconfig` och backup innan du kör.

```bash
talosctl rotate-ca
```

Starta om Talos-tjänster vid behov:

```bash
talosctl service restart kubelet
```

---

### Ta bort klustret

Ta bort workload-klustret via Cluster API (kör mot management-klustret):

```bash
kubectl delete cluster ${CLUSTER_NAME}
```

Följ borttagningen – infrastrukturen på Hetzner tas bort automatiskt:

```bash
kubectl get machines -A
```

---

## Felsökning och återställning

### Vanliga felsökningskommandon

```bash
# Kontrollera Cluster API-resurser (management-kluster)
kubectl get clusters -A
kubectl get machines -A
kubectl get machinedeployments -A

# Detaljinfo om en specifik maskin
kubectl describe machine <machine-name>

# Kontrollera att alla pods kör
kubectl get pods -A

# Loggar från Hetzner-providern
kubectl logs -n caph-system deploy/caph-controller-manager

# Loggar från CAPI-kärnan
kubectl logs -n capi-system deploy/capi-controller-manager
```

---

### Återskapa management-klustret

Om det lokala management-klustret hamnar i ett dåligt tillstånd kan du
återskapa det utan att påverka workload-klustret på Hetzner.

Ta bort det befintliga kind-klustret:

```bash
kind delete cluster --name capi-management
```

Skapa ett nytt:

```bash
kind create cluster --name capi-management
```

Initiera Cluster API igen (samma kommandon som vid första installation):

```bash
clusterctl init \
  --core cluster-api \
  --infrastructure hetzner \
  --bootstrap talos \
  --control-plane talos
```

Återanslut till det befintliga workload-klustret:

```bash
clusterctl get kubeconfig ${CLUSTER_NAME} -n default
```

---

### Nyttiga kommandon (snabbreferens)

```bash
# Visa provider-versioner
kubectl get providers -A

# Kontrollera klusterstatus
kubectl get cluster

# Bevaka maskiner
watch kubectl get machines

# Bevaka noder (workload-kluster)
watch kubectl get nodes
```

---

## Skala klustret

Alla kommandon körs mot **management-klustret**.

### Skala control plane

Control plane bör alltid ha ett udda antal noder (1, 3, 5) för att etcd ska ha kvorum.
Ändra `CP_REPLICAS` och applicera om manifestet:

```bash
CP_REPLICAS=5 ./create-cluster.sh
```

Det scriptet gör är att uppdatera `replicas` i `TalosControlPlane`-resursen.
Du kan göra samma sak manuellt:

```bash
kubectl patch taloscontrolplane ${CLUSTER_NAME}-cp \
  -n default \
  --type merge \
  -p '{"spec":{"replicas":5}}'
```

Följ utrullningen:

```bash
kubectl get machines -n default
```

---

### Skala workers (befintlig pool)

Ändra antalet workers i den befintliga poolen:

```bash
WORKER_REPLICAS=5 ./create-cluster.sh
```

Det scriptet gör är att uppdatera `replicas` i `MachineDeployment`-resursen.
Du kan göra samma sak manuellt på två sätt:

```bash
# Via kubectl scale
kubectl scale machinedeployment ${CLUSTER_NAME}-workers \
  --replicas=5 \
  -n default

# Via patch (samma som scale men explicit)
kubectl patch machinedeployment ${CLUSTER_NAME}-workers \
  -n default \
  --type merge \
  -p '{"spec":{"replicas":5}}'
```

---

### Lägga till en nodpool med annan hårdvara

Scriptet skapar en worker-pool per körning. För att lägga till en extra pool – t.ex.
minnesoptimerad eller med mycket disk – generera ett nytt manifest med `DRY_RUN=true`,
plocka ut worker-blocken och applicera dem separat.

#### **Steg 1: Generera manifest utan att applicera**

```bash
WORKER_MACHINE_TYPE=m1.xlarge \
WORKER_REPLICAS=2 \
DRY_RUN=true \
./create-cluster.sh
```

#### **Steg 2: Kopiera ut worker-blocken ur det genererade manifestet**

De tre resurser du behöver är:

- `MachineDeployment`
- `TalosConfigTemplate`
- `HCloudMachineTemplate`

#### **Steg 3: Byt namn och lägg till labels**

Döp om resurserna så de inte krockar med den befintliga poolen, t.ex. `capi-hetzner-workers-memory`,
och sätt ett `node-pool`-label på noderna så att workloads kan styras dit:

```yaml
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: capi-hetzner-workers-memory
  namespace: default
spec:
  clusterName: capi-hetzner
  replicas: 2
  selector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: capi-hetzner
  template:
    metadata:
      labels:
        cluster.x-k8s.io/cluster-name: capi-hetzner
        node-pool: memory
    spec:
      clusterName: capi-hetzner
      version: v1.35.0
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1alpha3
          kind: TalosConfigTemplate
          name: capi-hetzner-workers-memory-tct
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: HCloudMachineTemplate
        name: capi-hetzner-workers-memory-mt
---
apiVersion: bootstrap.cluster.x-k8s.io/v1alpha3
kind: TalosConfigTemplate
metadata:
  name: capi-hetzner-workers-memory-tct
  namespace: default
spec:
  template:
    spec:
      generateType: worker
      talosVersion: v1.12.4
      data: |
        # samma innehåll som i worker.yaml
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HCloudMachineTemplate
metadata:
  name: capi-hetzner-workers-memory-mt
  namespace: default
spec:
  template:
    spec:
      type: m1.xlarge       # minnesoptimerad servertyp på Hetzner
      imageName: talos-v1.12.4
      sshKeys:
        - name: hcloudSSHKey
```

#### **Steg 4: Applicera**

```bash
kubectl apply -f workers-memory.yaml
```

Verifiera att noderna dyker upp:

```bash
kubectl get nodes --show-labels
```

---

### Styra workloads till en specifik pool

När noderna har labels kan du styra dit workloads med `nodeSelector` i din deployment:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        node-pool: memory
```

---

### Ta bort en nodpool

```bash
kubectl delete machinedeployment capi-hetzner-workers-memory -n default
kubectl delete talosconfigtemplate capi-hetzner-workers-memory-tct -n default
kubectl delete hcloudmachinetemplate capi-hetzner-workers-memory-mt -n default
```

CAPI tömmer noderna och tar bort servrarna på Hetzner automatiskt.

---

## Anteckningar

- Management-klustret körs **lokalt** med kind och behöver bara vara
igång när du gör ändringar via CAPI
- Workload-klustret körs på **Hetzner Cloud** och är oberoende av att
management-klustret är uppe
- All infrastruktur hanteras via **Cluster API** – undvik att göra manuella
ändringar direkt i Hetzner Cloud Console
