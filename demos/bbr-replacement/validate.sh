#!/bin/bash
set -euo pipefail

GW_HOST=$(oc -n openshift-ingress get gateway maas-default-gateway \
  -o jsonpath='{.spec.listeners[0].hostname}')
TOKEN=$(oc create token default -n llm --audience=maas-default-gateway-sa)

echo "=== BBR Replacement Demo — Validation ==="
echo "Gateway: ${GW_HOST}"
echo ""

PASS=0
FAIL=0

check_contains() {
  local name="$1" expect_code="$2" expect_body="${3:-}"
  shift 3
  local response code body
  response=$(curl -sk -w "\n%{http_code}" "$@")
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
  response=$(curl -sk -w "\n%{http_code}" "$@")
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

# --- Model routing tests ---

check_json "model=qwen routes to qwen backend and forwards body" 200 \
  '.model == "qwen" and .forwarded_model == "qwen" and .forwarded_prompt == "hello"' \
  "https://${GW_HOST}/praxis/v1/chat/completions/" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

check_json "model=mistral routes to mistral backend and forwards body" 200 \
  '.model == "mistral" and .forwarded_model == "mistral" and .forwarded_prompt == "hello"' \
  "https://${GW_HOST}/praxis/v1/chat/completions/" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral","messages":[{"role":"user","content":"hello"}]}'

check_json "no model field falls through to default and still forwards body" 200 \
  '.model == "qwen" and .forwarded_model == null and .forwarded_prompt == "hello"' \
  "https://${GW_HOST}/praxis/v1/chat/completions/" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hello"}]}'

# --- Auth tests ---

check_contains "no auth returns 401" 401 "" \
  "https://${GW_HOST}/praxis/v1/chat/completions/" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

check_contains "bogus token returns 401" 401 "" \
  "https://${GW_HOST}/praxis/v1/chat/completions/" \
  -H "Authorization: Bearer fake-token" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

# --- Health check ---

HEALTH=$(oc -n llm exec deployment/praxis -- \
  wget -qO- --timeout=3 http://127.0.0.1:9901/ready 2>/dev/null || echo "UNREACHABLE")
if echo "$HEALTH" | grep -q '"status":"ok"'; then
  echo "PASS  admin /ready returns ok"
  PASS=$((PASS + 1))
else
  echo "FAIL  admin /ready: ${HEALTH}"
  FAIL=$((FAIL + 1))
fi

# --- Praxis logs ---

echo ""
echo "=== Recent Praxis access logs ==="
oc -n llm logs deployment/praxis --tail=10 2>&1 | grep access || echo "(no access logs)"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
