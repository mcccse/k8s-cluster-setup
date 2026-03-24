#!/usr/bin/env bash

# Skapa en HTTPRoute för headlamp
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: headlamp
  namespace: headlamp
spec:
  parentRefs:
    - name: shared-gateway
      namespace: gateway
      sectionName: http
  hostnames:
    - headlamp.${CLUSTER_NAME}.${DNS_ZONE}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: headlamp-https
  namespace: headlamp
spec:
  parentRefs:
    - name: shared-gateway
      namespace: gateway
      sectionName: https
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
