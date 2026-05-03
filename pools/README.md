
# Worker pools (CAPI/Talos/Hetzner)

Reusable worker pools for a Cluster API cluster on Hetzner.
Pattern: one MachineDeployment + TalosConfigTemplate + HCloudMachineTemplate per pool.

- general: no taints (default landing zone)
- compute/storage: tainted with `dedicated=<pool>:NoSchedule`
- Autoscaler annotations are pre-added (min 0, max 10) and safely ignored until Cluster Autoscaler is installed.

## Prerequisites

- Context: management cluster (kind) — same as when running create_cluster.sh.
- Tools: kubectl, envsubst.
- Ensure the script is executable:
  - chmod +x pools/poolctl.sh
- Export env (match your cluster):
  - export CLUSTER_NAME=<your-cluster>
  - export NAMESPACE=default
  - export KUBERNETES_VERSION=v1.35.0
  - export TALOS_VERSION=v1.12.4
  - export TALOS_IMAGE_NAME=talos-v1.12.4
  - export SSH_KEY_NAME=hcloudSSHKey

## Create pools

If you want to reuse the same talos-image,
check MACHINE_TYPE on installed servers,
`hcloud server describe <server-name>`

Check available MACHINE_TYPE:
`hcloud server-type list`

Verify the location and cpu type.

- General (no taints):
  - POOL=general MACHINE_TYPE=cpx31 REPLICAS=2 ./poolctl.sh apply
- Compute (tainted):
  - POOL=compute MACHINE_TYPE=ccx32 REPLICAS=0 TAINTED=true ./poolctl.sh apply
- Storage (tainted):
  - POOL=storage MACHINE_TYPE=cpx51 REPLICAS=0 TAINTED=true ./poolctl.sh apply

## Scale a pool

- POOL=compute REPLICAS=3 ./poolctl.sh scale

## Delete a pool

- POOL=compute ./poolctl.sh delete

## Render (dry-run)

- POOL=general MACHINE_TYPE=cpx31 REPLICAS=2 ./poolctl.sh render | less

## Scheduling workloads

- General pool (no taints) requires no changes.
- Compute/storage pools require nodeSelector + toleration:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        node-pool: compute
      tolerations:
        - key: "dedicated"
          value: "compute"
          effect: "NoSchedule"
