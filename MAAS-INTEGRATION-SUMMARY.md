# MaaS + Praxis Integration Summary

This document is the index and status summary for the MaaS + Praxis
proof-of-concept work. It links the phase docs, explains what Praxis
replaces, and separates validated behavior from planned follow-up work.

## Executive Summary

Praxis is being integrated into MaaS incrementally as an AI-native data
plane for model routing, provider egress, request admission, and later
token usage enforcement.

The current work proves that Praxis can replace the MaaS ext-proc/BBR
payload-processing path and can own auth/rate-limit decisions for a
targeted MaaS route. It does not yet replace the whole MaaS product, the
MaaS control plane, or all Kuadrant/Limitador token quota behavior.

| Area | Current State | Practical Meaning |
|---|---|---|
| Body-based model routing | Implemented and validated | Praxis can inspect OpenAI-compatible JSON, extract the model, and route without an ext-proc sidecar. |
| Provider egress | Implemented and validated | Praxis can rewrite paths, set provider credentials, resolve DNS, and send TLS traffic to OpenAI. |
| Request auth | Implemented and validated in Praxis | Praxis can call `maas-api` directly to validate MaaS API keys. `maas-api` remains the source of truth. |
| Request-count limiting | Implemented and validated | Praxis can enforce descriptor-based request limits keyed by subscription/user/model metadata. |
| Token limits | Planned for Phase 4 | Praxis does not yet enforce MaaS token quotas or replace Limitador token accounting. |
| Clean Kuadrant bypass | In progress / needs explicit validation | Shadow-route mode still passes through Kuadrant mechanically. Clean Gateway mode is the target proof for no Authorino/Limitador path. |
| Full gateway replacement | Not in scope yet | Envoy/OpenShift Gateway still receives external traffic; Praxis runs behind it as a backend today. |

The simplest current description is:

```text
Praxis has replaced the routing/body-processing slice of MaaS and now has
working foundations for auth and request admission. Token quota parity and
full gateway replacement are still future phases.
```

## Phase Links

| Phase | Doc | Scripts | Status | Main Outcome |
|---|---|---|---|---|
| Phase 1: BBR/ext-proc replacement | [demos/maas-praxis/README.md](demos/maas-praxis/README.md) | [deploy.sh](demos/maas-praxis/deploy.sh), [validate.sh](demos/maas-praxis/validate.sh) | Complete | Praxis replaces payload-processing/ext-proc path for model routing and provider egress. |
| Phase 1 completion report | [demos/maas-praxis/phase-1-completion.md](demos/maas-praxis/phase-1-completion.md) | [scripts/validate-all.sh](scripts/validate-all.sh) | Complete | Detailed validation summary for Phase 1. |
| Phase 2: request-admission controls | [demos/maas-praxis-phase2/README.md](demos/maas-praxis-phase2/README.md) | [deploy-descriptor.sh](demos/maas-praxis-phase2/deploy-descriptor.sh), [validate-descriptor.sh](demos/maas-praxis-phase2/validate-descriptor.sh), [validate-bridge-mode.sh](demos/maas-praxis-phase2/validate-bridge-mode.sh) | Complete | Metadata bag, Prometheus metrics, failure modes, descriptor limiter, and HTTP ext-auth foundation. |
| Phase 3: Praxis-owned auth and request limiting | [demos/maas-praxis-phase3/README.md](demos/maas-praxis-phase3/README.md) | [deploy.sh](demos/maas-praxis-phase3/deploy.sh), [validate.sh](demos/maas-praxis-phase3/validate.sh) | Shadow route validated | Praxis owns MaaS key validation and request limiting, but shared gateway path still uses pass-through Kuadrant policies. |
| Phase 3 clean Gateway path | [demos/maas-praxis-phase3/README.md](demos/maas-praxis-phase3/README.md) | [deploy-clean-gateway.sh](demos/maas-praxis-phase3/deploy-clean-gateway.sh), [validate-clean-gateway.sh](demos/maas-praxis-phase3/validate-clean-gateway.sh) | Needs explicit validation | Target path to prove the route works without shadow policies or pass-through Authorino/Limitador. |
| Phase 4: token limits and usage accounting | [demos/maas-praxis-phase4/README.md](demos/maas-praxis-phase4/README.md) | Not implemented yet | Planning | Replace token-quota slice of TRLP/Limitador for targeted Praxis-owned routes. |
| Install/runbook | [docs/install.md](docs/install.md) | N/A | Reference | MaaS + Praxis install notes. |
| StreamBuffer technical detail | [docs/streambuffer.md](docs/streambuffer.md) | N/A | Reference | Body forwarding issue and fix background. |

