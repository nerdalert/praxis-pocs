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

## What Praxis replaces

| MaaS Component | What it does | Praxis replacement | Status |
|---|---|---|---|
| ext-proc gRPC sidecar | Separate process for body inspection | Eliminated — Praxis does it inline | **Done** |
| EnvoyFilter for ext-proc | Wires ext-proc into Envoy | Eliminated — not needed | **Done** |
| body-field-to-header plugin | Extracts `model` from JSON body → header | `model_to_header` filter | **Done** (Demo 1) |
| model-provider-resolver plugin | Maps model name → provider endpoint | `router` filter (static config) | **Done** (Demo 2) |
| apikey-injection plugin | Injects provider API key | `request_set` filter | **Done** (Demo 2) |
| ExternalName Service | DNS-based routing to api.openai.com | Praxis upstream TLS with DNS resolution | **Done** (Demo 2) |
| Envoy upstream routing | Routes to backend by header | `router` + `load_balancer` | **Done** |

## What still needs work

| Issue | Detail | Fix needed |
|---|---|---|
| StreamBuffer + external TLS | `model_to_header` (body inspection) + external provider in the same request path causes "Connection reset by peer" from Cloudflare. Likely chunked encoding mismatch after StreamBuffer releases the body. | Debug Pingora's body forwarding after StreamBuffer pre-read. Workaround: split body inspection and provider routing into separate demos (current approach). |
| api-translation plugin | Praxis can't translate between provider API schemas (e.g. OpenAI → Anthropic format) | New feature — not started |
| Secret-backed credentials | API key is currently hardcoded in the ConfigMap, not sourced from a K8s Secret | New feature — needs Secret mount + injection |
| MaaS gpt-4o route (404) | Not a Praxis bug — ext-proc isn't deployed because Praxis replaces it. The existing MaaS model route has no body processor. | Deploy ext-proc alongside if you want both paths, or migrate the gpt-4o route to Praxis |

**TLDR:** Praxis replaces 6 of 7 ext-proc/BBR components. The two demos work end-to-end — body-based model routing (Demo 1) and real OpenAI provider egress (Demo 2). The one gap is combining body inspection with external TLS in a single request path, which needs a StreamBuffer fix.

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
(requires [`feat/dns-and-request-headers`](https://github.com/nerdalert/praxis/tree/feat/dns-and-request-headers) branch features):

```bash
$ curl -sk "https://${GW_HOST}/praxis-gw/v1/chat/completions" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":5}'

{
  "id": "chatcmpl-DXJwnCft3MKgNR35EFhmWfuAljan2",
  "object": "chat.completion",
  "model": "gpt-4o-2024-08-06",
  "choices": [{
    "message": {"role": "assistant", "content": "Understood."},
    "finish_reason": "stop"
  }],
  "usage": {"prompt_tokens": 14, "completion_tokens": 3, "total_tokens": 17}
}
```

## Prerequisites

- MaaS deployed with `maas-default-gateway`
- `oc` authenticated as cluster admin
- `ghcr.io/nerdalert/praxis:maas-dev` image (public)
