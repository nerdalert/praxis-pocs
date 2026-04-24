#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== BBR Replacement Demo ==="
echo ""

# Ensure namespace without Istio sidecar injection
oc create namespace llm 2>/dev/null || true
oc label namespace llm istio-injection- 2>/dev/null || true

# Deploy manifests (backends + praxis + route + policies)
echo "Deploying manifests..."
oc apply -f "${SCRIPT_DIR}/manifests.yaml"

# Wait for backends
echo "Waiting for mock backends..."
oc -n llm rollout status deployment/echo-qwen --timeout=120s
oc -n llm rollout status deployment/echo-mistral --timeout=120s

# Patch ConfigMap with real ClusterIPs (Praxis requires IP:port, not DNS)
QWEN_IP=$(oc -n llm get svc echo-qwen -o jsonpath='{.spec.clusterIP}')
MISTRAL_IP=$(oc -n llm get svc echo-mistral -o jsonpath='{.spec.clusterIP}')
echo "Backend IPs: qwen=${QWEN_IP} mistral=${MISTRAL_IP}"

oc -n llm get configmap praxis-config -o jsonpath='{.data.config\.yaml}' \
  | sed "s/QWEN_CLUSTER_IP/${QWEN_IP}/g" \
  | sed "s/MISTRAL_CLUSTER_IP/${MISTRAL_IP}/g" \
  > /tmp/praxis-config-resolved.yaml

oc -n llm create configmap praxis-config \
  --from-file=config.yaml=/tmp/praxis-config-resolved.yaml \
  --dry-run=client -o yaml | oc apply -f -
rm -f /tmp/praxis-config-resolved.yaml

# Restart Praxis with resolved config
oc -n llm rollout restart deployment/praxis
echo "Waiting for Praxis..."
oc -n llm rollout status deployment/praxis --timeout=120s

echo ""
echo "=== Deployed ==="
echo ""
echo "Run: ${SCRIPT_DIR}/validate.sh"
