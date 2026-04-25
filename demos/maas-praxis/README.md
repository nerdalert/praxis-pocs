# MaaS + Praxis Integration

Praxis replaces the ext-proc/BBR body-processing pipeline
in MaaS — the payload-processing pod and its four plugins
(body-field-to-header, model-provider-resolver,
api-translation, apikey-injection) — by doing body-aware
routing, credential injection, and provider egress inline.
No gRPC sidecar, no ext-proc EnvoyFilter, no separate
payload-processing pod. Envoy remains the gateway proxy —
Praxis runs behind it as a backend, not a replacement.

The Kuadrant gateway wasm plugin (auth + rate limiting)
is a separate component and is NOT replaced. It continues
to call Authorino for API key validation and Limitador
for per-subscription token rate limits, exactly as before.

This demo validates Praxis as a drop-in replacement for
the body-processing data path in a production MaaS stack,
while preserving the full MaaS auth, subscription, and
rate-limiting enforcement provided by Kuadrant, Authorino,
and Limitador.

## Phase Status

- **[Phase 1 — ext-proc/BBR Replacement](phase-1-completion.md): COMPLETE**

## Current Status

| Test | Result |
|------|--------|
| Body-based model routing (mock backends) | **Passing** |
| Body forwarding verified (upstream echoes body) | **Passing** |
| External model via Praxis → OpenAI (direct path) | **Passing** |
| External model via MaaS API key → Praxis → OpenAI | **Passing** |
| In-cluster model (facebook/opt-125m simulator) | **Passing** |
| MaaS API key minting via subscription | **Passing** |
| Auth rejection (bogus keys, no auth, header injection) | **Passing** |
| Model listing (`/v1/models`) | **Passing** |

## Patches and Changes Required

Three repositories are modified for this integration.
No changes are made to `models-as-a-service` source code —
only install-time patches to the running cluster.

### 1. Praxis — [`nerdalert/praxis`](https://github.com/nerdalert/praxis/tree/feat/dns-and-request-headers)

Branch: `feat/dns-and-request-headers`

| Commit | Change | Why |
|--------|--------|-----|
| `9888295` | DNS resolution for upstream endpoints | Praxis parsed upstream addresses as `IP:port` only. MaaS ExternalModel uses DNS hostnames like `api.openai.com:443`. Added `ToSocketAddrs` fallback in `upstream_peer.rs`. |
| `9888295` | `request_set` / `request_remove` on header filter | Praxis could only `request_add` headers. MaaS needs Host and Authorization headers *replaced*, not appended. Without `request_set`, Cloudflare rejects duplicate Host headers and OpenAI rejects duplicate Authorization. Added `request_set` and `request_remove` to `HeaderFilter`, wired through `HttpFilterContext.remove_request_headers` and the protocol layer's `RequestHeaderOps`. |
| `e7744c2` | StreamBuffer body forwarding fix | After `model_to_header` inspects the body and returns `Release`, post-Release chunks were discarded from the replay buffer. The upstream received an empty or truncated body. Removed the `!released` guard on `buffer.push()` in `stream_buffer.rs` so all chunks are buffered regardless of Release state. |
| `a235509` | Pingora dependency update | Points `Cargo.toml` to `nerdalert/pingora` fork which includes the initial-send fix for body replay after StreamBuffer pre-read. |

### 2. Pingora — [`nerdalert/pingora`](https://github.com/nerdalert/pingora/tree/feat/streambuffer-initial-send)

Branch: `feat/streambuffer-initial-send`

| Commit | Change | Why |
|--------|--------|-----|
| `0482d58` | Initial body send when downstream already done | After Praxis pre-reads the full body during StreamBuffer inspection, Pingora's downstream is marked as "done." Pingora's transport layer only performed an initial body send for retry buffers or empty bodies — it skipped the case where downstream was already consumed. Without this, Pingora entered `read_body_or_idle(done=true)` which called `idle()` and waited for the TCP connection to close. The upstream never received the body. Added `should_send_initial_body()` helper that also triggers when `downstream_done == true`. Applied to h1, h2, and custom transport paths. |

Note: Praxis already depended on a custom Pingora fork
(`praxis-proxy/pingora`) for ServerConfig and WrappedX509
patches. The `nerdalert/pingora` fork is based on that
same branch with one additional commit.

