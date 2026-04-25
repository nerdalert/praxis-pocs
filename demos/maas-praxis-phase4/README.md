# MaaS + Praxis Phase 4 — Token Limits and Usage Accounting

Phase 4 is the token-quota replacement phase.

The goal is to move MaaS token-limit enforcement from
Kuadrant/Limitador into Praxis for a targeted Praxis-owned route.
This is separate from Phase 3, which proves Praxis-owned auth and
request-admission. Phase 4 is where Praxis starts replacing the
MaaS `TokenRateLimitPolicy` / Limitador token path.

## Current Status

Praxis does **not** currently enforce MaaS token limits.

Praxis currently supports request-count limiting through the
Phase 2 descriptor limiter:

```text
descriptor -> request token bucket
```

That can enforce rules like:

```text
subscription gpt-4o-subscription: 10 requests/second, burst 20
```

It cannot yet enforce rules like:

```text
subscription gpt-4o-subscription: 10,000 tokens/minute
```

MaaS token quotas still flow through Kuadrant and Limitador:

```text
MaaSSubscription
  -> MaaS controller
  -> TokenRateLimitPolicy
  -> Kuadrant wasm plugin
  -> Limitador
  -> response usage.total_tokens
  -> authorized_hits / authorized_calls / limited_calls metrics
```

## Phase 4 Target

Target flow after Phase 4:

```text
Client
  -> clean Gateway or Praxis-owned route
  -> Praxis
     -> http_ext_auth validates MaaS sk-oai-* key with maas-api
     -> subscription/model metadata is selected
     -> token budget is loaded for subscription/model
     -> request is admitted or rejected based on token budget
     -> request is sent to backend/provider
     -> response usage is parsed
     -> token counters are updated
     -> usage metrics are exported
  -> backend/provider
```

Phase 4 should start with one route, one model, and one
subscription before broadening.

Recommended first target:

```text
/praxis-maas/gpt-4o/v1/chat/completions
```

Recommended first backend:

```text
OpenAI-compatible non-streaming chat completions
```

Streaming should be added after non-streaming usage accounting is
stable.

## What Phase 4 Replaces

| Current MaaS/Kuadrant piece | Praxis replacement target | Phase 4 status |
|---|---|---|
| `MaaSSubscription.spec.modelRefs[].tokenRateLimits[]` | Rendered Praxis token-limit config or adapter-fed config | Planned |
| `TokenRateLimitPolicy` for targeted route | Praxis token budget filter | Planned |
| Limitador token quota counters | Praxis shared token counter backend | Planned |
| Limitador `authorized_hits` token usage | Praxis usage/token metrics | Planned |
| Limitador `authorized_calls` / `limited_calls` request counters | Praxis auth/rate/token decision metrics | Partial foundation exists |
| Kuadrant response `usage.total_tokens` extraction | Praxis response usage parser / token counter | Planned |

## What Phase 4 Does Not Replace

| Component | Why not |
|---|---|
| MaaS controller | Still source of truth for MaaS CRDs and generated state |
| `maas-api` | Still owns API-key minting, validation, and subscription data |
| MaaS CRDs | Still source of truth for model/subscription policy |
| Gateway Envoy | Gateway replacement is a later phase |
| Provider translation | Only OpenAI-compatible usage parsing is in scope first |
| Full billing product | Phase 4 emits usage data; billing export is separate |

## Required Capabilities

### 1. Token-Limit Config Source

Praxis needs token-limit policy data.

Current MaaS source:

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
spec:
  modelRefs:
    - name: gpt-4o
      namespace: llm
      tokenRateLimits:
        - limit: 10000
          window: 1m
```

Phase 4 can start with static Praxis config rendered by the demo.
Longer term, a MaaS/Praxis adapter should watch MaaS CRDs and
render or push config.

Minimum config needed by Praxis:

```yaml
- filter: token_rate_limit
  mode: descriptor
  descriptor:
    sources:
      - context: maas.selected_subscription_key
      - context: ai.model
  limits:
    - name: total_tokens_per_minute
      tokens: 10000
      window: 1m
      dimension: total
