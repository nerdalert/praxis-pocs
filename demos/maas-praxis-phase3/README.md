# MaaS + Praxis Phase 3A — Praxis-Owned Auth + Rate Limiting

Phase 3A proves that Praxis can own the auth and rate-limit
**decisions** on a MaaS route. The ext-auth filter validates
MaaS API keys via `maas-api`, and the descriptor rate limiter
enforces request-admission limits keyed by subscription.

## Accurate Status

Kuadrant wasm, Authorino, and Limitador are **still mechanically
in the request path** on this shadow route. They are configured
as pass-through — the AuthPolicy accepts any bearer token and
the TRLP allows 1M req/min. Praxis makes the real auth/rate-limit
decisions.

**Why pass-through policies are needed:** The shared
`maas-default-gateway` has gateway-level default-deny policies
(AuthPolicy + TokenRateLimitPolicy). Without route-level overrides,
traffic is blocked before it reaches Praxis. Praxis itself does
not need Kuadrant — the pass-through policies exist only to
satisfy the gateway defaults.

| Claim | Accurate? |
|-------|-----------|
| Praxis owns auth decisions (key validation) | Yes |
| Praxis owns rate-limit decisions (descriptor) | Yes |
| Kuadrant wasm is absent from request path | **No** — wasm still present via pass-through |
| Authorino is not called | **No** — Authorino logs show shadow route auth |
| Limitador counters do not increment | **No** — Limitador metrics increment on shadow route |

## Validation Results

5/5 tests passing via `validate.sh`:

| Test | Description | Expected | Result |
|------|------------|----------|--------|
| 1 | Valid MaaS key → Praxis auth → OpenAI | HTTP 200 | **PASS** |
| 2 | Invalid key rejected by Praxis | HTTP 403 | **PASS** |
| 3 | Missing auth rejected by Praxis | HTTP 401 | **PASS** |
| 4 | `/metrics` shows `praxis_auth_allowed_total` | Present | **PASS** |
| 5 | `/metrics` shows descriptor rate limit decisions | Present | **PASS** |

## Artifacts