## Current Phase Matrix

| Capability | Phase 1 | Phase 2 | Phase 3A Shadow Route | Phase 3B Clean Gateway | Phase 4 Target |
|---|---:|---:|---:|---:|---:|
| Body-aware request inspection | Done | Done | Done | Done | Done |
| Model field extraction | Done | Done | Done | Done | Done |
| Model/path routing | Done | Done | Done | Done | Done |
| Provider DNS + TLS egress | Done | Done | Done | Done | Done |
| Provider credential swap | Done | Done | Done | Done | Done |
| Per-request metadata bag | Not present | Done | Done | Done | Done |
| Prometheus metrics endpoint | Not present | Done | Done | Done | Expanded |
| Per-filter failure mode | Not present | Done | Done | Done | Done |
| Request-count descriptor limits | Not present | Done | Done | Done | Done |
| Praxis-owned MaaS API-key validation | Not present | Code ready | Validated | Target validation | Done |
| Authorino physically absent from path | No | No | No | Target | Target |
| Limitador physically absent from path | No | No | No | Target | Target |
| Token quota enforcement | No | No | No | No | Target |
| Shared quota state | No | No | No | No | Target/follow-up |
| Full Envoy gateway replacement | No | No | No | No | Later |

## Component Replacement Matrix

| MaaS / Gateway Component | Current Role | Praxis Replacement State | Notes |
|---|---|---|---|
| ext-proc payload-processing pod | Body inspection and header mutation over gRPC | Replaced in Phase 1 | Praxis does this inline with StreamBuffer and filters. |
| BBR/body-field-to-header plugin | Extracts JSON body fields such as `model` | Replaced in Phase 1 | Praxis `model_to_header` / JSON field extraction covers this slice. |
| model-provider-resolver plugin | Resolves model to provider/upstream | Partially replaced | Praxis uses static YAML routing today; dynamic CRD watch/adaptation is future work. |
| apikey-injection plugin | Injects provider API key | Partially replaced | Praxis can set/remove request headers. Secret-backed lifecycle is future work. |
| api-translation plugin | Provider schema translation | Not replaced | Current path assumes OpenAI-compatible northbound/southbound API. |
| EnvoyFilter ext-proc wiring | Calls payload processor from gateway Envoy | Replaced for targeted path | Route backend is patched to Praxis instead of ext-proc flow. |
| Kuadrant wasm plugin | Gateway auth/rate-limit enforcement hook | Not globally replaced | Still present on shared gateway. Clean Gateway mode is the bypass proof. |
| Authorino | API-key and policy validation | Partially replaceable | Praxis can validate MaaS keys by calling `maas-api`; full Authorino removal requires clean route/gateway. |
| Limitador request counters | Request-count rate limiting | Partially replaced | Praxis descriptor limiter handles local request-count limits. |
| Limitador token counters | Token quota accounting | Not replaced | Phase 4 target. |
| `maas-api` | Key minting, key validation, subscriptions | Not replaced | Praxis calls it as the source of truth. |
| MaaS controller | Reconciles MaaS CRDs into routes/policies | Not replaced | Still creates ExternalModel/route/policy state. |
| KServe / model serving | In-cluster model lifecycle | Not replaced | Out of scope for Praxis data-plane POC. |
| OpenShift Gateway / Envoy | External ingress and Gateway API data plane | Not replaced | Praxis runs behind it today. Full gateway replacement is later. |

## High-Level Request Flows

### Phase 1: BBR Replacement Flow

| Step | Component | Action |
|---:|---|---|
| 1 | Client | Sends OpenAI-compatible chat request to MaaS model path. |
| 2 | OpenShift Gateway / Envoy | Receives request and applies existing gateway policies. |
| 3 | MaaS HTTPRoute | Routes selected model path to Praxis instead of the original ExternalName backend. |
| 4 | Praxis | Rewrites path from MaaS model prefix to provider path. |
| 5 | Praxis | Swaps client/MaaS credential for provider credential. |
| 6 | Praxis | Resolves provider DNS and opens upstream TLS connection. |
| 7 | Provider | Receives the original request body and returns response. |
| 8 | Client | Receives provider response through Praxis and Envoy. |