### 3. MaaS — runtime patches (no source changes)

These are cluster-time patches applied during deployment.
No changes to the `models-as-a-service` repository.

| Patch | What | Why |
|-------|------|-----|
| Authorino TLS workaround | Replace operator-managed TLS args with explicit cert paths, mount OpenShift service serving cert | The Authorino operator generates TLS config that doesn't match the wasm plugin's expectations. Gateway returns 500 with `gRPC status code is not OK`. |
| Authorino operator scale 0/1/0 | Briefly scale operator to 1 for CR status reconciliation, then back to 0 | Kuadrant policy controller requires Authorino CR `status.Ready=True` to enforce AuthPolicies. The operator must run briefly to set this status. Without it, all AuthPolicies show `Enforced: False` and routes return 404. |
| gpt-4o HTTPRoute backendRef patch | Change backendRef from `gpt-4o:443` (ExternalName) to `praxis-gateway:8080` | Routes the MaaS model path through Praxis instead of directly to the ExternalName Service. This is the key integration point — MaaS auth + subscription policies stay attached to the HTTPRoute while Praxis handles the provider egress. |
| Istio sidecar injection removed | Remove `istio-injection=enabled` label from `llm` namespace | Istio sidecar injection causes init container hangs for the Python echo backends and Praxis pods. Praxis handles its own upstream TLS. |

## What Praxis Replaces

Praxis replaces the **BBR/ext-proc body-processing pipeline**,
not the Kuadrant auth/rate-limit wasm plugin. These are two
separate components in the MaaS gateway:

- **Kuadrant wasm plugin** — auth + rate limiting. Calls
  Authorino and Limitador. **Still running.**
- **ext-proc/BBR pipeline** — body inspection, model
  extraction, provider resolution, credential injection.
  **Replaced by Praxis.**

| MaaS Component | What it does | Praxis replacement | Status |
|---|---|---|---|
| ext-proc gRPC sidecar (payload-processing pod) | Separate pod for body inspection via gRPC — runs body-field-to-header, model-provider-resolver, api-translation, apikey-injection plugins | Eliminated — Praxis inspects body inline via StreamBuffer | **Done** |
| EnvoyFilter for ext-proc | Istio CRD wiring ext-proc into gateway Envoy | Eliminated — not needed | **Done** |
| body-field-to-header plugin | Reads request body over gRPC, extracts `model` field, returns header mutation | `model_to_header` filter — reads body in-process, promotes field to header | **Done** |
| model-provider-resolver plugin | Watches MaaS CRDs at runtime, resolves model name → provider endpoint + transport config | `router` filter with static YAML config — model→cluster mapping defined at deploy time | **Done** (static only) |
| apikey-injection plugin | Reads provider credential from K8s Secret via CRD reference, injects as Authorization header | `request_set` filter — overwrites Authorization header with static value from ConfigMap | **Done** (static only) |
| ExternalName Service | Kubernetes DNS-based routing to external provider hostname | Praxis `load_balancer` with DNS resolution + upstream TLS + SNI | **Done** |
| Envoy upstream routing | Routes by `X-Gateway-Model-Name` header to ExternalName backend | Praxis `router` matches by path/header, `load_balancer` selects endpoint | **Done** |

## What Is NOT Replaced

| MaaS Component | What it does | Status |
|---|---|---|
| Kuadrant wasm plugin | Gateway-level Envoy plugin that calls Authorino (auth) and Limitador (rate limits) | **Unchanged** — this is NOT the wasm-shim that Praxis replaces. This is the Kuadrant auth/rate-limit enforcement layer that runs in the gateway Envoy before traffic reaches any backend. |
| Authorino | API key validation, K8s token auth, subscription checks, OPA authorization | **Unchanged** — called by the Kuadrant wasm plugin before traffic reaches Praxis |
| Limitador | Per-subscription token rate limiting | **Unchanged** — called by the Kuadrant wasm plugin before traffic reaches Praxis |
| maas-api | REST API for key minting, subscription management, model catalog | **Unchanged** |
| MaaS controller | Reconciles ExternalModel → HTTPRoute + Service + AuthPolicy + TRLP | **Unchanged** — creates the routes that Praxis backend-patches |
| KServe | LLMInferenceService lifecycle, in-cluster model deployment, HTTPRoute creation | **Unchanged** — handles the facebook/opt-125m simulator route directly |
| MaaS CRDs | ExternalModel, MaaSModelRef, MaaSAuthPolicy, MaaSSubscription | **Unchanged** — all CRD semantics preserved |
| api-translation plugin | Transforms request/response body between provider schemas (OpenAI ↔ Anthropic ↔ Mistral) | **Not implemented** — only matters for multi-provider routing |
| model-provider-resolver (dynamic) | Runtime CRD-driven model→endpoint resolution with watch | **Static config** — needs a config adapter sidecar for dynamic resolution |
| Secret-backed credential injection | Reads API key from K8s Secret referenced by ExternalModel CR | **Static config** — key injected into ConfigMap at deploy time via `deploy.sh` |

