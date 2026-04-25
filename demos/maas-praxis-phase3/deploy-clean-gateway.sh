#!/bin/bash
# Phase 3B: Deploy clean Gateway — no Kuadrant policies
#
# Creates a dedicated Gateway + HTTPRoute to praxis-phase3
# with NO AuthPolicy and NO TokenRateLimitPolicy attached.
# Proves Praxis can operate without Kuadrant in the path.
#
# Prerequisites:
#   - praxis-phase3 deployment already running (deploy.sh)
#   - maas-default-gateway exists (for cluster domain discovery)
#
# Rollback:
#   oc delete httproute praxis-clean-phase3 -n llm
#   oc delete gateway praxis-clean-gateway -n openshift-ingress
#
# Usage:
#   ./demos/maas-praxis-phase3/deploy-clean-gateway.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "===================================================================="
echo "Phase 3B: Deploy clean Gateway (no Kuadrant policies)"
echo "===================================================================="
echo ""

# Discover cluster domain from existing gateway hostname
# e.g. maas.apps.cluster.example.com → apps.cluster.example.com
MAAS_HOST=$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')

if [ -z "$MAAS_HOST" ]; then
  echo "ERROR: Could not discover hostname from maas-default-gateway"
  exit 1
fi

# Strip the first label (e.g. "maas") to get the cluster domain
CLUSTER_DOMAIN="${MAAS_HOST#*.}"
CLEAN_HOST="praxis-clean.${CLUSTER_DOMAIN}"

echo "MaaS gateway host:  ${MAAS_HOST}"
echo "Cluster domain:     ${CLUSTER_DOMAIN}"
echo "Clean gateway host:  ${CLEAN_HOST}"
echo ""

# Verify praxis-phase3 deployment exists
if ! oc -n llm get deployment praxis-phase3 &>/dev/null; then
  echo "ERROR: praxis-phase3 deployment not found in llm namespace"
  echo "       Run deploy.sh first to deploy Praxis Phase 3"
  exit 1
fi

# Template and apply the clean gateway manifest
echo "--- Deploying clean Gateway + HTTPRoute ---"
sed "s/CLUSTER_DOMAIN/${CLUSTER_DOMAIN}/g" \
  "${SCRIPT_DIR}/manifests/clean-gateway.yaml" | oc apply -f -

# Wait for gateway to be accepted
echo "--- Waiting for Gateway to be accepted ---"
for i in $(seq 1 30); do
  STATUS=$(oc get gateway praxis-clean-gateway -n openshift-ingress \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null || echo "")
  if [ "$STATUS" = "True" ]; then
    echo "Gateway accepted"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "WARNING: Gateway not yet accepted after 30s (may still be provisioning)"
  fi
  sleep 1
done

# Verify no Kuadrant policies target the clean resources
echo ""
echo "--- Verifying no Kuadrant policies target clean resources ---"

AUTH_TARGETS=$(oc get authpolicy -A -o json 2>/dev/null | \
  jq -r '.items[] | select(.spec.targetRef.name == "praxis-clean-phase3" or .spec.targetRef.name == "praxis-clean-gateway") | .metadata.namespace + "/" + .metadata.name' 2>/dev/null || echo "")

TRLP_TARGETS=$(oc get tokenratelimitpolicy -A -o json 2>/dev/null | \
  jq -r '.items[] | select(.spec.targetRef.name == "praxis-clean-phase3" or .spec.targetRef.name == "praxis-clean-gateway") | .metadata.namespace + "/" + .metadata.name' 2>/dev/null || echo "")

if [ -n "$AUTH_TARGETS" ]; then
  echo "WARNING: AuthPolicy targets clean resources: ${AUTH_TARGETS}"
  echo "         This defeats the purpose of the clean gateway test"
else
  echo "PASS  No AuthPolicy targets praxis-clean-gateway or praxis-clean-phase3"
fi

if [ -n "$TRLP_TARGETS" ]; then
  echo "WARNING: TokenRateLimitPolicy targets clean resources: ${TRLP_TARGETS}"
  echo "         This defeats the purpose of the clean gateway test"
else
  echo "PASS  No TRLP targets praxis-clean-gateway or praxis-clean-phase3"
fi

echo ""
echo "===================================================================="
echo "Deployed. Clean gateway host: ${CLEAN_HOST}"
echo ""
echo "Validate with:"
echo "  ${SCRIPT_DIR}/validate-clean-gateway.sh"
echo ""
echo "Rollback with:"
echo "  oc delete httproute praxis-clean-phase3 -n llm"
echo "  oc delete gateway praxis-clean-gateway -n openshift-ingress"
echo "===================================================================="
