#!/bin/bash
# Phase 3B: Validate clean Gateway — no Kuadrant in request path
#
# Proves Praxis handles auth + rate limiting without any
# Kuadrant/Authorino/Limitador components in the request path.
#
# Success criteria:
#   1. HTTP 200 from OpenAI through clean gateway
#   2. Praxis auth metrics increment
#   3. Praxis rate-limit metrics increment
#   4. No AuthPolicy targets clean route/gateway
#   5. No TRLP targets clean route/gateway
#   6. Limitador counters do not increment for clean route
#
# Usage:
#   ./demos/maas-praxis-phase3/validate-clean-gateway.sh

set -euo pipefail

# Discover hosts
CLEAN_HOST=$(oc get gateway praxis-clean-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null || echo "")

if [ -z "$CLEAN_HOST" ]; then
  echo "ERROR: praxis-clean-gateway not found"
  echo "       Run deploy-clean-gateway.sh first"
  exit 1
fi

MAAS_HOST=$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')

# Detect protocol — clean gateway uses HTTP (port 80)
CLEAN_PROTO="http"
CLEAN_PORT=$(oc get gateway praxis-clean-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].port}' 2>/dev/null || echo "80")
if [ "$CLEAN_PORT" = "443" ]; then
  CLEAN_PROTO="https"
fi

# The clean gateway gets its own LoadBalancer with a different ELB/IP
# than the wildcard *.apps DNS. Resolve the gateway's actual address
# so curl hits the right ingress controller.
CLEAN_LB=$(oc get gateway praxis-clean-gateway -n openshift-ingress \
  -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo "")
RESOLVE_FLAG=""
if [ -n "$CLEAN_LB" ] && [ "$CLEAN_LB" != "$CLEAN_HOST" ]; then
  # Resolve the LB hostname to an IP for --resolve
  LB_IP=$(host "$CLEAN_LB" 2>/dev/null | awk '/has address/{print $NF; exit}' || echo "")
  if [ -n "$LB_IP" ]; then
    RESOLVE_FLAG="--resolve ${CLEAN_HOST}:${CLEAN_PORT}:${LB_IP}"
    echo "NOTE: Clean gateway has its own LB (${CLEAN_LB})"
    echo "      Using --resolve to direct traffic to ${LB_IP}"
  else
    echo "WARNING: Could not resolve clean gateway LB: ${CLEAN_LB}"
    echo "         DNS may not have propagated yet. Trying direct hostname."
  fi
fi

echo "===================================================================="
echo "PHASE 3B — Clean Gateway validation (no Kuadrant in path)"
echo "===================================================================="
echo "Clean gateway:  ${CLEAN_HOST} (${CLEAN_PROTO})"
echo "MaaS gateway:   ${MAAS_HOST} (key minting)"
echo ""

PASS=0
FAIL=0

# --- Test 1: No AuthPolicy targets clean resources ---
echo "--- Test 1: No AuthPolicy targets clean resources ---"
AUTH_TARGETS=$(oc get authpolicy -A -o json 2>/dev/null | \
  jq -r '.items[] | select(.spec.targetRef.name == "praxis-clean-phase3" or .spec.targetRef.name == "praxis-clean-gateway") | .metadata.namespace + "/" + .metadata.name' 2>/dev/null || echo "")

if [ -z "$AUTH_TARGETS" ]; then
  echo "PASS  No AuthPolicy targets clean resources"
  PASS=$((PASS + 1))
else
  echo "FAIL  AuthPolicy targets clean resources: ${AUTH_TARGETS}"
  FAIL=$((FAIL + 1))
fi

# --- Test 2: No TRLP targets clean resources ---
echo "--- Test 2: No TRLP targets clean resources ---"
TRLP_TARGETS=$(oc get tokenratelimitpolicy -A -o json 2>/dev/null | \
  jq -r '.items[] | select(.spec.targetRef.name == "praxis-clean-phase3" or .spec.targetRef.name == "praxis-clean-gateway") | .metadata.namespace + "/" + .metadata.name' 2>/dev/null || echo "")

