#!/usr/bin/env bash
set -euo pipefail

# Ephemeral Gitea installation via the official Helm chart (no PVC).
# - Namespace: gitea
# - Admin credentials are managed in a Secret (created if missing)
# - Uses SQLite by default
# - persistence.enabled=false (uses emptyDir)
# - Creates 'app-of-apps' repository via a post-install Job

NS="gitea"
RELEASE="gitea"
CHART_REPO_NAME="gitea-charts"
CHART_REPO_URL="https://dl.gitea.com/charts/"
CHART="${CHART_REPO_NAME}/gitea"

SERVICE_NAME="gitea"
HTTP_PORT=3000
SSH_PORT=2222

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl not found in PATH"
  exit 1
}
command -v helm >/dev/null 2>&1 || {
  echo "helm not found in PATH"
  exit 1
}

# 1) Namespace
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# 2) Admin credentials Secret (create if absent)
if ! kubectl -n "${NS}" get secret gitea-admin >/dev/null 2>&1; then
  ADMIN_PASS="$(head -c 24 /dev/urandom | base64 -w 0)"
  kubectl -n "${NS}" create secret generic gitea-admin \
    --from-literal=admin-username=admin \
    --from-literal=admin-password="${ADMIN_PASS}"
  echo "Created Secret ${NS}/gitea-admin with admin credentials."
else
  echo "Secret ${NS}/gitea-admin already exists; reusing admin credentials."
fi

# Resolve admin creds from Secret (authoritative source)
ADMIN_USER="$(kubectl -n "${NS}" get secret gitea-admin -o jsonpath='{.data.admin-username}' | base64 -d)"
ADMIN_PASS="$(kubectl -n "${NS}" get secret gitea-admin -o jsonpath='{.data.admin-password}' | base64 -d)"

# 3) Install/upgrade via Helm (ephemeral)
helm repo add "${CHART_REPO_NAME}" "${CHART_REPO_URL}" >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install "${RELEASE}" "${CHART}" \
  --namespace "${NS}" \
  --create-namespace \
  -f - <<VALUES
gitea:
  admin:
    username: "${ADMIN_USER}"
    password: "${ADMIN_PASS}"
  config:
    server:
      ROOT_URL: "http://${SERVICE_NAME}.${NS}.svc.cluster.local:${HTTP_PORT}/"
      SSH_DOMAIN: "${SERVICE_NAME}.${NS}.svc.cluster.local"
      START_SSH_SERVER: true
      SSH_PORT: ${SSH_PORT}
    database:
      DB_TYPE: sqlite3
      PATH: /data/gitea/gitea.db
    cache:
      ADAPTER: memory
    session:
      PROVIDER: memory
    queue:
      TYPE: channel

service:
  http:
    type: ClusterIP
    port: ${HTTP_PORT}
  ssh:
    type: ClusterIP
    port: ${SSH_PORT}

persistence:
  enabled: false

postgresql-ha:
  enabled: false
# Also keep single-postgres disabled just in case
postgresql:
  enabled: false

# Disable Valkey/Redis subcharts
valkey:
  enabled: false
valkey-cluster:
  enabled: false
memcached:
  enabled: false
VALUES

# 4) Post-install Job to create 'app-of-apps' repository
kubectl -n "${NS}" delete job gitea-create-app-of-apps --ignore-not-found
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: gitea-create-app-of-apps
  namespace: ${NS}
spec:
  backoffLimit: 6
  activeDeadlineSeconds: 300
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: create-repo
          image: curlimages/curl:8.11.1
          imagePullPolicy: IfNotPresent
          env:
            - name: GITEA_BASE
              value: "http://${SERVICE_NAME}-http.${NS}.svc.cluster.local:${HTTP_PORT}"
            - name: GITEA_ADMIN_USER
              valueFrom:
                secretKeyRef:
                  name: gitea-admin
                  key: admin-username
            - name: GITEA_ADMIN_PASS
              valueFrom:
                secretKeyRef:
                  name: gitea-admin
                  key: admin-password
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              i=1
              while [ "\$i" -le 60 ]; do
                if curl -fsS "\$GITEA_BASE/api/healthz" >/dev/null; then
                  break
                fi
                sleep 2
                i=\$((i + 1))
              done
              if curl -fsS -u "\$GITEA_ADMIN_USER:\$GITEA_ADMIN_PASS" \
                   "\$GITEA_BASE/api/v1/repos/\$GITEA_ADMIN_USER/app-of-apps" >/dev/null; then
                echo "Repository app-of-apps already exists."
                exit 0
              fi
              curl -fsS \
                -u "\$GITEA_ADMIN_USER:\$GITEA_ADMIN_PASS" \
                -H "Content-Type: application/json" \
                -d '{"name":"app-of-apps","private":false}' \
                -X POST \
                "\$GITEA_BASE/api/v1/user/repos"
              echo "Created repository app-of-apps."
EOF

# 5) Wait for Job completion (service readiness is polled within the Job)
kubectl -n "${NS}" wait --for=condition=complete job/gitea-create-app-of-apps --timeout=300s

# 6) Output connection info and credentials
echo
echo "Ephemeral Gitea (Helm) is ready."
echo "HTTP URL:  http://${SERVICE_NAME}.${NS}.svc.cluster.local:${HTTP_PORT}"
echo "SSH URL:   ssh://git@${SERVICE_NAME}.${NS}.svc.cluster.local:${SSH_PORT}"
echo "Admin credentials: ${ADMIN_USER} / ${ADMIN_PASS}"
echo "Repo URLs:"
echo "  HTTPS: http://${SERVICE_NAME}.${NS}.svc.cluster.local:${HTTP_PORT}/${ADMIN_USER}/app-of-apps.git"
echo "  SSH:   ssh://git@${SERVICE_NAME}.${NS}.svc.cluster.local:${SSH_PORT}/${ADMIN_USER}/app-of-apps.git"
echo "NOTE: Repositories are stored in memory and will be lost if the Pod restarts."
