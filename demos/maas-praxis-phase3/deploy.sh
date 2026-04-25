#!/bin/bash
# Phase 3A: Deploy Praxis with inline auth + rate limiting
#
# Praxis owns auth + rate limiting on the shadow route.
# Auth via http_ext_auth → maas-api. Kuadrant AuthPolicy
# and TRLP are configured as pass-through to allow MaaS
# API keys through the shared gateway's default-deny.
#
# Usage:
#   OPENAI_API_KEY='sk-...' ./demos/maas-praxis-phase3/deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "ERROR: OPENAI_API_KEY is not set"
  exit 1
fi

echo "===================================================================="
echo "Phase 3A: Praxis-owned auth + rate limiting"
echo "===================================================================="
echo ""

oc create namespace llm 2>/dev/null || true
oc label namespace llm istio-injection- 2>/dev/null || true

# Deploy shadow route (no Kuadrant auth/TRLP enforcement)
echo "--- Deploying shadow route ---"
oc apply -f "${SCRIPT_DIR}/manifests/shadow-route.yaml"

# Deploy Praxis Phase 3 config
echo "--- Deploying Praxis Phase 3 ---"
oc apply -f "${SCRIPT_DIR}/manifests/praxis-phase3.yaml"

# Inject API key
echo "--- Injecting provider credentials ---"
CONFIG=$(oc -n llm get configmap praxis-phase3-config -o jsonpath='{.data.config\.yaml}')
CONFIG="${CONFIG//OPENAI_API_KEY_PLACEHOLDER/$OPENAI_API_KEY}"
printf '%s' "$CONFIG" > /tmp/praxis-phase3-config.yaml

oc -n llm create configmap praxis-phase3-config \
  --from-file=config.yaml=/tmp/praxis-phase3-config.yaml \
  --dry-run=client -o yaml | oc apply -f -
rm -f /tmp/praxis-phase3-config.yaml

oc -n llm rollout restart deployment/praxis-phase3
echo "--- Waiting for Praxis Phase 3 ---"
oc -n llm rollout status deployment/praxis-phase3 --timeout=120s

echo ""
echo "===================================================================="
echo "Deployed. Validate with: ${SCRIPT_DIR}/validate.sh"
echo "===================================================================="