## Request Flows

### Flow 1: ExternalModel via MaaS API key (gpt-4o → OpenAI)

This is the primary integration path. The client uses a
MaaS API key minted via subscription. Authorino validates
the key. The HTTPRoute is patched to route to Praxis
instead of the ExternalName Service. Praxis handles path
rewriting, credential swap, DNS resolution, and TLS.

```
1. Client sends request
   POST https://maas.apps.<cluster>/llm/gpt-4o/v1/chat/completions
   Headers:
     Authorization: Bearer sk-oai-<maas-api-key>
     Content-Type: application/json
   Body: {"model":"gpt-4o","messages":[{"role":"user","content":"hello"}],"max_tokens":5}

2. DNS resolves gateway hostname → AWS ELB → Envoy gateway pod

3. Envoy runs Kuadrant wasm plugin
   → gRPC call to Authorino (TLS on port 50051)
   → Authorino validates sk-oai-* API key via maas-api /internal/v1/api-keys/validate
   → Checks subscription status and group membership via OPA
   → Limitador checks per-subscription token rate limit
   → Auth response injects identity headers for downstream

4. HTTPRoute "gpt-4o" (created by MaaS ExternalModel reconciler)
   Rule: PathPrefix /llm/gpt-4o → backendRef praxis-gateway:8080
   *** PATCHED: original backendRef was gpt-4o:443 (ExternalName) ***
   Filter: RequestHeaderModifier sets Host: api.openai.com
   Associated policies (attached to HTTPRoute, not backend):
     - AuthPolicy "maas-auth-gpt-4o": API key + subscription validation
     - TokenRateLimitPolicy "maas-trlp-gpt-4o": per-subscription token quota
   Envoy forwards request (plain HTTP) to Praxis Service ClusterIP :8080

5. Praxis receives on listener :8080
   Filter chain: observability → normalize → inject-credentials → route

6. Filter: path_rewrite
   Condition: path_prefix "/llm/gpt-4o/"
   Action: strips prefix → /llm/gpt-4o/v1/chat/completions → /v1/chat/completions

7. Filter: headers (request_set)
   Overwrites Authorization: Bearer sk-oai-<maas-key> → Bearer sk-proj-<openai-key>
   Overwrites Host: api.openai.com (redundant — gateway already set this,
   but Praxis sets it explicitly for the upstream TLS connection)

8. Filter: router
   Matches path_prefix "/" → selects cluster "openai"

9. Filter: load_balancer
   Cluster "openai" endpoint: api.openai.com:443
   DNS resolves api.openai.com → Cloudflare IP (e.g. 172.66.x.x)
   Establishes upstream TLS with SNI: api.openai.com

10. Pingora sends request to api.openai.com:443
    POST /v1/chat/completions (rewritten path)
    Host: api.openai.com
    Authorization: Bearer sk-proj-<openai-key> (swapped credential)
    Body: original JSON forwarded intact

11. OpenAI processes request → returns completion

12. Response flows: OpenAI → Praxis → Envoy gateway → Client
    Client receives: {"model":"gpt-4o-2024-08-06","choices":[{"message":{"content":"Ok."}}],...}
```

### Flow 2: ExternalModel via direct Praxis path (/praxis-gw/)

Same as Flow 1 but bypasses MaaS auth. Uses a K8s token
with audience `maas-default-gateway-sa` for gateway auth.
Useful for testing the Praxis routing path independently
of MaaS subscription management.

