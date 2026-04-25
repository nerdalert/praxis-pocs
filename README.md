# Praxis POCs

Proof-of-concept demos for [Praxis](https://github.com/praxis-proxy/praxis), an AI-native proxy built on Pingora.

These demos show Praxis replacing components in a MaaS (Models-as-a-Service) gateway stack — body-aware model routing, provider egress, and request classification without ext-proc or Wasm sidecars.

## MaaS Integration Summary

Start with [MAAS-INTEGRATION-SUMMARY.md](MAAS-INTEGRATION-SUMMARY.md) for the phase-by-phase status, request flows, component replacement matrix, known gaps, and issue map.

## Praxis Changes

These demos use development images from `ghcr.io/nerdalert/praxis`.
Phase-specific details live in the phase docs and the summary above.

| Phase | Praxis branch/image | Main Praxis changes |
|---|---|---|
| Phase 1 | [`feat/dns-and-request-headers`](https://github.com/nerdalert/praxis/tree/feat/dns-and-request-headers), `ghcr.io/nerdalert/praxis:maas-dev` | DNS upstreams, request header set/remove, StreamBuffer body forwarding |
| Phase 2 / 3 | [`feat/maas-phase2`](https://github.com/nerdalert/praxis/tree/feat/maas-phase2), `ghcr.io/nerdalert/praxis:maas-phase2` | Metadata bag, `/metrics`, failure modes, descriptor rate limiter, HTTP ext-auth |

The Praxis builds still rely on the Pingora body-forwarding work in
[`nerdalert/pingora` `feat/streambuffer-initial-send`](https://github.com/nerdalert/pingora/tree/feat/streambuffer-initial-send).

## Demos

| Demo | Purpose |
|---|---|
| [demos/maas-praxis/](demos/maas-praxis/) | Phase 1: BBR/ext-proc replacement for body-aware routing and provider egress |
| [demos/maas-praxis-phase2/](demos/maas-praxis-phase2/) | Phase 2: descriptor request limiter, bridge mode, and auth/rate-limit primitives |
| [demos/maas-praxis-phase3/](demos/maas-praxis-phase3/) | Phase 3: Praxis-owned MaaS key validation and request limiting |
| [demos/maas-praxis-phase4/](demos/maas-praxis-phase4/) | Phase 4 planning: token limits and usage accounting |

## Docs

- [docs/install.md](docs/install.md) — MaaS + Praxis install runbook
- [docs/streambuffer.md](docs/streambuffer.md) — StreamBuffer body forwarding technical detail

## Scripts

- [`scripts/validate-all.sh`](scripts/validate-all.sh) — full integration test suite
- [`scripts/validate-maas-path-gpt.sh`](scripts/validate-maas-path-gpt.sh) — gpt-4o MaaS path validation
- [`scripts/validate-maas-all-models.sh`](scripts/validate-maas-all-models.sh) — all models (gpt-4o + facebook/opt-125m)

## Quick Start

```bash
# Prerequisites: MaaS deployed (see docs/install.md)

OPENAI_API_KEY='sk-...' ./demos/maas-praxis/deploy.sh
./demos/maas-praxis/validate.sh
```

## License

MIT
