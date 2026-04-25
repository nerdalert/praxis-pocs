#!/bin/bash
# Phase 3A: Validate Praxis-owned auth + rate limiting
#
# Tests the shadow route where Praxis handles auth
# (http_ext_auth → maas-api) and rate limiting (descriptor).
# Kuadrant AuthPolicy and TRLP are configured as pass-through
# on this route — Praxis owns the actual auth/rate-limit
# decisions.
#
# Usage:
#   ./demos/maas-praxis-phase3/validate.sh

set -euo pipefail

GW_HOST=$(kubectl get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')

echo "===================================================================="
echo "PHASE 3A — Praxis-owned auth + rate limiting"
echo "  (Kuadrant policies configured as pass-through)"
echo "===================================================================="
echo "Gateway: ${GW_HOST}"
echo "Shadow route: /praxis-maas/gpt-4o/"
echo ""

PASS=0
FAIL=0

# Mint a MaaS API key via the existing MaaS path
TOKEN=$(oc whoami -t)
KEY=$(curl -sk -X POST "https://${GW_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"phase3-validate","subscription":"gpt-4o-subscription"}' | jq -r '.key // empty')

if [ -z "$KEY" ]; then
  echo "FAIL  could not mint MaaS API key"
  exit 1
fi
echo "MaaS API key: ${KEY:0:20}..."
echo ""

# --- Test 1: Valid key → OpenAI via Praxis auth ---
echo "--- Test 1: Valid MaaS key → Praxis auth → OpenAI ---"
RAW=$(curl -sk -w "\n%{http_code}" --max-time 15 \
  "https://${GW_HOST}/praxis-maas/gpt-4o/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}')
CODE=$(echo "$RAW" | tail -1)
BODY=$(echo "$RAW" | head -n -1)

if [ "$CODE" = "200" ]; then
  echo "$BODY" | jq .
  echo ""
  echo "PASS  valid key via Praxis auth: HTTP ${CODE}"
  PASS=$((PASS + 1))
else
  echo "FAIL  valid key via Praxis auth: expected 200, got ${CODE}"
  FAIL=$((FAIL + 1))
fi

# --- Test 2: Invalid key rejected ---
echo "--- Test 2: Invalid key rejected by Praxis ---"
CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
  "https://${GW_HOST}/praxis-maas/gpt-4o/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-FAKE-INVALID" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}')
if [ "$CODE" = "403" ]; then
  echo "PASS  invalid key rejected: HTTP ${CODE}"
  PASS=$((PASS + 1))
else
  echo "FAIL  invalid key: expected 403, got ${CODE}"
  FAIL=$((FAIL + 1))
fi

# --- Test 3: Missing auth rejected ---
echo "--- Test 3: Missing auth rejected by Praxis ---"
CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
  "https://${GW_HOST}/praxis-maas/gpt-4o/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}')
if [ "$CODE" = "401" ]; then
  echo "PASS  missing auth rejected: HTTP ${CODE}"
  PASS=$((PASS + 1))
else
  echo "FAIL  missing auth: expected 401, got ${CODE}"
  FAIL=$((FAIL + 1))
fi

# --- Test 4: Auth metrics show Praxis validated ---
echo "--- Test 4: /metrics shows Praxis auth decisions ---"
METRICS=$(oc -n llm exec deployment/praxis-phase3 -- \
  wget -qO- --timeout=3 http://127.0.0.1:9901/metrics 2>/dev/null || echo "")

if echo "$METRICS" | grep -q 'praxis_auth_allowed_total'; then
  echo "PASS  /metrics contains praxis_auth_allowed_total"
  PASS=$((PASS + 1))
  echo ""
  echo "Auth metrics:"
  echo "$METRICS" | grep 'praxis_auth' | head -5
else
  echo "FAIL  /metrics missing praxis_auth_allowed_total"
  FAIL=$((FAIL + 1))
fi

# --- Test 5: Rate limit metrics show descriptor decisions ---
echo ""
echo "--- Test 5: /metrics shows descriptor rate limit decisions ---"
if echo "$METRICS" | grep -q 'praxis_rate_limit_decisions_total.*praxis-auth-subscription'; then
  echo "PASS  /metrics contains descriptor rate limit decisions"
  PASS=$((PASS + 1))
  echo ""
  echo "Rate limit metrics:"
  echo "$METRICS" | grep 'praxis_rate_limit' | head -5
else
  echo "FAIL  /metrics missing descriptor rate limit decisions"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "===================================================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "Phase 3A validated: Praxis owns auth (http_ext_auth → maas-api)"
echo "and request-admission (descriptor rate_limit) decisions."
echo ""
echo "Kuadrant wasm/Authorino/Limitador are still mechanically in the"
echo "request path via pass-through policies on maas-default-gateway."
echo "Praxis does not need them — they exist only because the shared"
echo "gateway has gateway-level default-deny policies."
echo ""
echo "This is request-admission only. Token quotas remain Phase 3b."
echo "===================================================================="

[ "$FAIL" -gt 0 ] && exit 1
exit 0