```
1. Client POST https://<gateway>/praxis-gw/v1/chat/completions
   Authorization: Bearer <k8s-token> (audience: maas-default-gateway-sa)

2. Gateway → Authorino validates K8s token (Praxis-specific AuthPolicy)

3. HTTPRoute "praxis-gateway-demo" → praxis-gateway:8080
   AuthPolicy: simple K8s token check (no subscription)
   TokenRateLimitPolicy: 100 req/min flat

4. Praxis: path_rewrite strips /praxis-gw → /v1/chat/completions
5. Praxis: request_set swaps Auth + Host
6. Praxis: router → openai cluster → DNS → TLS → api.openai.com
7. OpenAI responds → Client
```

### Flow 3: BBR replacement (body routing to mock backends)

Proves that Praxis can read the request body, extract
routing signals, make a routing decision, and forward
the complete original body to the selected upstream.
This is the core capability that replaces ext-proc/BBR.

```
1. Client POST https://<gateway>/praxis/v1/chat/completions/
   Authorization: Bearer <k8s-token>
   Body: {"model":"qwen","messages":[{"role":"user","content":"hello"}]}

2. Gateway → Authorino validates K8s token

3. HTTPRoute "praxis-bbr-demo" → praxis:8080

4. Praxis: model_to_header filter activates StreamBuffer mode
   a. Reads request body chunks from downstream connection
   b. Pushes ALL chunks into buffer (including post-Release)
   c. Parses JSON, extracts "model" field → "qwen"
   d. Promotes to header: X-AI-Model: qwen
   e. Filter returns Release
   f. Buffer frozen into pre_read_body deque

5. Praxis: router matches X-AI-Model: qwen → cluster "qwen"
   load_balancer selects echo-qwen pod by ClusterIP

6. Pingora connects to echo-qwen:8080
   Downstream is already done (body consumed in step 4)
   *** PINGORA FIX: should_send_initial_body(downstream_done=true) ***
   Calls request_body_filter → Praxis pops pre_read_body deque
   Sends complete body to upstream

7. Echo backend (Python HTTP server) reads body via Content-Length
   Parses JSON, extracts model + messages[0].content
   Returns: {"model":"qwen","forwarded_model":"qwen","forwarded_prompt":"hello",...}

8. Validation script checks:
   - .model == "qwen" (backend identity)
   - .forwarded_model == "qwen" (body arrived, model field intact)
   - .forwarded_prompt == "hello" (body arrived, message content intact)
```

### Flow 4: LLMInferenceService (in-cluster model)

The facebook/opt-125m simulator runs in-cluster via
KServe. This path does NOT go through Praxis — KServe
manages the HTTPRoute and routes directly to the workload.
MaaS auth and subscription policies still apply.

```
1. Client POST https://<gateway>/llm/facebook-opt-125m-cpu/v1/chat/completions
   Authorization: Bearer sk-oai-<maas-api-key>

2. Gateway → Authorino validates API key + subscription

3. KServe HTTPRoute → workload Service :8000
   URLRewrite: /llm/facebook-opt-125m-cpu/v1/chat/completions → /v1/chat/completions
   Backend: facebook-opt-125m-cpu-kserve-workload-svc (in-cluster, HTTPS)

4. Simulator (llm-d-inference-sim) processes request
   Returns simulated completion with random tokens

5. Response → Gateway → Client
```

## StreamBuffer Body Forwarding

The StreamBuffer fix is the most significant technical
change. See [docs/streambuffer.md](../../docs/streambuffer.md)
for the full analysis.

**The problem:** Praxis reads the request body to extract
routing signals, but the upstream must still receive the
complete original body.

**Two fixes required:**

1. **Praxis** (`stream_buffer.rs`): buffer ALL chunks
   regardless of filter Release state. Previously,
   post-Release chunks were consumed from downstream but
   not stored for replay.

2. **Pingora** (`proxy_h1.rs`, `proxy_h2.rs`,
   `proxy_custom.rs`): trigger the initial body send when
   downstream is already done. Without this, Pingora
   enters `idle()` waiting for the TCP connection to close
   instead of calling `request_body_filter()` where Praxis
   replays the buffered body.

