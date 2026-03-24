#!/usr/bin/env bash

# Skapa en HTTPRoute för headlamp
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: headlamp
  namespace: headlamp
spec:
  parentRefs:
    - name: shared-gateway
      namespace: gateway
  hostnames:
    - headlamp.${CLUSTER_NAME}.${DNS_ZONE}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: headlamp
          port: 80
EOF