Key point: Phase 1 replaces body-processing and provider egress, not auth or token limiting.

### Phase 2: Bridge-Mode Descriptor Flow

| Step | Component | Action |
|---:|---|---|
| 1 | Client | Sends request using MaaS API key. |
| 2 | Kuadrant / Authorino | Validates key and injects trusted MaaS identity headers. |
| 3 | Praxis | Reads trusted header such as `x-maas-subscription`. |
| 4 | Praxis descriptor limiter | Builds descriptor key from trusted identity/model values. |
| 5 | Praxis | Allows or rejects based on local token bucket. |
| 6 | Praxis | Strips trusted internal headers before upstream. |
| 7 | Provider | Sees no internal MaaS descriptor headers. |

Key point: Phase 2 proves Praxis can consume MaaS identity and make descriptor-based request-admission decisions.

### Phase 3A: Praxis-Owned Decision Flow on Shared Gateway

| Step | Component | Action |
|---:|---|---|
| 1 | Client | Sends request to shadow MaaS/Praxis path with `sk-oai-*` MaaS key. |
| 2 | Shared Gateway Kuadrant policies | Pass-through policies allow traffic to reach Praxis. |
| 3 | Praxis `http_ext_auth` | Extracts bearer key and calls `maas-api` validation endpoint. |
| 4 | `maas-api` | Validates key, subscription, status, expiration, and returns metadata. |
| 5 | Praxis metadata bag | Stores user/subscription/key metadata from validation response. |
| 6 | Praxis descriptor limiter | Enforces request-count limit using `auth.subscription` metadata. |
| 7 | Praxis routing/egress filters | Rewrite path, swap provider credential, route to OpenAI. |
| 8 | Provider | Returns response. |

Key point: Praxis owns the meaningful auth and request-limit decisions, but pass-through Kuadrant/Authorino/Limitador are still mechanically in the shared Gateway path.

### Phase 3B: Clean Gateway Target Flow

| Step | Component | Action |
|---:|---|---|
| 1 | Client | Sends request to a clean Gateway/route dedicated to Praxis. |
| 2 | Clean Gateway | Forwards to Praxis without Kuadrant AuthPolicy/TRLP pass-through. |
| 3 | Praxis `http_ext_auth` | Calls `maas-api` directly for key validation. |
| 4 | Praxis descriptor limiter | Applies local request-count admission control. |
| 5 | Praxis routing/egress filters | Sends valid requests to provider. |

Key point: this is the proof path for operating without shadow routes and without Authorino/Limitador involvement for the targeted route.

### Phase 4: Token-Limit Target Flow

| Step | Component | Action |
|---:|---|---|
| 1 | Client | Sends request to Praxis-owned MaaS route. |
| 2 | Praxis auth | Validates MaaS key via `maas-api`. |
| 3 | Praxis token policy | Finds token budget for subscription/model. |
| 4 | Praxis token admission | Rejects early or reserves estimated tokens. |
| 5 | Provider | Processes request and returns usage. |
| 6 | Praxis usage parser | Reads `usage.prompt_tokens`, `usage.completion_tokens`, `usage.total_tokens`. |
| 7 | Praxis counter backend | Charges token usage and updates remaining budget. |
| 8 | Metrics/export | Emits usage and limit-decision metrics. |

Key point: Phase 4 is where Praxis starts replacing Limitador token quota behavior. This is not complete today.

## Auth Ownership

Praxis auth is configurable, not hardcoded globally. It only runs when the
`http_ext_auth` filter is placed in the listener filter chain.

| Item | Current Behavior |
|---|---|
| Token source | `Authorization: Bearer <token>` |
| Validation backend | Configured HTTP endpoint, currently `maas-api` internal validation API |
| Request body to validation backend | `{"key":"<token>"}` |
| Allow condition | Validation response includes `valid: true` |
| Deny behavior | Missing auth -> `401`; invalid key -> `403` |
| Metadata output | Response fields are mapped into Praxis filter metadata such as `auth.subscription` |
| Header hygiene | Config can strip request headers before upstream. |
| Scope | Per route/listener config. Removing the filter disables Praxis auth. |