## BBR Plugin Replacement Detail

### body-field-to-header → `model_to_header`

| Aspect | BBR (ext-proc) | Praxis |
|---|---|---|
| Where body is read | ext-proc pod over gRPC | Inline via StreamBuffer |
| Latency | gRPC round-trip per request | Zero — same process |
| Field extraction | Plugin arg: `fieldName`, `headerName` | YAML config: `header` field |
| Nested fields | Top-level only | Top-level only |
| Body forwarding | Envoy manages via ext-proc stream | Praxis buffers + replays from deque |

### model-provider-resolver → `router`

| Aspect | BBR (ext-proc) | Praxis |
|---|---|---|
| Model→endpoint mapping | Dynamic from ExternalModel CRD (K8s watch) | Static YAML config |
| Runtime updates | Automatic via CRD reconciliation | Requires ConfigMap update + restart |
| Multi-model | Automatic from CRD inventory | Manual route/cluster per model |

### apikey-injection → `request_set`

| Aspect | BBR (ext-proc) | Praxis |
|---|---|---|
| Credential source | K8s Secret via ExternalModel credentialRef | Static value in ConfigMap |
| Secret refresh | Watches Secret for rotation | Requires redeploy |
| Header operation | Remove client key + inject provider key | Overwrite via `request_set` |

### api-translation — not implemented

| Aspect | BBR (ext-proc) | Praxis |
|---|---|---|
| Request body rewrite | Per-provider schema translation | Not available |
| Response normalization | Normalizes to client format | Not available |
| When it matters | Multi-provider routing (OpenAI→Anthropic) | Only matters if providers differ |

## Deploy

```bash
# Prerequisites: MaaS deployed, ExternalModel created
# See docs/install.md for the full runbook

OPENAI_API_KEY='sk-...' ./demos/maas-praxis/deploy.sh
```

The deploy script:
1. Creates `llm` namespace (removes Istio injection label)
2. Deploys BBR replacement manifests (echo backends + Praxis)
3. Patches ClusterIPs into Praxis config
4. Deploys provider gateway manifests (Praxis → OpenAI)
5. Injects OpenAI API key into gateway ConfigMap
6. Patches gpt-4o HTTPRoute backendRef to `praxis-gateway:8080`

## Validate

```bash
./demos/maas-praxis/validate.sh
```

### Expected output

```
BBR REPLACEMENT — body-based model routing
  PASS  model=qwen routes and forwards body: HTTP 200
  PASS  model=mistral routes and forwards body: HTTP 200
  PASS  no auth rejected: HTTP 401

PROVIDER GATEWAY — gpt-4o via Praxis → OpenAI
  PASS  chat completion via /praxis-gw/: HTTP 200
  PASS  provider route no auth rejected: HTTP 401

MAAS MODEL PATH — gpt-4o with MaaS API key through Praxis
  MaaS API key: sk-oai-...
  {"model":"gpt-4o-2024-08-06","choices":[{"message":{"content":"Ok."}}],...}
  PASS  gpt-4o via MaaS API key: HTTP 200
  PASS  bogus key rejected: HTTP 403
  PASS  no auth rejected: HTTP 401

Results: 8 passed, 0 failed, 0 skipped
```

## Additional Validation Scripts

| Script | What it tests |
|--------|--------------|
| `scripts/validate-all.sh` | Full suite: BBR + provider gateway + MaaS auth (13 tests) |
| `scripts/validate-maas-path-gpt.sh` | gpt-4o MaaS path in detail: API key, K8s token, model listing, auth rejection (8 tests) |
| `scripts/validate-maas-all-models.sh` | All models: gpt-4o (ExternalModel via Praxis) + facebook/opt-125m (LLMInferenceService via KServe) (7 tests) |

## Known Issues