if [ -z "$TRLP_TARGETS" ]; then
  echo "PASS  No TRLP targets clean resources"
  PASS=$((PASS + 1))
else
  echo "FAIL  TRLP targets clean resources: ${TRLP_TARGETS}"
  FAIL=$((FAIL + 1))
fi

# Snapshot Praxis metrics before test
echo ""
echo "--- Snapshotting Praxis metrics before test ---"
METRICS_BEFORE=$(oc -n llm exec deployment/praxis-phase3 -- \
  wget -qO- --timeout=3 http://127.0.0.1:9901/metrics 2>/dev/null || echo "")

AUTH_ALLOWED_BEFORE=$(echo "$METRICS_BEFORE" | \
  grep 'praxis_auth_allowed_total' | grep -oP '\d+$' || echo "0")
RATE_LIMIT_BEFORE=$(echo "$METRICS_BEFORE" | \
  grep 'praxis_rate_limit_decisions_total.*decision="allow"' | grep -oP '\d+$' || echo "0")

echo "  praxis_auth_allowed_total before: ${AUTH_ALLOWED_BEFORE}"
echo "  praxis_rate_limit allow before:   ${RATE_LIMIT_BEFORE}"

# Mint a MaaS API key via the existing MaaS path
echo ""
echo "--- Minting MaaS API key via existing gateway ---"
TOKEN=$(oc whoami -t)
KEY=$(curl -sk -X POST "https://${MAAS_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"clean-gateway-test","subscription":"gpt-4o-subscription"}' | jq -r '.key // empty')

if [ -z "$KEY" ]; then
  echo "FAIL  Could not mint MaaS API key"
  exit 1
fi
echo "MaaS API key: ${KEY:0:20}..."
echo ""

# --- Test 3: Valid key → Praxis via clean gateway → OpenAI ---
echo "--- Test 3: Valid MaaS key → clean gateway → Praxis → OpenAI ---"
RAW=$(curl -sk -w "\n%{http_code}" --max-time 15 \
  $RESOLVE_FLAG \
  "${CLEAN_PROTO}://${CLEAN_HOST}/praxis-maas/gpt-4o/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}')
CODE=$(echo "$RAW" | tail -1)
BODY=$(echo "$RAW" | head -n -1)

if [ "$CODE" = "200" ]; then
  echo "$BODY" | jq .
  echo ""
  echo "PASS  Valid key via clean gateway: HTTP ${CODE}"
  PASS=$((PASS + 1))
else
  echo "FAIL  Valid key via clean gateway: expected 200, got ${CODE}"
  echo "Body: ${BODY}"
  FAIL=$((FAIL + 1))
fi

# --- Test 4: Invalid key rejected ---
echo "--- Test 4: Invalid key rejected via clean gateway ---"
CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
  $RESOLVE_FLAG \
  "${CLEAN_PROTO}://${CLEAN_HOST}/praxis-maas/gpt-4o/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-FAKE-INVALID" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}')
if [ "$CODE" = "403" ]; then
  echo "PASS  Invalid key rejected: HTTP ${CODE}"
  PASS=$((PASS + 1))
else
  echo "FAIL  Invalid key: expected 403, got ${CODE}"
  FAIL=$((FAIL + 1))
fi

# --- Test 5: Missing auth rejected ---
echo "--- Test 5: Missing auth rejected via clean gateway ---"
CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
  $RESOLVE_FLAG \
  "${CLEAN_PROTO}://${CLEAN_HOST}/praxis-maas/gpt-4o/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}')
if [ "$CODE" = "401" ]; then
  echo "PASS  Missing auth rejected: HTTP ${CODE}"
  PASS=$((PASS + 1))
else
  echo "FAIL  Missing auth: expected 401, got ${CODE}"
  FAIL=$((FAIL + 1))
fi

# --- Test 6: Praxis auth metrics incremented ---
echo ""
echo "--- Test 6: Praxis auth metrics incremented ---"
METRICS_AFTER=$(oc -n llm exec deployment/praxis-phase3 -- \
  wget -qO- --timeout=3 http://127.0.0.1:9901/metrics 2>/dev/null || echo "")

AUTH_ALLOWED_AFTER=$(echo "$METRICS_AFTER" | \
  grep 'praxis_auth_allowed_total' | grep -oP '\d+$' || echo "0")

if [ "$AUTH_ALLOWED_AFTER" -gt "$AUTH_ALLOWED_BEFORE" ]; then
  echo "PASS  praxis_auth_allowed_total incremented: ${AUTH_ALLOWED_BEFORE} → ${AUTH_ALLOWED_AFTER}"
  PASS=$((PASS + 1))
else
  echo "FAIL  praxis_auth_allowed_total did not increment: ${AUTH_ALLOWED_BEFORE} → ${AUTH_ALLOWED_AFTER}"
  FAIL=$((FAIL + 1))
fi

# --- Test 7: Praxis rate-limit metrics incremented ---
echo "--- Test 7: Praxis rate-limit metrics incremented ---"
RATE_LIMIT_AFTER=$(echo "$METRICS_AFTER" | \
  grep 'praxis_rate_limit_decisions_total.*decision="allow"' | grep -oP '\d+$' || echo "0")

if [ "$RATE_LIMIT_AFTER" -gt "$RATE_LIMIT_BEFORE" ]; then
  echo "PASS  praxis_rate_limit allow incremented: ${RATE_LIMIT_BEFORE} → ${RATE_LIMIT_AFTER}"
  PASS=$((PASS + 1))
else
  echo "FAIL  praxis_rate_limit allow did not increment: ${RATE_LIMIT_BEFORE} → ${RATE_LIMIT_AFTER}"
  FAIL=$((FAIL + 1))
fi

# --- Test 8: Limitador has no counters for clean route ---
echo ""
echo "--- Test 8: Limitador has no counters for clean route ---"
echo "  (Checking if Limitador shows activity for praxis-clean)"

# Check Limitador metrics via exec (curl available in limitador pod)
LIMITADOR_METRICS=$(oc -n kuadrant-system exec deployment/limitador-limitador -- \
  curl -s --max-time 3 http://127.0.0.1:8080/metrics 2>/dev/null || echo "UNAVAILABLE")

if [ "$LIMITADOR_METRICS" = "UNAVAILABLE" ]; then
  echo "FAIL  Could not reach Limitador metrics"
  FAIL=$((FAIL + 1))
else
  if echo "$LIMITADOR_METRICS" | grep -q "praxis.clean"; then
    echo "FAIL  Limitador has counters referencing praxis-clean:"
    echo "$LIMITADOR_METRICS" | grep "praxis.clean" | head -5
    FAIL=$((FAIL + 1))
  else
    echo "PASS  No Limitador counters reference praxis-clean"
    PASS=$((PASS + 1))
    echo ""
    echo "  Limitador namespaces with praxis activity (shadow route only):"
    echo "$LIMITADOR_METRICS" | grep "praxis" | head -5 || echo "  (none)"
  fi
fi

echo ""
echo "===================================================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "Phase 3B validated: Praxis handles auth + rate limiting"
  echo "through a clean Gateway with NO Kuadrant policies attached."
  echo ""
  echo "No AuthPolicy, no TokenRateLimitPolicy, no Kuadrant wasm,"
  echo "no Authorino, no Limitador in the request path."
else
  echo "Phase 3B validation incomplete — see failures above."
fi
echo ""
echo "Rollback:"
echo "  oc delete httproute praxis-clean-phase3 -n llm"
echo "  oc delete gateway praxis-clean-gateway -n openshift-ingress"
echo "===================================================================="

[ "$FAIL" -gt 0 ] && exit 1
exit 0