```

Open question: whether Praxis should read MaaS CRDs directly or
only consume rendered config from a MaaS-side adapter. For the POC,
rendered config is safer.

### 2. Token Usage Extraction

First implementation should parse OpenAI-compatible response usage:

```json
{
  "usage": {
    "prompt_tokens": 12,
    "completion_tokens": 5,
    "total_tokens": 17
  }
}
```

Required metadata:

| Metadata key | Meaning |
|---|---|
| `tokens.prompt` | prompt/input tokens |
| `tokens.completion` | completion/output tokens |
| `tokens.total` | total tokens used |
| `tokens.source` | `provider_usage`, `local_count`, or `estimated` |
| `tokens.model` | response or request model |

The first POC can trust provider-reported `usage.total_tokens` for
non-streaming OpenAI-compatible responses.

Local tokenization should be added later because providers do not
all return usage in the same way, and streaming usage may arrive at
end-of-stream or not at all.

### 3. Token Counter Backend

Token counters need shared state before any multi-replica claim.

Single-pod local state is acceptable for the first dev proof only.
Production-style enforcement needs Redis/Valkey or another shared
state backend.

Required backend behavior:

- atomic check-and-increment or reserve-and-commit
- key TTL based on quota window
- timeout handling
- fail-open/fail-closed config
- metrics for backend latency/errors/partitions
- deterministic behavior across Praxis replicas

Recommended first shared backend:

```text
Redis / Valkey
```

### 4. Enforcement Model

Token limits have an awkward timing problem: output tokens are only
known after the backend responds.

Phase 4 should explicitly choose one or more modes:

| Mode | How it works | Pros | Cons |
|---|---|---|---|
| Pre-admit by estimated max tokens | Reject before upstream if prompt + requested max output would exceed budget | Prevents overspend | Conservative; depends on request fields |
| Post-charge actual usage | Allow request, then charge actual `usage.total_tokens` | Accurate accounting | Can overshoot quota |
| Reserve then reconcile | Reserve prompt + max output, then refund unused tokens | Stronger enforcement | More state complexity |
| Provider usage only | Trust response `usage.total_tokens` | Fastest POC | Not enough for strict quota |

Recommended order:

1. Post-charge actual usage from non-streaming responses.
2. Add pre-admit based on prompt estimate and `max_tokens`.
3. Add reserve/reconcile once shared state is stable.
4. Add streaming support.

### 5. Metrics and Usage Events

MaaS dashboards currently depend on Limitador metrics:

| Metric | Current meaning |
|---|---|
| `authorized_hits` | token usage, normally from `usage.total_tokens` |
| `authorized_calls` | allowed requests |
| `limited_calls` | rejected/rate-limited requests |

Praxis should emit native metrics first:

| Metric | Labels |
|---|---|
| `praxis_token_usage_total` | route, model, subscription, token_type |
| `praxis_token_limit_decisions_total` | route, model, policy, decision, reason |
| `praxis_token_limit_remaining` | route, model, policy |
| `praxis_token_limit_backend_errors_total` | backend, reason |
| `praxis_token_limit_backend_latency_seconds` | backend, operation |

Compatibility metrics can be added later if MaaS dashboards need to
read old names, but native Praxis names should be the source of truth
for the POC.

Cardinality rule: do not label by raw API key. Be careful with user
labels. Subscription/model/route are acceptable for the POC if bounded.

## Issue Mapping

| Issue | Phase 4 role | Notes |
|---|---|---|
| [#20 Token Counting](https://github.com/praxis-proxy/praxis/issues/20) | Core dependency | Count input tokens, output tokens, inject counts into context, support provider-specific tokenizer selection, examples/tests |
| [#21 Token Rate Limiting](https://github.com/praxis-proxy/praxis/issues/21) | Core dependency | Per-client token quotas, token-aware 429, headers, depends on #20 |
| [#65 Stateful Options](https://github.com/praxis-proxy/praxis/issues/65) | Required for shared counters | Needs concrete Redis/Valkey token counter design or child implementation issue |
| [#19 AI Inference](https://github.com/praxis-proxy/praxis/issues/19) | Response/SSE inspection and AI filter composition | SSE streaming inspection and token-aware routing are directly relevant |
| [#8 Prometheus Metrics](https://github.com/praxis-proxy/praxis/issues/8) | Usage/decision observability | Existing `/metrics` is partial; token metrics and cardinality controls remain |
| [#9 Per-filter metrics](https://github.com/praxis-proxy/praxis/issues/9) | Performance visibility | Useful to measure token filter overhead |
| [#10 Distributed Tracing](https://github.com/praxis-proxy/praxis/issues/10) | Debuggability | Useful for auth -> token limit -> upstream -> response accounting flow |
| [#11 Dynamic Configuration Reloading](https://github.com/praxis-proxy/praxis/issues/11) | Needed for controller-driven policies | Static POC can restart pods; production needs reload/config watch |
| [#40 Filter pipeline architecture](https://github.com/praxis-proxy/praxis/issues/40) | Ordering and dependency validation | Token filters depend on auth/model metadata and response parsing |
| [#75 StreamBuffer pre-read body forwarding limited to 64 KiB](https://github.com/praxis-proxy/praxis/issues/75) | Large prompt risk | Any prompt/body token counting must not truncate or lose large bodies |

New issues likely needed:

| Proposed issue | Why |
|---|---|
| Redis/Valkey token counter backend | #65 is a spike; implementation needs a concrete issue |
| OpenAI-compatible usage parser filter | Fastest path for non-streaming token accounting |
| MaaSSubscription-to-Praxis config adapter | Praxis needs token limits from MaaS CRDs without hand-written YAML |
| Token usage metrics compatibility | Decide whether to emit `authorized_hits`-like compatibility metrics |
| Streaming/SSE token accounting | Separate from non-streaming response usage parsing |

## Suggested Implementation Slices

### Slice 1: Response Usage Parser

Goal: parse `usage.total_tokens` from OpenAI-compatible JSON
responses and store token counts in filter metadata/logs/metrics.

Acceptance criteria:

- non-streaming OpenAI response with `usage.total_tokens` is parsed
- missing `usage` is handled predictably
- metrics emit token usage by model/subscription where metadata exists
- no quota enforcement yet

### Slice 2: Static Token Budget Filter

Goal: enforce a static per-subscription/model token budget using
local state.

Acceptance criteria:

- config defines token quota and window
- response usage charges the quota
- later requests reject after budget is exhausted
- 429 response includes token-limit reason
- docs state this is single-pod only

### Slice 3: Pre-Admit Estimate

Goal: reject requests before upstream when estimated max token usage
would exceed remaining budget.

Inputs:

- prompt token estimate or count
- request `max_tokens`
- current remaining budget

Acceptance criteria:

- request can be rejected before upstream
- rejection metrics distinguish pre-admit from post-charge
- actual usage still reconciles after successful responses

### Slice 4: Shared Redis/Valkey Backend

Goal: make token counters correct across multiple Praxis replicas.

Acceptance criteria:

- atomic counter update
- TTL/window behavior works
- backend errors follow configured failure mode
- two Praxis replicas share quota state

### Slice 5: MaaSSubscription Adapter

Goal: stop hand-writing token limits and consume MaaS policy data.

Options:

- POC script renders Praxis config from `MaaSSubscription`
- sidecar watches MaaS CRDs and writes config
- MaaS controller emits Praxis config directly

Acceptance criteria:

- `MaaSSubscription` token limits are reflected in Praxis config
- config update path is documented
- invalid/missing policy fails safely

### Slice 6: Streaming Support

Goal: support streaming chat completions.

Acceptance criteria:

- SSE chunks pass through correctly
- usage metadata is parsed if provider sends final usage
- local output token counting is planned or implemented if provider
  does not send usage
- quotas account for streaming output without breaking stream delivery

## Validation Plan

Initial validation should use the clean Gateway from Phase 3B so
Kuadrant/Limitador do not participate.

Required tests:

| Test | Expected |
|---|---|
| valid key under quota | 200 |
| token usage metric increments | yes |
| repeated calls exhaust static token budget | later request gets 429 |
| invalid key | 403/401 from Praxis auth |
| missing usage field | configured behavior: reject, allow without charge, or charge estimate |
| existing MaaS route still works | control path remains healthy |
| Limitador counters do not move for clean route | proves Praxis token path is independent |
| two Praxis replicas share state | required only after Redis/Valkey slice |

## Definition of Done

Phase 4 is complete for the POC when:

- Praxis reads or receives a token limit for one MaaS subscription/model.
- Praxis parses token usage from one OpenAI-compatible response path.
- Praxis enforces token quota for the targeted route.
- Praxis exports token usage and token-limit decision metrics.
- Validation proves Limitador is not involved on the targeted route.
- The docs clearly state limitations: model coverage, streaming status,
  local/shared state status, and metric compatibility status.

## Non-Goals

- Full provider translation.
- Full billing export API.
- Replacing MaaS controller or `maas-api`.
- Replacing Gateway Envoy.
- Perfect tokenizer parity for every provider in the first slice.
- Multi-model dynamic policy reload in the first slice.