| Issue | Detail | Workaround |
|-------|--------|------------|
| Authorino AuthPolicy enforcement | Kuadrant requires Authorino CR `status.Ready=True`. Scaling the operator to 0 leaves status stale. AuthPolicies show `Enforced: False` and routes 404. | Scale operator to 1 briefly, wait 30s, scale back to 0. See `docs/install.md` §3. |
| Transient 404 after Authorino restart | Gateway wasm plugin has stale gRPC connection after Authorino restarts. First request may 404. | Self-heals within 30-60s as connection pool recycles. |
| gpt-4o HTTPRoute reconciliation | MaaS controller may revert the backendRef patch on ExternalModel update. | Re-run `deploy.sh` or re-apply the patch. |
| Istio sidecar injection | Echo backends and Praxis pods hang in `Init:1/2` if `llm` namespace has `istio-injection=enabled`. | Deploy scripts remove the label automatically. |
| sed key corruption | `sed` corrupts API keys containing certain character sequences during ConfigMap injection. | Deploy script uses bash parameter expansion `${CONFIG//placeholder/$value}` instead. |
| StreamBuffer + external TLS combined | Body inspection (`model_to_header`) and external provider routing work in separate paths. Combining them in a single hop requires both the Praxis and Pingora fixes. | Both fixes are included in the current image. |

## MaaS Consolidation Roadmap

| Phase | Target | What moves into Praxis | What it eliminates | GitHub Issues | Status |
|-------|--------|----------------------|-------------------|---------------|--------|
| **1** | ext-proc/BBR replacement | Body extraction, model routing, credential injection, provider TLS egress | ext-proc pod, EnvoyFilter, DestinationRule, ExternalName Service, payload-processing RBAC | — | **Complete** ([details](phase-1-completion.md)) |
| **2** | Descriptor request limiting | Request-admission limits keyed by trusted subscription, user, model, route, or workspace descriptors | Only request-count-style Limitador usage on Praxis-owned routes; not token quotas | #8, #48, new descriptor-limit issue | **Complete** ([details](../maas-praxis-phase2/)) |
| **2** | Prometheus metrics | `/metrics` endpoint on admin listener | — (additive) | #8 | **Complete** |
| **2** | Per-filter failure modes | Configurable fail-open/fail-closed per filter | — (additive) | #48 | **Complete** |
| **2b** | Targeted inline / ext-auth | `maas-api` validation bridge for opaque `sk-oai-*` API keys; metadata injection | Authorino only on targeted Praxis-owned routes after behavior parity | #12, #14 | **Code complete** (not yet cluster-deployed as Authorino replacement) |
| **3A** | Praxis-owned auth + rate limiting on shadow route | Auth (http_ext_auth → maas-api) + request-admission (descriptor rate_limit) handled by Praxis | Kuadrant auth/rate-limit *decisions* bypassed — wasm still mechanically present via pass-through policies on shared gateway | Depends on Phase 2 + 2b | **Validated** ([details](../maas-praxis-phase3/)) |
| **3B** | True Kuadrant bypass on dedicated route | Same as 3A but on a clean Gateway with no Kuadrant policy attachment | Kuadrant wasm, Authorino, Limitador fully absent from request path | Depends on Phase 3A | Not started |
| **3b** | Token counting + token-aware limits | Prompt/completion token counting, per-descriptor token quotas, shared state backend | Limitador for token-quota enforcement | #20, #21 | Not started |
| **4** | Praxis as the gateway | TLS termination, HTTP/2, HTTP/3, WebSocket, Gateway API | Envoy gateway, Istio gateway pods, all EnvoyFilter/WasmPlugin CRDs | #7, #33, #39 | Not started |

### Phase dependencies

```
Phase 1 (COMPLETE)
  │
  ├── Phase 2: descriptor request limiting (new issue)
  │     requires: #8 (Prometheus metrics), #48 (failure modes)
  │
  ├── Phase 2b: targeted inline / ext-auth (#12, #14, new MaaS API-key issue)
  │
  └── Phase 2 + 2b together enable:
        │
        Phase 3A: Praxis-owned auth + rate limiting (VALIDATED)
          │  Praxis owns decisions; Kuadrant pass-through on shared gateway
          │
          ├── Phase 3B: true Kuadrant bypass (dedicated clean Gateway)
          │     proves Praxis works without any Kuadrant components
          │
          ├── Phase 3c: token counting + token limits (#20, #21)
          │     requires: shared state backend (new issue)
          │
          └── Phase 3B + 3c together enable:
                │
                Phase 4: Praxis as the gateway (#7, #33, #39)
```

Detailed phase-2 execution planning lives in
[praxxis-planning.md](../../../praxxis-planning.md).
