#!/bin/bash
# Deploy descriptor rate limiter demo
#
# Prerequisites:
#   - MaaS deployed with echo backends (run maas-praxis/deploy.sh first)
#   - ghcr.io/nerdalert/praxis:maas-phase2 image pushed
#
# Usage:
#   ./demos/maas-praxis-phase2/deploy-descriptor.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Descriptor Rate Limiter Demo — Deploy ==="
echo ""

# Ensure namespace
oc create namespace llm 2>/dev/null || true
oc label namespace llm istio-injection- 2>/dev/null || true

# Need echo backends from Phase 1 demo
if ! oc -n llm get svc echo-qwen &>/dev/null; then
  echo "ERROR: echo-qwen service not found. Run demos/maas-praxis/deploy.sh first."
  exit 1
fi

# Deploy descriptor limiter manifests
echo "Deploying descriptor limiter manifests..."
oc apply -f "${SCRIPT_DIR}/manifests/descriptor-limiter.yaml"

# Wait for deployment
echo "Waiting for praxis-descriptor..."
oc -n llm rollout status deployment/praxis-descriptor --timeout=120s 2>/dev/null || true

# Patch ConfigMap with ClusterIPs
QWEN_IP=$(oc -n llm get svc echo-qwen -o jsonpath='{.spec.clusterIP}')
MISTRAL_IP=$(oc -n llm get svc echo-mistral -o jsonpath='{.spec.clusterIP}')
echo "Backend IPs: qwen=${QWEN_IP} mistral=${MISTRAL_IP}"

CONFIG=$(oc -n llm get configmap praxis-descriptor-config -o jsonpath='{.data.config\.yaml}')
CONFIG="${CONFIG//QWEN_CLUSTER_IP/$QWEN_IP}"
CONFIG="${CONFIG//MISTRAL_CLUSTER_IP/$MISTRAL_IP}"
printf '%s' "$CONFIG" > /tmp/praxis-descriptor-config.yaml

oc -n llm create configmap praxis-descriptor-config \
  --from-file=config.yaml=/tmp/praxis-descriptor-config.yaml \
  --dry-run=client -o yaml | oc apply -f -
rm -f /tmp/praxis-descriptor-config.yaml

oc -n llm rollout restart deployment/praxis-descriptor
echo "Waiting for praxis-descriptor..."
oc -n llm rollout status deployment/praxis-descriptor --timeout=120s

echo ""
echo "=== Deployed ==="
echo ""
echo "Run: ${SCRIPT_DIR}/validate-descriptor.sh"
