# Demo: BBR/ext-proc Replacement

## What this proves

Praxis replaces the BBR payload-processing ext-proc pipeline
for model extraction and routing. Instead of:

```
Client → Envoy → ext_proc (gRPC) → payload-processing
  → body-field-to-header plugin
  → model-provider-resolver plugin
  → api-translation plugin
  → apikey-injection plugin
→ Envoy routes by X-Gateway-Model-Name
```

Praxis does it in-process:

```
Client → Gateway → Praxis
  → model_to_header (native filter, StreamBuffer)
  → router (header match)
  → load_balancer (endpoint selection)
→ Backend
```

No ext-proc hop. No gRPC sidecar. No Wasm shim. Body
inspection happens inline in the proxy, and the validation
also proves the original request body reaches the selected
upstream backend intact.

## What is replaced

| BBR Component | Praxis Replacement | Status |
|---|---|---|
| body-field-to-header plugin | `model_to_header` filter | Working |
| model-provider-resolver | `router` filter (static config) | Working (static only) |
| ext_proc gRPC service | eliminated | N/A |
| EnvoyFilter for ext_proc | eliminated | N/A |

## What is NOT replaced yet

| BBR Component | Why | Issue |
|---|---|---|
| api-translation plugin | Provider schema translation not implemented | New issue |
| apikey-injection plugin | Needs `request_set`/`request_remove` | New issue |

## Prerequisites

- MaaS deployed with `maas-default-gateway` in openshift-ingress
- `oc` access as cluster admin

## Deploy

```bash
# From repo root
./demos/bbr-replacement/deploy.sh
```

## Validate

```bash
./demos/bbr-replacement/validate.sh
```

The validation asserts all of the following:

- `model=qwen` routes to the `qwen` backend
- `model=mistral` routes to the `mistral` backend
- requests without a `model` field fall through to the default route
- the backend receives and echoes the original request body
- auth failures still return `401`
