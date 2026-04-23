#!/bin/bash
# Praxis + MaaS full integration validation
#
# Tests:
#   - Praxis BBR replacement route (body-based model routing)
#   - Praxis provider gateway route (external model egress)
#   - MaaS gpt-4o route (existing auth + subscription flow)
#
# Usage:
#   ./scripts/validate-all.sh

set -euo pipefail

GW_HOST=$(kubectl get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}')
echo "Gateway: $GW_HOST"
echo ""

PASS=0
FAIL=0
SKIP=0

check() {
  local name="$1" expect_code="$2" expect_body="${3:-}"
  shift 3
  local response code body
  response=$(curl -sk -w "\n%{http_code}" "$@" 2>&1)
  code=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -n -1)

  if [ "$code" = "$expect_code" ]; then
    if [ -n "$expect_body" ] && ! echo "$body" | grep -q "$expect_body"; then
      echo "FAIL  ${name}: HTTP ${code} but body missing '${expect_body}'"
      FAIL=$((FAIL + 1))
      return
    fi
    echo "PASS  ${name}: HTTP ${code}"
    PASS=$((PASS + 1))
  else
    echo "FAIL  ${name}: expected ${expect_code}, got ${code}"
    FAIL=$((FAIL + 1))
  fi
}

check_json() {
  local name="$1" expect_code="$2" jq_expr="$3"
  shift 3
  local response code body
  response=$(curl -sk -w "\n%{http_code}" "$@" 2>&1)
  code=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -n -1)

  if [ "$code" != "$expect_code" ]; then
    echo "FAIL  ${name}: expected ${expect_code}, got ${code}"
    FAIL=$((FAIL + 1))
    return
  fi

  if ! echo "$body" | jq -e "$jq_expr" >/dev/null 2>&1; then
    echo "FAIL  ${name}: HTTP ${code} but JSON check failed: ${jq_expr}"
    echo "       body: $body"
    FAIL=$((FAIL + 1))
    return
  fi

  echo "PASS  ${name}: HTTP ${code}"
  PASS=$((PASS + 1))
}

# --------------------------------------------------------------------------
# Demo 1: BBR Replacement — body-based model routing
# --------------------------------------------------------------------------

PRAXIS_TOKEN=$(oc create token default -n llm \
  --audience=maas-default-gateway-sa 2>/dev/null || true)

if [ -z "$PRAXIS_TOKEN" ]; then
  echo "SKIP  Praxis route tests (could not create audience-scoped token)"
  SKIP=$((SKIP + 1))
else
  echo "===================================================================="
  echo "DEMO 1: BBR REPLACEMENT — body-based model routing"
  echo "===================================================================="
  echo ""

  check_json "model=qwen routes to qwen backend and forwards body" 200 \
    '.model == "qwen" and .forwarded_model == "qwen" and .forwarded_prompt == "hello"' \
    "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Authorization: Bearer ${PRAXIS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

  check_json "model=mistral routes to mistral backend and forwards body" 200 \
    '.model == "mistral" and .forwarded_model == "mistral" and .forwarded_prompt == "hello"' \
    "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Authorization: Bearer ${PRAXIS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"mistral","messages":[{"role":"user","content":"hello"}]}'

  check_json "no model field falls through to default and still forwards body" 200 \
    '.model == "qwen" and .forwarded_model == null and .forwarded_prompt == "hello"' \
    "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Authorization: Bearer ${PRAXIS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"hello"}]}'

  check "no auth returns 401" 401 "" \
    "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

  check "bogus token returns 401" 401 "" \
    "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Authorization: Bearer randomgarbage" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

  # Health check
  HEALTH=$(oc -n llm exec deployment/praxis -- \
    wget -qO- --timeout=3 http://127.0.0.1:9901/ready 2>/dev/null || echo "UNREACHABLE")
  if echo "$HEALTH" | grep -q '"status":"ok"'; then
    echo "PASS  admin /ready returns ok"
    PASS=$((PASS + 1))
  else
    echo "FAIL  admin /ready: ${HEALTH}"
    FAIL=$((FAIL + 1))
  fi

  echo ""
fi

# --------------------------------------------------------------------------
# Demo 2: Model Routing Gateway — external provider
# --------------------------------------------------------------------------

if oc -n llm get deployment praxis-gateway &>/dev/null; then
  echo "===================================================================="
  echo "DEMO 2: MODEL ROUTING GATEWAY — external provider"
  echo "===================================================================="
  echo ""

  PRAXIS_TOKEN=${PRAXIS_TOKEN:-$(oc create token default -n llm \
    --audience=maas-default-gateway-sa 2>/dev/null || true)}

  check "chat completion via Praxis → OpenAI" 200 "chat.completion" \
    "https://${GW_HOST}/praxis-gw/v1/chat/completions" \
    -H "Authorization: Bearer ${PRAXIS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}'

  check "provider route no auth returns 401" 401 "" \
    "https://${GW_HOST}/praxis-gw/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hello"}]}'

  echo ""
else
  echo "SKIP  Demo 2 (praxis-gateway deployment not found)"
  SKIP=$((SKIP + 1))
fi

# --------------------------------------------------------------------------
# MaaS gpt-4o route (existing stack)
# --------------------------------------------------------------------------

echo "===================================================================="
echo "MAAS GPT-4O ROUTE — existing auth + subscription flow"
echo "===================================================================="
echo ""

TOKEN=$(oc whoami -t)

KEY=$(curl -sk -X POST "https://${GW_HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"validate-all","subscription":"gpt-4o-subscription"}' | jq -r '.key // empty')

if [ -z "$KEY" ]; then
  echo "SKIP  MaaS gpt-4o tests (could not mint API key)"
  SKIP=$((SKIP + 1))
else
  echo "MaaS key: ${KEY:0:20}..."
  echo ""

  check "valid key, correct path" 200 "chat.completion" \
    "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $KEY" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}'

  check "bogus sk-oai- key" 403 "" \
    "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer sk-oai-FAKE-KEY-12345" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'

  check "random token" 401 "" \
    "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer randomgarbage" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'

  check "no auth" 401 "" \
    "https://${GW_HOST}/llm/gpt-4o/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'

  check "header injection attempt" 401 "" \
    "https://${GW_HOST}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer FAKE" \
    -H "X-Gateway-Model-Name: gpt-4o" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'
fi

echo ""
echo "===================================================================="
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "===================================================================="
