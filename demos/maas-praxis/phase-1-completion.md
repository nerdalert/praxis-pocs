# Phase 1 Completion — ext-proc/BBR Replacement

## Objective

Replace the ext-proc/BBR body-processing pipeline with
Praxis for inline body-aware routing, credential
injection, and provider egress.

## Result

**Complete.** All validation passing on production MaaS
cluster.

## Capabilities Delivered

| Capability | How it works | Validated |
|---|---|---|
| Body-based model extraction | `model_to_header` reads JSON body via StreamBuffer, promotes `model` field to header | Yes — echo backends verify body arrives intact |
| Model-based routing | `router` matches promoted header → selects cluster | Yes — qwen/mistral route correctly |
| Provider credential injection | `request_set` overwrites Authorization header with provider API key | Yes — OpenAI accepts the swapped key |
| Host header rewrite | `request_set` overwrites Host for Cloudflare/provider routing | Yes — no duplicate Host rejection |
| Path normalization | `path_rewrite` strips `/llm/gpt-4o` and `/praxis-gw` prefixes | Yes — OpenAI receives `/v1/chat/completions` |
| DNS resolution for upstreams | `ToSocketAddrs` fallback in `upstream_peer.rs` | Yes — resolves `api.openai.com:443` |
| Upstream TLS with SNI | Pingora TLS connection with configurable SNI | Yes — Cloudflare accepts the connection |
| StreamBuffer body replay | All chunks buffered + Pingora initial-send fix | Yes — upstream receives complete body |
| MaaS API key auth flow | MaaS key minted → Authorino validates → Praxis routes | Yes — full subscription flow works |
| In-cluster model support | LLMInferenceService via KServe (not through Praxis) | Yes — facebook/opt-125m simulator works |

## Test Results

```
validate-all.sh:             13 passed, 0 failed
validate-maas-path-gpt.sh:    8 passed, 0 failed
validate-maas-all-models.sh:  7 passed, 0 failed
```

## Components Eliminated

```
BEFORE:
  Client → Envoy → Kuadrant wasm → Authorino → Limitador
    → ext-proc (gRPC) → payload-processing pod
      ├── body-field-to-header
      ├── model-provider-resolver
      ├── api-translation
      └── apikey-injection
    → Envoy routes → ExternalName Service → provider

AFTER:
  Client → Envoy → Kuadrant wasm → Authorino → Limitador
    → Praxis (inline)
      ├── model_to_header (StreamBuffer)
      ├── path_rewrite
      ├── request_set (Host + Auth)
      ├── router
      └── load_balancer (DNS + TLS)
    → provider
```

**No longer in the active request path:** ext-proc pod,
EnvoyFilter CRD, DestinationRule, payload-processing
ServiceAccount + RBAC, ExternalName Service. These
resources are not deleted but are bypassed by the POC —
the gpt-4o HTTPRoute backendRef is patched to Praxis.

## Patches Required

### Praxis — [`nerdalert/praxis`](https://github.com/nerdalert/praxis/tree/feat/dns-and-request-headers)

Branch: `feat/dns-and-request-headers`

| Commit | Change | Files changed |
|--------|--------|---------------|
| `9888295` | DNS resolution for upstream endpoints — added `ToSocketAddrs` fallback when `SocketAddr` parsing fails | `protocol/src/http/pingora/handler/upstream_peer.rs` |
| `9888295` | `request_set` / `request_remove` on header filter — overwrites or removes request headers before upstream | `filter/src/builtins/http/transformation/header/mod.rs`, `filter/src/builtins/http/transformation/header/tests.rs`, `filter/src/context.rs`, `filter/src/lib.rs`, `protocol/src/http/pingora/context.rs`, `protocol/src/http/pingora/handler/request_filter/mod.rs`, `protocol/src/http/pingora/handler/request_filter/stream_buffer.rs`, `benchmarks/microbenchmarks/common.rs` |
| `e7744c2` | StreamBuffer body forwarding fix — removed `!released` guard so post-Release body chunks are buffered for replay | `protocol/src/http/pingora/handler/request_filter/stream_buffer.rs` |
| `a235509` | Pingora dependency update — points `Cargo.toml` to `nerdalert/pingora` fork with initial-send fix | `Cargo.toml`, `Cargo.lock` |

### Pingora — [`nerdalert/pingora`](https://github.com/nerdalert/pingora/tree/feat/streambuffer-initial-send)

Branch: `feat/streambuffer-initial-send`

| Commit | Change | Files changed |
|--------|--------|---------------|
| `0482d58` | Initial body send when downstream already done — added `should_send_initial_body()` helper that triggers when `downstream_done == true` | `pingora-proxy/src/proxy_common.rs`, `pingora-proxy/src/proxy_h1.rs`, `pingora-proxy/src/proxy_h2.rs`, `pingora-proxy/src/proxy_custom.rs` |

### MaaS — runtime patches (no source changes)

| Patch | What | Applied by |
|-------|------|------------|
| Authorino TLS workaround | Serve gRPC TLS with OpenShift service cert, scale operator 1/0 for status | `docs/install.md` §3 |
| gpt-4o HTTPRoute backendRef | Change backendRef from `gpt-4o:443` (ExternalName) to `praxis-gateway:8080` | `demos/maas-praxis/deploy.sh` |
| Istio sidecar injection removed | Remove `istio-injection=enabled` label from `llm` namespace | `demos/maas-praxis/deploy.sh` |
| API key injection | Inject `OPENAI_API_KEY` into Praxis gateway ConfigMap via bash parameter expansion | `demos/maas-praxis/deploy.sh` |

## What Was NOT Changed

| Component | Status |
|---|---|
| `models-as-a-service` source code | No changes |
| Kuadrant wasm plugin | Still running — auth + rate limiting enforcement |
| Authorino | Still running — API key + token validation |
| Limitador | Still running — per-subscription token quotas |
| KServe | Still running — in-cluster model lifecycle |
| maas-api | Still running — key minting, subscription management |
| MaaS controller | Still running — CRD reconciliation |
| MaaS CRDs | All unchanged — ExternalModel, MaaSModelRef, MaaSAuthPolicy, MaaSSubscription |

## Validated Request Paths

| Path | Auth method | Backend | Through Praxis |
|---|---|---|---|
| `/praxis/v1/chat/completions/` | K8s token | Mock echo backends | Yes — body routing |
| `/praxis-gw/v1/chat/completions` | K8s token | api.openai.com | Yes — credential swap + TLS |
| `/llm/gpt-4o/v1/chat/completions` | MaaS API key (sk-oai-*) | api.openai.com via Praxis | Yes — full MaaS auth flow |
| `/llm/facebook-opt-125m-cpu/v1/chat/completions` | MaaS API key (sk-oai-*) | In-cluster simulator via KServe | No — KServe routes directly |
| `/v1/models` | MaaS API key | maas-api model catalog | No — handled by maas-api |

## Image

`ghcr.io/nerdalert/praxis:maas-dev` — public, includes
all Praxis and Pingora fixes listed above.

## Next Phase

Phase 2 targets descriptor request limiting in Praxis and
targeted Authorino replacement. MaaS `sk-oai-*` API keys are
opaque hash-backed keys, so the MaaS path needs a `maas-api`
validation bridge or equivalent before Authorino can be removed
from that route. Token-quota parity remains a later Phase 3b
track. See
[praxxis-planning.md](../../../praxxis-planning.md) for the
full roadmap.