| Artifact | Reference |
|---|---|
| Praxis branch | [`feat/maas-phase2`](https://github.com/nerdalert/praxis/tree/feat/maas-phase2) |
| Image | `ghcr.io/nerdalert/praxis:maas-phase2` |
| Phase 2 demo | [`demos/maas-praxis-phase2/`](../maas-praxis-phase2/) |

## Request Flow

```
Client
  │
  ▼
maas-default-gateway (Envoy)
  │
  ├── Kuadrant WasmPlugin (pass-through AuthPolicy + permissive TRLP)
  │     └── Authorino: passthrough auth (any bearer accepted)
  │     └── Limitador: permissive TRLP (1M req/min)
  │
  ▼
praxis-phase3 Service (:8080)
  │
  ├── observability: request_id + access_log
  ├── auth: http_ext_auth → maas-api /internal/v1/api-keys/validate
  │     └── valid:true  → set filter_metadata (user_id, subscription, key_id)
  │     └── valid:false → 403 Forbidden
  │     └── missing auth → 401 Unauthorized
  ├── limit: rate_limit (descriptor mode, keyed by auth.subscription)
  ├── normalize: path_rewrite (strip /praxis-maas/gpt-4o)
  ├── inject-credentials: set Authorization (OpenAI key), Host, strip internal headers
  └── route: router + load_balancer → api.openai.com:443 (TLS)
```

Praxis makes all meaningful decisions (auth validation,
rate limiting, credential injection, routing). The Kuadrant
components above it are configured to allow everything through.

## How Auth Works Without Authorino

Praxis validates MaaS API keys by calling `maas-api` directly.
Praxis does not store API-key hashes and does not become the key
database. `maas-api` remains the source of truth.

```text
Client
  -> Authorization: Bearer sk-oai-...
  -> Praxis http_ext_auth
     -> extracts sk-oai-* token
     -> POST {"key":"sk-oai-..."} to maas-api
        /internal/v1/api-keys/validate
     -> maas-api checks key hash, status, expiration, and subscription
     -> maas-api returns valid:true or an invalid response
     -> Praxis allows or rejects
```

The important split:

| Component | Role |
|---|---|
| `maas-api` | Source of truth for MaaS API keys and subscriptions |
| Praxis `http_ext_auth` | Enforcement point that calls `maas-api` and turns the result into allow/deny |
| Authorino | Not required for this key-validation step once the request reaches Praxis |

Auth is enabled by the Praxis config, not hardcoded globally. The
Phase 3 manifest opts into auth by placing `http_ext_auth` in the
listener filter chain:

```yaml
listeners:
  - name: default
    filter_chains:
      - observability
      - auth
      - limit
      - normalize
      - inject-credentials
      - route

filter_chains:
  - name: auth
    filters:
      - filter: http_ext_auth
        endpoint: "https://maas-api.opendatahub.svc.cluster.local:8443/internal/v1/api-keys/validate"
        timeout_ms: 2000
        tls_skip_verify: true
        response:
          metadata:
            auth.user_id: userId
            auth.username: username
            auth.key_id: keyId
            auth.subscription: subscription
        strip:
          request_headers:
            - authorization
```

If the `auth` chain or `http_ext_auth` filter is removed from the
listener, Praxis does not perform this auth callout. The filter is
currently configurable for endpoint, timeout, TLS verification,
response-to-metadata mapping, response-to-header mapping, stripped
headers, and pipeline `failure_mode`.

The current `http_ext_auth` implementation is still intentionally
MaaS-shaped: it reads `Authorization: Bearer <token>` and sends
`{"key":"<token>"}` to the configured endpoint, then requires
`valid:true`. Making token sources, request body shape, and allow/deny
response fields fully generic is future `#14` / `#12` work.

On Phase 3A's shared `maas-default-gateway`, Authorino is still
mechanically touched by the pass-through `AuthPolicy`. That is only
to satisfy gateway-level default-deny behavior. Phase 3B's clean
Gateway path is the proof point for running this auth flow with no
Authorino involvement.

## How Rate Limiting Works Without TRLP

MaaS uses `TokenRateLimitPolicy` (TRLP) → Limitador → Redis for
request and token rate limiting. Praxis replaces the
request-counting slice of that pipeline with a local descriptor
rate limiter. Token quotas are not yet implemented.

### What TRLP does in MaaS today

```yaml
# MaaS TRLP shape (Kuadrant v1alpha1)
apiVersion: kuadrant.io/v1alpha1
kind: TokenRateLimitPolicy
spec:
  targetRef:
    kind: HTTPRoute
    name: gpt-4o
  limits:
    per-user:
      counters:
        - expression: auth.identity.userid   # CEL on Authorino identity
      rates:
        - limit: 100        # count
          window: 1m         # fixed window
```

TRLP defines rate limits as **count per fixed window** (e.g.
100 req/min), keyed by **CEL counter expressions** evaluated
against Authorino's auth context. Limitador enforces the
counters and stores state in Redis, so limits are consistent
across all gateway replicas.

### What Praxis does instead

```yaml
# Praxis rate_limit config shape
- filter: rate_limit
  mode: descriptor
  rate: 10                          # tokens per second (≈600 req/min)
  burst: 20                         # max bucket capacity
  descriptor:
    name: praxis-auth-subscription
    sources:
      - context: auth.subscription  # from http_ext_auth metadata
    missing: skip
  failure_mode: open
```

Praxis uses a **token bucket** algorithm with `rate` in
**tokens/second** and `burst` as max capacity. Descriptor keys
are built from filter metadata (set by `http_ext_auth`) or
trusted request headers — not CEL expressions.

### Key differences

| Aspect | MaaS TRLP + Limitador | Praxis descriptor rate_limit |
|--------|----------------------|------------------------------|
| **Rate unit** | count per window (`limit: 100`, `window: 1m`) | tokens/second (`rate: 10`, `burst: 20`) |
| **Algorithm** | Fixed or sliding window (Limitador) | Token bucket (local) |
| **Key source** | CEL counter expressions on Authorino identity | Filter metadata or trusted headers |
| **State backend** | Redis (distributed across replicas) | Local `DashMap` (per pod) |
| **Multi-replica** | Consistent — shared Redis counters | **Not consistent** — each pod has its own bucket |
| **Config location** | TRLP CRD on HTTPRoute/Gateway | Praxis YAML `filter_chains` |
| **Limit lifecycle** | Kuadrant controller reconciles CRD changes | Praxis pod restart reloads config |
| **Missing key** | Depends on counter expression eval | Configurable: `reject` (429) or `skip` |
| **Token counting** | Supported (token quotas via TRLP) | **Not implemented** — request counts only |

### How limits are configured today

Praxis rate limits are **hardcoded in the Praxis config YAML**,
not read from any CRD or MaaS API. The Phase 3 config sets
`rate: 10` / `burst: 20` per subscription — this is a static
value baked into the ConfigMap.

MaaS TRLP limits are defined per-route or per-gateway by the
platform operator via CRD, reconciled by the Kuadrant controller,
and enforced by Limitador. Changing a limit is a `kubectl apply`
on the TRLP resource.

To reach parity, Praxis would need to either:
1. Read limit values from a CRD or API at startup/reload, or
2. Accept a Praxis-native CRD that a controller reconciles
   into config updates

Neither is implemented. Today, changing a Praxis rate limit
means editing the ConfigMap and restarting the pod.

## Parity Summary

| Capability | MaaS (Kuadrant stack) | Praxis Phase 3 | Parity |
|------------|----------------------|----------------|--------|
| **API key validation** | Authorino → maas-api | http_ext_auth → maas-api | **Yes** — same backend, same validation |
| **Key metadata extraction** | Authorino identity context | http_ext_auth → filter_metadata | **Yes** — userId, subscription, keyId |
| **Request rate limiting** | TRLP → Limitador → Redis | descriptor rate_limit (local) | **Partial** — works but local-only, static config |
| **Per-subscription limits** | TRLP counter expression on identity | descriptor key from auth.subscription | **Yes** — same granularity |
| **Per-user limits** | TRLP counter on auth.identity.userid | descriptor source from auth.user_id | **Yes** — same granularity possible |
| **Distributed rate state** | Redis via Limitador | Not implemented | **No** |
| **Token counting** | TRLP token quotas (#20, #21) | Not implemented | **No** |
| **Dynamic limit changes** | CRD apply → controller reconcile | Config edit → pod restart | **No** |
| **Credential injection** | MaaS controller → ExternalModel | Praxis headers filter | **Yes** |
| **Provider routing + TLS** | ExternalName Service + DestinationRule | Praxis router + load_balancer | **Yes** |
| **Path normalization** | MaaS ext-proc / wasm-shim | Praxis path_rewrite | **Yes** |
| **Observability** | Limitador /metrics, Authorino logs | Praxis /metrics (auth + rate_limit counters) | **Partial** — different metric names/shapes |
| **Multi-replica consistency** | Yes (Redis) | No (local state) | **No** |

### What has parity

- Auth validation: same backend (`maas-api`), same semantics
  (`valid:true` required, fail-closed on anything else)
- Metadata extraction: same fields surfaced (subscription,
  userId, keyId, username)
- Request-count rate limiting by subscription: same
  granularity, different algorithm (token bucket vs fixed window)
- Credential injection and provider routing: full parity
- Path normalization: full parity

### What does NOT have parity

- **Distributed state**: Praxis rate limits are per-pod.
  Two replicas each allow `rate` req/s independently.
  Needs Redis/Valkey backend (#65).
- **Token quotas**: TRLP can limit by prompt/completion
  tokens. Praxis has no token counting yet (#20, #21).
- **Dynamic config**: TRLP changes via CRD apply; Praxis
  needs a pod restart. No CRD/controller integration.
- **Metric compatibility**: Praxis emits
  `praxis_rate_limit_decisions_total` and `praxis_auth_*_total`;
  Limitador emits `authorized_calls`, `limited_calls`. Dashboards
  would need updating.

## Configuration

### Praxis filter chain (`praxis-phase3.yaml`)

- **`http_ext_auth`** — calls `maas-api` with `{"key":"<bearer>"}`,
  requires `valid: true` in response. Maps `userId`, `username`,
  `keyId`, `subscription` to filter metadata. Strips `Authorization`
  before upstream.
- **`rate_limit` (descriptor)** — keyed by `auth.subscription`
  from metadata. 10 req/s with burst of 20.
- **`path_rewrite`** — strips `/praxis-maas/gpt-4o` prefix.
- **`headers`** — injects OpenAI credentials and `Host: api.openai.com`.
  Strips `x-maas-subscription` before upstream.
- **`router` + `load_balancer`** — routes to `api.openai.com:443`
  with TLS SNI.

### Shadow route (`shadow-route.yaml`)

- **HTTPRoute** — `/praxis-maas` → `praxis-phase3:8080`
- **AuthPolicy** — passthrough: accepts any bearer token,
  delegates real validation to Praxis `http_ext_auth`
- **TokenRateLimitPolicy** — permissive: 1M req/min, overrides
  gateway default-deny

## Dev-Only Settings

The current config has settings appropriate for POC validation
that **must not** be used in production:

| Setting | Current | Production |
|---------|---------|------------|
| `tls_skip_verify` | `true` | `false` — use real certs or mount OpenShift serving CA |
| `missing` (rate limit) | `skip` | `reject` — enforce rate limits when subscription metadata is missing |
| `failure_mode` (rate limit) | `open` | `closed` (default) — fail requests on rate limiter errors |

## Known Limitations

1. **Kuadrant wasm still in path** — WasmPlugin includes
   `/praxis-maas` action sets. Authorino and Limitador
   metrics increment on shadow route requests.

2. **MaaS controller reconciliation** — the MaaS controller
   may revert HTTPRoute `backendRef` patches on ExternalModel
   updates. Re-run `deploy.sh` to re-apply.

3. **Request-admission only** — this is request-count
   limiting, not token quotas. Token counting (#20) +
   token-aware rate limiting (#21) remain Phase 3c.

4. **Single replica** — descriptor rate-limit state is
   local to the Praxis pod. Multi-replica deployments
   need a shared backend (Redis/Valkey).

## True Bypass Validation (Phase 3B)

Praxis **can** operate without Kuadrant/AuthPolicy/TRLP/
Authorino/Limitador. The current setup only uses pass-through
policies because the shared gateway blocks traffic without them.

### Current blocker

```
maas-default-gateway
  → gateway-level AuthPolicy (default deny)
  → gateway-level TokenRateLimitPolicy (default deny)
```

Removing the route-level pass-through policies while using
this gateway would block traffic before Praxis sees it.

### Ways to run without Kuadrant

1. **Direct service/port-forward** —
   `client → praxis-phase3 Service → Praxis → OpenAI`.
   Bypasses Envoy/Kuadrant entirely. Good for proving
   standalone behavior.

2. **Dedicated clean Gateway** (recommended) —
   `client → clean Gateway (no Kuadrant policies) → Praxis → OpenAI`.
   Best cluster proof. Keep `maas-default-gateway` unchanged,
   create a separate Gateway/HTTPRoute without any Kuadrant
   policy attachment.

3. **OpenShift Route or LoadBalancer directly to Praxis** —
   `client → OpenShift Route → Praxis → OpenAI`.
   Also bypasses Kuadrant, but less aligned with Gateway API.

4. **Use the real `/llm/gpt-4o` route** —
   Possible, but risky. MaaS controller may reconcile it,
   and it risks breaking the known-good MaaS path.

### Phase 3B: Clean Gateway validation

A dedicated clean Gateway + HTTPRoute with no Kuadrant policy
attachment. Proves Praxis operates without any Kuadrant
components in the request path.

```
Client
  → praxis-clean-gateway (no AuthPolicy, no TRLP)
  → HTTPRoute /praxis-maas
  → praxis-phase3
  → maas-api validation (inside Praxis)
  → OpenAI
```

**Deploy:**

```bash
./demos/maas-praxis-phase3/deploy-clean-gateway.sh
```

**Validate (8 checks):**

```bash
./demos/maas-praxis-phase3/validate-clean-gateway.sh
```

| Test | Description | Expected |
|------|------------|----------|
| 1 | No AuthPolicy targets clean resources | No matches |
| 2 | No TRLP targets clean resources | No matches |
| 3 | Valid MaaS key → clean gateway → OpenAI | HTTP 200 |
| 4 | Invalid key rejected | HTTP 403 |
| 5 | Missing auth rejected | HTTP 401 |
| 6 | Praxis auth metrics increment | Counter increases |
| 7 | Praxis rate-limit metrics increment | Counter increases |
| 8 | Limitador has no counters for clean route | No matches |

**Rollback:**

```bash
oc delete httproute praxis-clean-phase3 -n llm
oc delete gateway praxis-clean-gateway -n openshift-ingress
```

## Usage

### Phase 3A: Shadow route (Kuadrant pass-through)

```bash
OPENAI_API_KEY='sk-...' ./demos/maas-praxis-phase3/deploy.sh
./demos/maas-praxis-phase3/validate.sh
```

### Phase 3B: Clean gateway (no Kuadrant)

```bash
# Requires Phase 3A deployment first
./demos/maas-praxis-phase3/deploy-clean-gateway.sh
./demos/maas-praxis-phase3/validate-clean-gateway.sh
```

## Next Phases

| Phase | Target | Status |
|-------|--------|--------|
| Phase 3B | True Kuadrant bypass (dedicated clean Gateway) | **Validated** (7/7 + Limitador confirmed absent) |
| Phase 3c | Token counting + token-aware limits (#20, #21) | Not started |
| Phase 3d | Distributed rate-limit state (Redis/Valkey) | Not started (#65) |
| Phase 3e | Dynamic limit config (CRD or API-driven) | Not started |
| Phase 4 | Praxis as the gateway (#7, #33, #39) | Not started |
