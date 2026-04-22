# Praxis Demos

Demonstrations of Praxis replacing components in the MaaS
(Models-as-a-Service) gateway stack.

## What Praxis replaces

Praxis is an AI-native proxy that performs body-aware
routing inline, eliminating the need for external
processing sidecars.

### Current MaaS routing stack

```
Client → Envoy → Wasm (kuadrant auth)
→ ext_proc (gRPC) → payload-processing
  ├── body-field-to-header (model extraction)
  ├── model-provider-resolver
  ├── api-translation
  └── apikey-injection
→ Envoy routes by X-Gateway-Model-Name → backend
```

### With Praxis

```
Client → Gateway → Praxis
  ├── model_to_header  (native, inline)
  ├── router           (header-based route match)
  └── load_balancer    (endpoint selection + TLS)
→ backend
```

No ext-proc hop. No gRPC sidecar. No Wasm shim.

## Component replacement matrix

| Current Component | Praxis Replacement | Status |
|---|---|---|
| ext_proc gRPC service | eliminated | Done |
| EnvoyFilter for ext_proc | eliminated | Done |
| body-field-to-header plugin | `model_to_header` filter | Done |
| model-provider-resolver plugin | `router` filter (static config) | Done (static) |
| Envoy upstream routing | `router` + `load_balancer` | Done |
| Envoy upstream TLS | Praxis upstream TLS | Done |
| api-translation plugin | not yet implemented | Blocked |
| apikey-injection plugin | `request_add` (partial) | Needs `request_set` |
| Host header rewrite | not yet implemented | Needs `request_set` |

## Demos

### [bbr-replacement](bbr-replacement/)

**Status: Working**

Praxis replaces the BBR/ext-proc pipeline for model
extraction and routing to mock backends. Proves native
body-aware routing without external processing.

### [model-routing-gateway](model-routing-gateway/)

**Status: Working** (requires [`feat/dns-and-request-headers`](https://github.com/nerdalert/praxis/tree/feat/dns-and-request-headers) branch)

Praxis as the direct model-routing proxy to a real
external provider (OpenAI). Praxis resolves DNS for
the upstream, establishes TLS, and uses `request_set`
to rewrite Host and inject provider credentials.

## Deployment

Each demo has its own `deploy.sh` and `validate.sh`:

```bash
# BBR replacement (works now)
./demos/bbr-replacement/deploy.sh
./demos/bbr-replacement/validate.sh

# Model routing gateway (needs request_set)
export OPENAI_API_KEY='sk-...'
./demos/model-routing-gateway/deploy.sh
./demos/model-routing-gateway/validate.sh
```

## Validation

### Demo 1: BBR Replacement — model-based routing

Get a token and the gateway hostname:

```bash
GW_HOST=$(oc -n openshift-ingress get gateway maas-default-gateway \
  -o jsonpath='{.spec.listeners[0].hostname}')
TOKEN=$(oc create token default -n llm --audience=maas-default-gateway-sa)
```

Route to qwen backend by model field in request body:

```bash
$ curl -sk "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

{"id":"chatcmpl-demo","object":"chat.completion","model":"qwen","choices":[{"message":{"role":"assistant","content":"hello from qwen backend (routed by Praxis)"}}]}
```

Route to mistral backend by changing the model field:

```bash
$ curl -sk "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"mistral","messages":[{"role":"user","content":"hello"}]}'

{"id":"chatcmpl-demo","object":"chat.completion","model":"mistral","choices":[{"message":{"role":"assistant","content":"hello from mistral backend (routed by Praxis)"}}]}
```

Unauthenticated requests are rejected by the gateway:

```bash
$ curl -sk -w "HTTP %{http_code}" "https://${GW_HOST}/praxis/v1/chat/completions/" \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen","messages":[{"role":"user","content":"hello"}]}'

HTTP 401
```

Praxis access logs show the routing decision:

```
access method=POST path=/praxis/v1/chat/completions/ status=200 cluster="qwen"  request_body_bytes=63
access method=POST path=/praxis/v1/chat/completions/ status=200 cluster="mistral" request_body_bytes=66
```

### Demo 2: Model Routing Gateway — external provider

Route to a real OpenAI endpoint through Praxis
(requires `feat/dns-and-request-headers` branch features):

```bash
$ curl -sk "https://${GW_HOST}/praxis-gw/v1/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}'

# Expected when working:
{"id":"chatcmpl-...","object":"chat.completion","model":"gpt-4o",...}

# Current status: POST with body hits StreamBuffer/chunked-transfer
# issue with Cloudflare. GET requests proxy successfully.
```

## Prerequisites

- MaaS deployed with `maas-default-gateway`
- `oc` authenticated as cluster admin
- `ghcr.io/nerdalert/praxis:maas-dev` image (public)