| Component | Responsibility in Phase 3 |
|---|---|
| `maas-api` | Source of truth for MaaS keys, subscriptions, expiration, and validation result. |
| Praxis `http_ext_auth` | Enforcement point that asks `maas-api` whether to allow the request. |
| Authorino | Still touched in Phase 3A shadow route; not required by Praxis itself. |
| Clean Gateway path | Intended proof that Praxis auth works without Authorino in the route path. |

## Rate Limiting and Token Limits

Praxis currently enforces request-count limits, not token quotas.

| Question | Current Answer |
|---|---|
| Where are Praxis request limits configured? | In Praxis YAML ConfigMap. |
| What algorithm is used? | Local token bucket. |
| What keys can limits use? | Descriptor values from filter metadata or trusted headers. |
| Can it limit per subscription? | Yes, if `auth.subscription` metadata or a trusted subscription header is present. |
| Can it limit per model? | Yes, if model metadata/header is included in descriptor sources. |
| Is state shared across replicas? | No, current limiter state is local to each Praxis pod. |
| Does it enforce MaaS token limits? | No. Phase 4 target. |
| Does it read `MaaSSubscription` token limits directly? | No. Phase 4 needs a config adapter or CRD-driven integration. |

| Capability | MaaS TRLP + Limitador | Praxis Today | Phase 4 Target |
|---|---|---|---|
| Request-count limiting | Yes | Yes, local descriptor limiter | Yes, with shared state later |
| Token quota limiting | Yes | No | Yes |
| Per-subscription keys | Yes | Yes | Yes |
| Per-model keys | Yes | Yes if configured | Yes |
| Runtime CRD reconciliation | Yes | No | Adapter/controller needed |
| Distributed counters | Yes, Redis/Limitador | No | Redis/Valkey or equivalent |
| Usage metrics | Limitador metrics | Praxis auth/rate metrics only | Praxis token usage metrics |
| Streaming token accounting | Existing MaaS/Kuadrant path varies by provider | No | Later after non-streaming |

## Validation Summary

| Area | Validation | Result | Notes |
|---|---|---|---|
| Phase 1 BBR replacement | Phase 1 demo validation | Passing | Includes body routing, body forwarding, model path, and provider egress. |
| External OpenAI path | MaaS `gpt-4o` path through Praxis | Passing historically | Requires OpenAI key and route/backend patch. |
| All-model check | `gpt-4o` + `facebook/opt-125m` scripts | Passing historically | Confirms external and in-cluster model paths can coexist. |
| Phase 2 descriptor limiter | `validate-descriptor.sh` | Passing | Local request-count limits and metrics. |
| Phase 2 bridge mode | `validate-bridge-mode.sh` | Passing | Authorino-injected descriptor consumed and stripped by Praxis. |
| Phase 2 ext-auth unit tests | Rust unit tests | Passing | Exercises config parsing, token extraction, and runtime behavior. |
| Phase 3A shadow route | `validate.sh` | Passing | Praxis owns decisions; pass-through Kuadrant still mechanically present. |
| Phase 3B clean Gateway | `validate-clean-gateway.sh` | Needs explicit run/result | This should be the next proof point if not already captured in the phase doc. |
| Phase 4 token limits | Not implemented | Not applicable | Planning only. |

## Known Gaps and Caveats

| Gap | Impact | Likely Phase / Work Item |
|---|---|---|
| Phase 3A still uses pass-through Kuadrant policies | It proves Praxis decisions, not physical removal of Authorino/Limitador. | Phase 3B clean Gateway validation. |
| Token quotas are not enforced by Praxis | Cannot replace MaaS token TRLP/Limitador path yet. | Phase 4. |
| Request limiter state is local | Multi-replica limits are not globally correct. | Shared Redis/Valkey backend. |
| Praxis limits are static YAML | MaaS CRD limit changes do not flow into Praxis automatically. | MaaS/Praxis config adapter or controller. |
| Provider credentials are static in demo config | No production-grade secret lifecycle or rotation yet. | Secret-backed config integration. |
| Provider schema translation is absent | Works for OpenAI-compatible providers only. | Provider abstraction/translation phase. |
| `tls_skip_verify` may be used in dev | Not production-safe. | Service CA/native root handling. |
| Streaming token accounting is absent | Cannot enforce output-token budgets for streaming completions. | Phase 4 follow-up. |
| Gateway replacement not attempted | Envoy still handles external ingress. | Later gateway phase. |
| StreamBuffer/Pingora body forwarding remains sensitive | Payload pre-read and replay are load-bearing for routing. | Keep regression tests and upstream alignment. |

