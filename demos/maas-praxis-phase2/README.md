# MaaS + Praxis Phase 2 — Request-Admission Controls

Phase 2 extends Praxis from routing-only replacement to
request-admission enforcement on Praxis-owned routes.

This is **not** full Limitador replacement. Phase 2 proves
the descriptor machinery for request-count limiting and
MaaS identity projection. Token quotas require Phase 3b
(token counting #20 + token rate limiting #21 + shared state).

## Status

**Tasks 1-7 are complete as implementation/demo tasks. Task 8 is deferred.**

Cluster validation has been completed for Phase 1, descriptor
request limiting, and bridge-mode MaaS descriptor projection.
Task 7 is code-complete and unit-tested, but has **not** yet been
deployed as the Authorino replacement on a MaaS route.

| Validation | Tests | Result |
|-----------|-------|--------|
| Phase 1: BBR replacement + MaaS path | 8 | **8/8** |
| Phase 2: Descriptor rate limiting | 7 | **7/7** |
| Phase 2: Bridge-mode MaaS projection | 3 | **3/3** |
| All models: gpt-4o + facebook/opt-125m | 7 | **7/7** |
| Cluster script assertions | 25 | **25/25** |
| Task 7: `http_ext_auth` unit tests | 18 | **18/18** |

The cluster validation rows are separate script checkpoints and
some paths overlap. They should not be interpreted as 25 unique
end-to-end scenarios.

## Artifacts

| Artifact | Reference |
|---|---|
| Praxis branch | [`feat/maas-phase2`](https://github.com/nerdalert/praxis/tree/feat/maas-phase2) |
| Pingora branch | [`feat/streambuffer-initial-send`](https://github.com/nerdalert/pingora/tree/feat/streambuffer-initial-send) |
| Image | `ghcr.io/nerdalert/praxis:maas-phase2` |
| Phase 1 checkpoint | [`phase1-complete`](https://github.com/nerdalert/praxis/releases/tag/phase1-complete) / `ghcr.io/nerdalert/praxis:maas-phase1` |
| Phase 1 demo | [`demos/maas-praxis/`](../maas-praxis/) |
| Phase 1 report | [`demos/maas-praxis/phase-1-completion.md`](../maas-praxis/phase-1-completion.md) |

## Commits

All commits on `feat/maas-phase2` branch, ordered by dependency:

| Commit | Task | Upstream Issue | Change | Files | Tests Added |
|--------|------|---------------|--------|-------|-------------|
| `9888295` | Phase 1 | New (DNS resolution) | **DNS resolution for upstream endpoints.** Added `ToSocketAddrs` fallback in `upstream_peer.rs` when `SocketAddr` parsing fails. Enables endpoints like `api.openai.com:443` and K8s service DNS names. | `upstream_peer.rs` | 4 |
| `9888295` | Phase 1 | New (request headers) | **`request_set` / `request_remove` on header filter.** Overwrites or removes request headers before upstream. Needed for Host rewrite and provider credential injection. Wired through `HttpFilterContext.remove_request_headers` and protocol layer `RequestHeaderOps`. | `header/mod.rs`, `header/tests.rs`, `context.rs`, `lib.rs`, `request_filter/mod.rs`, `stream_buffer.rs`, `common.rs` | 2 |
| `e7744c2` | Phase 1 | New (StreamBuffer) | **StreamBuffer body forwarding fix.** Removed `!released` guard on `buffer.push()` in `stream_buffer.rs` so all body chunks are buffered for replay regardless of filter Release state. Without this, upstream backends received empty or truncated request bodies after body inspection. | `stream_buffer.rs` | 0 (existing tests cover) |
| `a235509` | Phase 1 | — | **Pingora dependency update.** Points `Cargo.toml` to `nerdalert/pingora` fork (`feat/streambuffer-initial-send` branch) which includes the initial-send fix. Pingora's transport layer skipped `request_body_filter` when downstream was already consumed; the fork adds `should_send_initial_body()` to trigger the callback. | `Cargo.toml`, `Cargo.lock` | 0 |
| `50f26f9` | Task 1 | New (foundation) | **Per-request metadata bag.** Added `filter_metadata: HashMap<String, String>` to `HttpFilterContext` and `PingoraRequestCtx`. Persists across all Pingora lifecycle phases via `mem::take` + write-back in 6 execution sites (request, request body, response, response body, logging cleanup, StreamBuffer pre-read). Filters write with `set_metadata()`, read with `metadata()`. | `context.rs`, `lib.rs`, `protocol/context.rs`, `request_filter/mod.rs`, `stream_buffer.rs`, `request_body_filter.rs`, `response_filter.rs`, `response_body_filter.rs`, `handler/mod.rs`, `common.rs` | 3 |
| `18ee6d7` | Task 2 | [#8](https://github.com/praxis-proxy/praxis/issues/8) (partial) | **Prometheus `/metrics` endpoint.** Process-global `PrometheusHandle` via `OnceLock` + `Mutex` (race-safe). `/metrics` route on admin listener with Prometheus text exposition format. Records `praxis_http_requests_total` counter and `praxis_http_request_duration_seconds` histogram from `logging()` hook in both `with_body` and `no_body` handlers. Labels: method, status, cluster. Status from `session.response_written()` with safe fallback. Updated `docs/features.md` and `examples/configs/operations/admin-interface.yaml` (corrected `/health` → `/healthy`). | `metrics.rs` (new), `request_metrics.rs` (new), `health/service.rs`, `mod.rs`, `with_body.rs`, `no_body.rs`, `handler/mod.rs`, `Cargo.toml`, `protocol/Cargo.toml`, `features.md`, `admin-interface.yaml` | 2 |
| `878095e` | Task 3 | [#48](https://github.com/praxis-proxy/praxis/issues/48) | **Per-filter failure modes.** Added `FailureMode` enum (`Closed`/`Open`) to `FilterEntry` config with `#[serde(default)]` defaulting to `Closed`. Carried through pipeline tuple as 4th element. Fail-open checked in all execution phases: HTTP request, response, request body, response body, and TCP connect. `Reject` is never bypassed — fail-open only converts `Err(FilterError)` to `Continue`. | `config/filters.rs`, `config/mod.rs`, `pipeline/mod.rs`, `pipeline/build.rs`, `pipeline/http.rs`, `pipeline/http_utils.rs`, `pipeline/tcp.rs`, `pipeline/body.rs`, `pipeline/checks.rs`, `pipeline/tests.rs`, plus test utility files | 5 |
| `c9172fa` | Task 4 | New (descriptor limiting) | **Descriptor-based local request rate limiting.** Extended `rate_limit` filter with `mode: descriptor`. Composite keys from context metadata or trusted request headers. Per-descriptor request buckets with `DashMap` and eviction (`MAX_DESCRIPTOR_ENTRIES=100K`). Collision-safe keys with length-prefixed `name:value` pairs. `missing: reject` (429) or `skip` behavior. Metrics: `praxis_rate_limit_decisions_total` with policy/decision/reason labels. Metadata: `rate_limit.policy`, `rate_limit.decision`, `rate_limit.remaining`, `rate_limit.descriptor_key`. Response headers injected via stored descriptor key. Existing `global`/`per_ip` modes unchanged. | `rate_limit/config.rs`, `rate_limit/mod.rs`, `rate_limit/limiter.rs`, `rate_limit/tests.rs`, `filter/Cargo.toml` | 12 |
| `45550c1` | Task 7 | [#14](https://github.com/praxis-proxy/praxis/issues/14) (partial), [#12](https://github.com/praxis-proxy/praxis/issues/12) (partial) | **HTTP ext-auth filter for MaaS API key validation.** New `http_ext_auth` filter validates bearer tokens via HTTP callout to auth service (e.g. `maas-api`). Extracts `Bearer` token from `Authorization` header. Calls configured endpoint with `{"key":"<token>"}`. Strictly requires `valid:true` in response (fail-closed on missing field, `valid:false`, or malformed response). Maps response JSON fields to `filter_metadata` and upstream headers. Strips configured request headers before upstream — including on callout failure (prevents credential leak on fail-open). TLS verify enabled by default (`tls_skip_verify` for dev). Metrics: `praxis_auth_allowed_total`, `praxis_auth_rejected_total`, `praxis_auth_error_total`. Mock HTTP server tests for `valid:true`, `valid:false`, missing valid, 401/403, metadata injection, header injection, stripping, callout failure. | `http_ext_auth/mod.rs` (new), `http_ext_auth/config.rs` (new), `http_ext_auth/tests.rs` (new), `security/mod.rs`, `builtins/http/mod.rs`, `registry.rs`, `Cargo.toml`, `filter/Cargo.toml` | 18 |
| `a01215c` | — | — | **Rustls crypto provider init.** Install `aws_lc_rs` crypto provider in `main()` before Pingora and reqwest init to prevent CryptoProvider conflict at startup. Required because reqwest's `rustls-tls-manual-roots` and Pingora both use rustls but neither installs the provider. Also fixed mock server tests (async I/O instead of blocking). | `server/src/main.rs`, `server/Cargo.toml`, `http_ext_auth/tests.rs` | 0 |

## Phase 2 Summary

Phase 1 proved that Praxis can sit behind the MaaS-created
HTTPRoute and replace the body-based-routing data path for the
`gpt-4o` ExternalModel. Authorino and Limitador remained in front
of Praxis.

Phase 2 adds the request-admission pieces needed to start replacing
parts of that front-door control path:

| Area | What changed | Replacement value |
|------|--------------|-------------------|
| Per-request metadata | Filters can write/read `filter_metadata` across request, body, response, and logging phases. | Later filters can consume identity, subscription, model, and rate-limit decisions without relying only on headers. |
| Metrics | Praxis exposes `/metrics` and records request, rate-limit, and auth decision metrics. | Gives the POC enough observability to compare Praxis decisions with Kuadrant/Limitador behavior. |
| Failure modes | Each filter can be `failure_mode: closed` or `failure_mode: open`; rejects are never bypassed. | Lets auth/rate-limit filters fail closed while less critical filters can fail open. |
| Descriptor request limiter | `rate_limit` supports `mode: descriptor` using metadata or trusted headers. | Replaces the request-count slice of Limitador for Praxis-owned routes. This is not token limiting. |
| Bridge mode | Praxis can consume `x-maas-subscription` injected by Authorino, make a descriptor-limit decision, then strip the internal header. | Allows incremental adoption without removing Authorino first. |
| HTTP ext-auth | Praxis can call `maas-api` with an opaque `sk-oai-*` key and require `valid:true`. | Starts the targeted Authorino replacement path for MaaS API-key validation. Not cluster-wired yet. |
| Shared state | Deferred. | Required before multi-replica descriptor limits or token quotas are correct. |

The important boundary: Phase 2 replaces **routing and local
request-admission mechanics**, not the full MaaS policy system.
Token quotas, subscription selection, distributed counters, and
full Authorino/Limitador removal remain later work.

## Task Status

| Task | Description | Status | Commit |
|------|------------|--------|--------|
| 1 | Per-request metadata bag (`filter_metadata`) | **Done** | `50f26f9` |
| 2 | Prometheus `/metrics` endpoint | **Done** | `18ee6d7` |
| 3 | Per-filter failure modes (all phases) | **Done** | `878095e` |
| 4 | Descriptor-based local request rate limiting | **Done** | `c9172fa` |
| 5 | Descriptor limiter demo validation | **Done** | praxis-pocs `7e51c5f` |
| 6 | Bridge-mode MaaS descriptor projection | **Done** | praxis-pocs `2b8bb64` |
| 7 | HTTP ext-auth filter for MaaS API key validation | **Done - code/unit tests, not cluster-wired** | `45550c1` |
| 8 | Shared Redis/Valkey rate-limit backend | **Deferred** | — |

## Issue Alignment

| Upstream Issue | Task | Coverage | Notes |
|---------------|------|----------|-------|
| [#8 Prometheus Metrics](https://github.com/praxis-proxy/praxis/issues/8) | Task 2 | Partial | HTTP request counter + duration histogram. Body byte metrics, TCP metrics, upstream metrics, and error cardinality items remain. |
| [#48 Per-Filter Failure Modes](https://github.com/praxis-proxy/praxis/issues/48) | Task 3 | Complete | `failure_mode: open/closed` on all HTTP and TCP execution phases. Reject never bypassed. |
| [#14 External Auth Filter](https://github.com/praxis-proxy/praxis/issues/14) | Task 7 | Partial | HTTP callout path only. gRPC ext_authz, Envoy ext_authz compatibility, configurable forwarded headers, and full integration tests remain. |
| [#12 Authentication](https://github.com/praxis-proxy/praxis/issues/12) | Task 7 | Partial | MaaS `sk-oai-*` API key validation via HTTP callout. JWT/JWKS validation not implemented. |
| [#21 Token Rate Limiting](https://github.com/praxis-proxy/praxis/issues/21) | — | Not used | #21 is token-aware quotas (depends on #20 token counting). Task 4 is request-count limiting only. Do not attach descriptor limiting to #21. |
| [#65 Stateful Options](https://github.com/praxis-proxy/praxis/issues/65) | Task 8 | Design context | Spike issue for shared state. Task 8 needs a separate implementation issue. |
| New: descriptor request limiting | Task 4 | Needs filing | Local request-count buckets keyed by descriptor. Not token quotas. |
| New: MaaS API key validation mode | Task 7 | Needs filing | MaaS-specific child of #14/#12 for opaque `sk-oai-*` key validation. |
| New: shared rate-limit backend | Task 8 | Needs filing | Redis/Valkey backend for distributed descriptor/request limiting. Reference #65. |

## What Phase 2 Proves

| Capability | Validated |
|-----------|-----------|
| Praxis can enforce request-admission limits by trusted descriptor | Yes — descriptor isolation, burst exhaustion, /metrics |
| Praxis can consume Authorino-injected MaaS identity for rate limiting | Yes — bridge mode with `x-maas-subscription` |
| Praxis strips descriptor headers before upstream | Yes — OpenAI doesn't see internal headers |
| Praxis can validate MaaS API keys via HTTP callout | Yes (code + unit tests) — not yet deployed as Authorino replacement |
| Praxis fails closed on invalid/missing `valid` field | Yes (code + unit tests) |
| Per-filter failure modes work across all execution phases | Yes (code + tests) |
| `/metrics` exposes rate-limit and auth decisions | Yes — `praxis_rate_limit_decisions_total`, `praxis_auth_*_total` |

## What Phase 2 Does NOT Prove

| Capability | Why not |
|-----------|---------|
| Token quota enforcement | Requires #20 token counting — Phase 3b |
| Distributed rate limiting | Requires Redis/Valkey shared state — Task 8 |
| Full Limitador replacement | Requires token counting + shared state + dashboard compatibility |
| Full Authorino replacement | Task 7 ext-auth needs cluster validation, TLS/CA story, subscription selection |
| Kuadrant wasm plugin elimination | Requires Phase 2 + 2b together on targeted routes |

## Request Flows

### Flow A: Descriptor Limiter Demo

This is a standalone Praxis-owned route used to prove local
descriptor request limiting.

```text
client
  -> OpenShift Gateway /praxis-desc/v1/chat/completions/
  -> Kuadrant/Authorino validates Kubernetes token for demo route
  -> Praxis `praxis-descriptor`
     -> request_id/access_log
     -> model_to_header extracts body model into X-AI-Model
     -> rate_limit mode=descriptor reads:
        - X-MaaS-Subscription
        - X-AI-Model
     -> router chooses qwen or mistral echo backend
  -> echo backend
```

Validated by `validate-descriptor.sh`:

- first request for `free/qwen` is allowed
- second request for `free/qwen` is rejected with `429`
- `premium/qwen` gets a separate bucket
- `free/mistral` gets a separate bucket
- missing descriptor is rejected
- `/metrics` exposes rate-limit decisions
- Praxis logs show rate-limit decisions

This proves local request-count limiting only. It does not prove
token quotas or distributed counters.

### Flow B: MaaS Bridge Mode

This is the real MaaS `gpt-4o` ExternalModel path with Authorino
still in front. Praxis consumes the identity header that Authorino
already injects.

```text
client with MaaS API key
  -> OpenShift Gateway /llm/gpt-4o/v1/chat/completions
  -> Kuadrant wasm plugin
     -> Authorino validates sk-oai-* key with maas-api
     -> Authorino checks subscription/policy
     -> Limitador still handles token quota policy
     -> Authorino injects x-maas-subscription
  -> Praxis `praxis-gateway`
     -> rate_limit mode=descriptor reads x-maas-subscription
     -> Praxis strips x-maas-subscription before upstream
     -> header filter replaces Authorization with provider key
     -> upstream TLS to OpenAI
  -> OpenAI
```

Validated by `validate-bridge-mode.sh`:

- MaaS API key request succeeds on `/llm/gpt-4o/...`
- Praxis metrics show descriptor decision `allow` / `reason=ok`
- OpenAI response succeeds after internal descriptor header is stripped

This is the safest incremental replacement mode because Authorino
continues to own auth and subscription checks while Praxis starts
owning request-admission decisions.

### Flow C: Future Targeted Authorino Replacement

Task 7 adds the code required for Praxis to validate opaque MaaS
API keys directly, but this flow is not deployed in the current
cluster demo.

```text
client with MaaS API key
  -> OpenShift Gateway on targeted Praxis-owned route
  -> Praxis
     -> http_ext_auth extracts Bearer token
     -> POST {"key":"<token>"} to maas-api /internal/v1/api-keys/validate
     -> require response valid:true
     -> map subscription/user fields into filter_metadata and/or headers
     -> strip Authorization before upstream
     -> descriptor rate_limit consumes metadata/header
     -> route to model backend/provider
```

Remaining work before this replaces Authorino on a MaaS route:

- cluster deployment manifest that wires `http_ext_auth` into a
  targeted route
- TLS/service CA handling for the `maas-api` HTTPS endpoint
- subscription-selection parity if the route needs Authorino's
  `subscription-info` behavior, not just API-key validation
- negative E2E tests for invalid/revoked keys
- confirmation that credential stripping works on real upstream traffic

## Validation Scripts

| Script | What it tests |
|--------|--------------|
| `demos/maas-praxis-phase2/validate-descriptor.sh` | Descriptor isolation, burst exhaustion, missing descriptor, /metrics, logs (7 tests) |
| `demos/maas-praxis-phase2/validate-bridge-mode.sh` | Authorino-injected descriptor, metrics match, header stripping (3 tests) |
| `demos/maas-praxis/validate.sh` | Phase 1: BBR replacement + provider gateway + MaaS API key path (8 tests) |
| `scripts/validate-maas-all-models.sh` | All models: gpt-4o + facebook/opt-125m + model listing (7 tests) |

## Deploy

```bash
# Prerequisites: Phase 1 deployed (demos/maas-praxis/deploy.sh)

# Deploy descriptor limiter demo
./demos/maas-praxis-phase2/deploy-descriptor.sh

# Validate
./demos/maas-praxis-phase2/validate-descriptor.sh
./demos/maas-praxis-phase2/validate-bridge-mode.sh
```

## Next Phases

See [`praxxis-planning.md`](../../../praxxis-planning.md) for
the full roadmap.

| Phase | Target | Key Issues |
|-------|--------|------------|
| Phase 3 | Eliminate Kuadrant wasm on Praxis-owned routes | Depends on Phase 2 + 2b |
| Phase 3b | Token counting + token-aware limits | #20, #21 |
| Phase 4 | Praxis as the gateway | #7, #33, #39 |
