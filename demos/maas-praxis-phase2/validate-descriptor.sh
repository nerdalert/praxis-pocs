#!/bin/bash
# Validate descriptor rate limiter on cluster
#
# Tests:
#   1. Same descriptor allowed within burst
#   2. Same descriptor rejected after burst
#   3. Different descriptor still passes
#   4. Missing descriptor rejected
#   5. /metrics exposes rate limit decisions
#
# This validates LOCAL request-count limiting only.
# It does NOT validate token quotas, distributed state,
# or Limitador replacement beyond request-count controls.
#
# Usage:
#   ./demos/maas-praxis-phase2/validate-descriptor.sh

set -euo pipefail

GW_HOST=$(kubectl get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
TOKEN=$(oc create token default -n llm --audience=maas-default-gateway-sa)

echo "===================================================================="
echo "DESCRIPTOR RATE LIMITER — local request-count limiting"
echo "===================================================================="
echo "Gateway: ${GW_HOST}"
echo ""

PASS=0
FAIL=0

send() {
  local sub="$1" model="$2"
  local args=(-sk -w "\n%{http_code}" --max-time 10)
  args+=("https://${GW_HOST}/praxis-desc/v1/chat/completions/")
  args+=(-H "Authorization: Bearer ${TOKEN}")
  args+=(-H "Content-Type: application/json")
  [ -n "$sub" ] && args+=(-H "X-MaaS-Subscription: ${sub}")
  [ -n "$model" ] && args+=(-H "X-AI-Model: ${model}")
  args+=(-d '{"model":"'"${model:-qwen}"'","messages":[{"role":"user","content":"hello"}]}')
  curl "${args[@]}" 2>&1
}

get_code() {
  echo "$1" | tail -1
}

check() {
  local name="$1" expect="$2" actual="$3"
  if [ "$actual" = "$expect" ]; then
    echo "PASS  ${name}: HTTP ${actual}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  ${name}: expected ${expect}, got ${actual}"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 1: First request with descriptor allowed ---
echo "--- Test 1: Same descriptor allowed within burst ---"
RESP=$(send "free" "qwen")
CODE=$(get_code "$RESP")
check "free/qwen first request (allow)" "200" "$CODE"

# --- Test 2: Same descriptor rejected after burst ---
echo "--- Test 2: Same descriptor rejected after burst ---"
RESP=$(send "free" "qwen")
CODE=$(get_code "$RESP")
check "free/qwen second request (deny)" "429" "$CODE"

# --- Test 3: Different descriptor still passes ---
echo "--- Test 3: Different descriptor gets own bucket ---"
RESP=$(send "premium" "qwen")
CODE=$(get_code "$RESP")
check "premium/qwen first request (allow)" "200" "$CODE"

# --- Test 4: Different model same subscription ---
echo "--- Test 4: Different model gets own bucket ---"
RESP=$(send "free" "mistral")
CODE=$(get_code "$RESP")
check "free/mistral first request (allow)" "200" "$CODE"

# --- Test 5: Missing descriptor rejected ---
echo "--- Test 5: Missing descriptor rejected ---"
RESP=$(send "" "")
CODE=$(get_code "$RESP")
check "missing descriptor (reject)" "429" "$CODE"

# --- Test 6: Check /metrics ---
echo ""
echo "--- Test 6: /metrics exposes rate limit decisions ---"
METRICS=$(oc -n llm exec deployment/praxis-descriptor -- \
  wget -qO- --timeout=3 http://127.0.0.1:9901/metrics 2>/dev/null || echo "")

if echo "$METRICS" | grep -q 'praxis_rate_limit_decisions_total'; then
  echo "PASS  /metrics contains praxis_rate_limit_decisions_total"
  PASS=$((PASS + 1))
  echo ""
  echo "Rate limit metrics:"
  echo "$METRICS" | grep 'praxis_rate_limit_decisions_total' | head -10
else
  echo "FAIL  /metrics missing praxis_rate_limit_decisions_total"
  FAIL=$((FAIL + 1))
fi

# --- Test 7: Check Praxis logs for decision metadata ---
echo ""
echo "--- Test 7: Praxis logs show policy decisions ---"
LOGS=$(oc -n llm logs deployment/praxis-descriptor --tail=10 2>&1)
if echo "$LOGS" | grep -q 'rate_limit'; then
  echo "PASS  logs contain rate_limit entries"
  PASS=$((PASS + 1))
else
  echo "FAIL  logs missing rate_limit entries"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "===================================================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "NOTE: This validates local request-count limiting only."
echo "      Limitador token quotas remain separate until token"
echo "      counting + shared state are implemented."
echo "===================================================================="

[ "$FAIL" -gt 0 ] && exit 1
exit 0
