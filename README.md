# demiurge-parity

Product smoke / incremental integration harness for
[`demiurge`](https://github.com/egao1980/demiurge). Unit tests per repo prove
parts; this repo proves the composition.

This tree is **checkout-only**. Dependencies resolve from
`ghcr.io/egao1980/cl-systems` (never a sibling git checkout of `demiurge`).

## Stages

Each Rove file is runnable standalone. Later stages assume earlier ones pass.

| Stage | File | Default CI |
|---|---|---|
| S1 resolve | `tests/s1-resolve.lisp` | run — load `demiurge` + `/improve` + `/ingest` + `/serve` from OCI |
| S2 boot | `tests/s2-boot.lisp` | run — personal profile in a temp dir |
| S3 ingest | `tests/s3-ingest.lisp` | run — `demiurge/ingest:run-ingest` on fixtures; hash-idempotent re-run |
| S4 answer | `tests/s4-answer.lisp` | run — echo / cl-dev + mock LLM; citations assert block-id |
| S5 feedback | `tests/s5-feedback.lisp` | run — `add-case` + serve-wire (`handle-feedback-event` / MCP `record_feedback`) |
| S6 improve | `tests/s6-improve.lisp` | run — mock-LLM candidate wins, gate promotes |
| S7 durability | `tests/s7-durability.lisp` | run — child SBCL kill-and-resume (2-step journal) |
| S8 serve | `tests/s8-serve.lisp` | run — in-process MCP / A2A / AG-UI round-trips vs echo + mock LLM |
| S9 corporate | `tests/s9-corporate.lisp` | run — mock-tier corporate profile / tenant / OIDC / authz; live `readyz` only when `DEMIURGE_PARITY_TIER=live-corporate` |

## Tiers

| Tier | Gate | CI |
|---|---|---|
| `mock` | default | always (`test` job; S9 live cases skip) |
| `live-local` | `DEMIURGE_PARITY_LLM=` | skip unless set |
| `live-corporate` | compose Postgres | `parity-live` (`docker compose --profile corporate`; MinIO/collector are `--profile extras`) |

```bash
ros -e '(asdf:test-system "demiurge-parity")' -q
```

Live compose (Postgres/pgvector is required; LDAP/Keycloak are optional profiles):

```bash
docker compose --profile corporate up --wait
DEMIURGE_PARITY_TIER=live-corporate \
  DEMIURGE_CORPORATE__POSTGRES__DSN=postgres://demiurge:demiurge@127.0.0.1:5432/demiurge \
  ros -e '(asdf:test-system "demiurge-parity")' -q
```

Standalone stage:

```bash
ros -e '(asdf:load-system "demiurge-parity/tests")' \
    -e '(rove:run #p"tests/s1-resolve.lisp")' -q
```

## Demo evidence

Narrated recordings for later human review live in
[`demos/`](demos/README.md). They are scripts, not tests
(S2/S4/S6/S7 plus B8 v2 `deep-research` / `corporate-boot`).
S3/S5/S8/S9 run in Rove. `deep-research` hits LM Studio or llama.cpp when
a local model is up (`DEMIURGE_PARITY_DEMO_LLM=mock` to force the script).

```bash
./demos/run-demo.sh s2-boot
./demos/run-demo.sh s4-answer
./demos/run-demo.sh s6-improve
./demos/run-demo.sh s7-resume
./demos/run-demo.sh deep-research
./demos/run-demo.sh corporate-boot
```

CI: `.github/workflows/demo-evidence.yml` (release tags + `workflow_dispatch`).

## License

MIT
