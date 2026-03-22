# Talos cluster på Hetzner med Cluster API

## Innehållsförteckning

- [Arkitekturöversikt](#arkitekturöversikt)
- [Förutsättningar](#förutsättningar)
- [Engångsinställningar](#engångsinställningar)
- [Skapa kluster](#skapa-kluster)
- [Daglig drift](#daglig-drift)
- [Felsökning och återställning](#felsökning-och-återställning)
- [Skala klustret](#skala-klustret)
- [Anteckningar](#anteckningar)

---

## Arkitekturöversikt

Det här upplägget använder **Cluster API (CAPI)** för att provisionera ett
Kubernetes-kluster på Hetzner Cloud.

```txt
┌─────────────────────────────────┐       ┌────────────────────────────────────┐
│       Lokalt (din dator)        │       │         Hetzner Cloud              │
│                                 │       │                                    │
│  ┌──────────────────────────┐   │       │  ┌──────────────────────────────┐  │
│  │  Management-kluster      │   │       │  │  Workload-kluster (Talos)    │  │
│  │  (kind)                  │───────────▶  │                              │  │
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

**Management-klustret** är ett tillfälligt lokalt kluster (kind) vars enda uppgift
är att köra Cluster API-kontrollerna som skapar och sköter workload-klustret på
Hetzner. Det körs bara på din dator och behöver inte vara igång konstant, men utan
det kan du inte göra ändringar i kluster-resurser via CAPI.

**Workload-klustret** är det riktiga Talos-klustret på Hetzner som dina
applikationer kör på.

---

## Förutsättningar

### Konton och nycklar

- Hetzner API-token
- Hetzner SSH-nyckel (uppladdad till Hetzner)
- DNS-domän för Kubernetes API-endpointen

### Miljövariabler

Exportera dessa innan du kör något:

```bash
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
| `docker` | Container runtime på din lokala dator |
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

kubectl patch secret hetzner \
  -n default \
  -p '{"metadata":{"labels":{"clusterctl.cluster.x-k8s.io/move":""}}}'
```

---

### 4. Skapa workload-klustret

CAPI genererar automatiskt alla Talos-secrets och certifikat vid bootstrap.
Du behöver inte generera någon konfiguration manuellt.

> **Obs:** Talos installerar Flannel som standard-CNI. Det tas bort automatiskt
> av `install_cilium.sh` i steg 7.

Visa tillgängliga variabler:

```bash
./create_cluster.sh -h
```

Skapa klustret:

```bash
# Exempel: litet testkluster
CP_REPLICAS=1 WORKER_REPLICAS=1 ./create_cluster.sh
```

Följ förloppet:

```bash
clusterctl describe cluster ${CLUSTER_NAME} -n default
kubectl get cluster,machine -A
hcloud load-balancer list
```

---

### 5. Uppdatera DNS

Skapa en DNS-post för Kubernetes API-endpointen:

```bash
# Namnet som ska pekas ut
echo "${DNS_API_NAME}.${CLUSTER_NAME}.${DNS_ZONE}"
```

Peka den på IP-adressen för control plane load balancern på Hetzner:

```bash
hcloud load-balancer list
```

---

### 6. Hämta credentials

När klustret är uppe hämtar du `talosconfig` och `kubeconfig` med:

```bash
./get_credentials.sh
```

Filerna sparas i `talos-config/${CLUSTER_NAME}/` och kan när som helst återhämtas
från Kubernetes så länge management-klustret är uppe.

Använd workload-klustret:

```bash
export KUBECONFIG=talos-config/${CLUSTER_NAME}/kubeconfig
kubectl get nodes
```

> Från och med nu kör du `kubectl` mot **workload-klustret på Hetzner**,
> inte mot management-klustret.

Använd talosctl:

```bash
export TALOSCONFIG=talos-config/${CLUSTER_NAME}/talosconfig
talosctl get members
```

---

### 7. Installera Cilium CNI

`install_cilium.sh` tar bort Flannel och installerar Cilium via Helm med
WireGuard-kryptering och Hubble aktiverat.

```bash
./install_cilium.sh
```

Verifiera krypteringsstatus (mot workload-klustret):

```bash
for pod in $(kubectl get pods -n cilium-system -l k8s-app=cilium -o name); do
  echo "=== $pod ==="
  kubectl exec -n cilium-system $pod -- cilium encrypt status
done
```

Du bör se `Encryption: Wireguard` med en peer per övrig nod.

---

## Daglig drift

### Hemligheter i management-klustret

CAPI skapar och hanterar följande secrets automatiskt:

| Secret | Typ | Skapad av | Syfte |
| --- | --- | --- | --- |
| `hetzner` | Opaque | Manuellt (steg 3) | Hetzner API-token och SSH-nyckelnamn. Används av Hetzner-providern för att skapa och ta bort servrar och load balancers. |
| `${CLUSTER_NAME}-ca` | Opaque | CAPI automatiskt | Kubernetes CA-certifikat för workload-klustret. Signerar kubeconfig och hanterar kommunikation mellan Kubernetes-komponenter. |
| `${CLUSTER_NAME}-kubeconfig` | cluster.x-k8s.io/secret | CAPI automatiskt | kubectl-klientkonfiguration för workload-klustret. Hämtas med `get_credentials.sh`. |
| `${CLUSTER_NAME}-talos` | Opaque | CAPI automatiskt | Talos interna kluster-secrets – CA, bootstrap-token och krypteringsnycklar för etcd. Källan till sanningen för Talos-certifikaten på noderna. |
| `${CLUSTER_NAME}-talosconfig` | Opaque | CAPI automatiskt | talosctl-klientkonfiguration, signerad med CA:t från `${CLUSTER_NAME}-talos`. Hämtas med `get_credentials.sh`. |
| `${CLUSTER_NAME}-<machine-id>-bootstrap-data` | Opaque | CAPI automatiskt | Engångsdata per nod vid första boot. Innehåller Talos machine config för en specifik nod. Blir irrelevant efter att noden bootstrappats. |

---

### Uppgradera Kubernetes-versionen

Kör om scriptet med ny version – det uppdaterar manifestet och applicerar det:

```bash
KUBERNETES_VERSION=v1.32.0 ./create_cluster.sh
```

Följ utrullningen (mot management-klustret):

```bash
kubectl get machines -n default
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
talosctl get certs -n <node-ip>
```

> **Obs:** `rotate-ca` roterar CA-certifikaten för hela klustret – det är en
> ingripande operation som påverkar alla noder. Planera en underhållsperiod och
> se till att du har tillgång till `talosconfig` och backup innan du kör.

```bash
talosctl rotate-ca
```

Hämta ny `talosconfig` efter rotation:

```bash
./get_credentials.sh
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
# Övergripande klusterstatus (management-kluster)
clusterctl describe cluster ${CLUSTER_NAME} -n default

# Kontrollera Cluster API-resurser
kubectl get clusters,machines,machinedeployments -A

# Detaljinfo om en specifik maskin
kubectl describe machine <machine-name>

# Kontrollera att alla pods kör
kubectl get pods -A

# Loggar från Hetzner-providern
kubectl logs -n caph-system deploy/caph-controller-manager

# Loggar från CAPI-kärnan
kubectl logs -n capi-system deploy/capi-controller-manager

# Talos-status direkt mot en nod
talosctl services -n <node-ip>
talosctl dmesg -n <node-ip>
```

---

### Återskapa management-klustret

Om det lokala management-klustret hamnar i ett dåligt tillstånd kan du återskapa
det utan att påverka workload-klustret på Hetzner.

Ta bort det befintliga kind-klustret:

```bash
kind delete cluster --name capi-management
```

Skapa ett nytt och initiera Cluster API:

```bash
kind create cluster --name capi-management

clusterctl init \
  --core cluster-api \
  --infrastructure hetzner \
  --bootstrap talos \
  --control-plane talos
```

Återskapa Hetzner credentials-secret (steg 3 ovan), hämta sedan tillbaka
credentials för workload-klustret:

```bash
./get_credentials.sh
```

---

### Nyttiga kommandon (snabbreferens)

```bash
# Visa provider-versioner
kubectl get providers -A

# Kontrollera klusterstatus
kubectl get cluster -A

# Bevaka maskiner
watch kubectl get machines -A

# Bevaka noder (workload-kluster)
watch kubectl get nodes
```

---

## Skala klustret

Alla kommandon körs mot **management-klustret**.

### Skala control plane

Control plane bör alltid ha ett udda antal noder (1, 3, 5) för att etcd ska ha kvorum.

Kör om scriptet med nytt antal – det uppdaterar `TalosControlPlane`-resursen:

```bash
CP_REPLICAS=5 ./create_cluster.sh
```

Eller patcha direkt utan att generera om manifestet:

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

Kör om scriptet med nytt antal – det uppdaterar `MachineDeployment`-resursen:

```bash
WORKER_REPLICAS=5 ./create_cluster.sh
```

Eller patcha direkt:

```bash
# Via kubectl scale
kubectl scale machinedeployment ${CLUSTER_NAME}-workers \
  --replicas=5 \
  -n default

# Via patch
kubectl patch machinedeployment ${CLUSTER_NAME}-workers \
  -n default \
  --type merge \
  -p '{"spec":{"replicas":5}}'
```

---

### Lägga till en nodpool med annan hårdvara

Scriptet skapar en worker-pool per körning. För att lägga till en extra pool –
t.ex. minnesoptimerad eller med mycket disk – generera ett nytt manifest med
`DRY_RUN=true`, plocka ut worker-blocken och applicera dem separat.

#### Steg 1: Generera manifest utan att applicera

```bash
WORKER_MACHINE_TYPE=m1.xlarge \
WORKER_REPLICAS=2 \
DRY_RUN=true \
./create_cluster.sh
```

#### Steg 2: Kopiera ut worker-blocken ur det genererade manifestet

De tre resurser du behöver är `MachineDeployment`, `TalosConfigTemplate`
och `HCloudMachineTemplate`.

#### Steg 3: Byt namn och lägg till labels

Döp om resurserna så de inte krockar med den befintliga poolen och sätt ett
`node-pool`-label så att workloads kan styras dit:

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
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HCloudMachineTemplate
metadata:
  name: capi-hetzner-workers-memory-mt
  namespace: default
spec:
  template:
    spec:
      type: m1.xlarge
      imageName: talos-v1.12.4
      sshKeys:
        - name: hcloudSSHKey
```

#### Steg 4: Applicera

```bash
kubectl apply -f workers-memory.yaml
```

Verifiera att noderna dyker upp:

```bash
kubectl get nodes --show-labels
```

---

### Styra workloads till en specifik pool

När noderna har labels kan du styra dit workloads med `nodeSelector`:

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

- Management-klustret körs **lokalt** med kind och behöver bara vara igång när
du gör ändringar via CAPI
- Workload-klustret körs på **Hetzner Cloud** och är oberoende av att
management-klustret är uppe
- CAPI genererar och hanterar alla Talos-secrets automatiskt – du behöver inte
generera någon konfiguration manuellt
- Talos installerar **Flannel** som standard-CNI – det ersätts av **Cilium** med
WireGuard-kryptering när `install_cilium.sh` körs
- All infrastruktur hanteras via **Cluster API** – undvik att göra manuella
ändringar direkt i Hetzner Cloud Console