## Issue Map

| Area | Upstream Issue | Relevance |
|---|---|---|
| Prometheus metrics | [praxis-proxy/praxis#8](https://github.com/praxis-proxy/praxis/issues/8) | Phase 2 metrics foundation. |
| Per-filter metrics | [praxis-proxy/praxis#9](https://github.com/praxis-proxy/praxis/issues/9) | Needed for richer auth/rate/token observability. |
| Distributed tracing | [praxis-proxy/praxis#10](https://github.com/praxis-proxy/praxis/issues/10) | Useful for MaaS end-to-end request tracing. |
| Dynamic config reload | [praxis-proxy/praxis#11](https://github.com/praxis-proxy/praxis/issues/11) | Needed before Praxis can consume changing MaaS policy without pod restarts. |
| External auth / policy | [praxis-proxy/praxis#14](https://github.com/praxis-proxy/praxis/issues/14) | Tracks HTTP ext-auth and broader auth integration. |
| AI inference support | [praxis-proxy/praxis#19](https://github.com/praxis-proxy/praxis/issues/19) | Umbrella for OpenAI-compatible inference gateway behavior. |
| Token counting | [praxis-proxy/praxis#20](https://github.com/praxis-proxy/praxis/issues/20) | Required for Phase 4 token usage accounting. |
| Token rate limiting | [praxis-proxy/praxis#21](https://github.com/praxis-proxy/praxis/issues/21) | Required for replacing MaaS token quotas. |
| Filter pipeline architecture | [praxis-proxy/praxis#40](https://github.com/praxis-proxy/praxis/issues/40) | Relevant to cross-filter metadata and stateful request handling. |
| Failure modes | [praxis-proxy/praxis#48](https://github.com/praxis-proxy/praxis/issues/48) | Phase 2 per-filter failure-mode work. |
| Stateful options | [praxis-proxy/praxis#65](https://github.com/praxis-proxy/praxis/issues/65) | Required for shared quota state, token ledgers, and advanced MaaS policy. |
| StreamBuffer body forwarding | [praxis-proxy/praxis#75](https://github.com/praxis-proxy/praxis/issues/75) | Relevant to body pre-read/replay correctness. |

Suggested new or follow-up issues if they do not already exist:

| Proposed Issue | Why It Matters |
|---|---|
| Redis/Valkey backend for descriptor and token limit state | Required for multi-replica correctness. |
| MaaSSubscription-to-Praxis config adapter | Needed to read MaaS token limits and render Praxis config. |
| OpenAI usage parser filter | First concrete step for Phase 4 token accounting. |
| Token usage Prometheus compatibility metrics | Needed for dashboards and migration from Limitador metrics. |
| SSE/streaming token accounting | Required for streaming completions. |
| Secret-backed provider credential source | Needed to remove static provider keys from ConfigMaps. |
| Clean Gateway no-Kuadrant validation gate | Needed to prove physical bypass, not just decision ownership. |

## Recommended Next Steps

| Priority | Step | Why |
|---:|---|---|
| 1 | Validate Phase 3B clean Gateway path and record results in the Phase 3 README. | This resolves the current confusion about shadow routes and whether Authorino/Limitador are physically absent. |
| 2 | Harden Phase 3 config for production-like behavior. | Move away from dev-only `tls_skip_verify`, fail-open, and permissive missing-descriptor behavior where applicable. |
| 3 | Start Phase 4 with non-streaming OpenAI usage parsing. | Smallest useful slice of token accounting. |
| 4 | Add token usage metrics. | Gives a visible replacement path for Limitador token counters. |
| 5 | Add a shared Redis/Valkey backend. | Required before claiming multi-replica quota correctness. |
| 6 | Build or prototype a MaaSSubscription config adapter. | Bridges MaaS CRD policy into Praxis config. |
| 7 | Add streaming/SSE token accounting. | Required for real chat-completion traffic parity. |

## One-Sentence Status

Praxis is a validated replacement for MaaS body-based routing and provider
egress, has working foundations for Praxis-owned auth and request limiting,
and needs Phase 3B clean-Gateway validation plus Phase 4 token accounting
before it can replace the Authorino/Limitador enforcement path for targeted
MaaS routes.
