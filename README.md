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
| S1 resolve | `tests/s1-resolve.lisp` | run — load `demiurge` + `demiurge/improve` from OCI |
| S2 boot | `tests/s2-boot.lisp` | run — personal profile in a temp dir |
| S3 ingest | `tests/s3-ingest.lisp` | helpers run; `demiurge/ingest` call skips until B3 |
| S4 answer | `tests/s4-answer.lisp` | run — echo / cl-dev + mock LLM; citations assert block-id |
| S5 feedback | `tests/s5-feedback.lisp` | `add-case` runs; serve-wire skips until B3 |
| S6 improve | `tests/s6-improve.lisp` | run — mock-LLM candidate wins, gate promotes |
| S7 durability | `tests/s7-durability.lisp` | run — child SBCL kill-and-resume (2-step journal) |
| S8 serve | `tests/s8-serve.lisp` | skip — activates with B3 |
| S9 corporate | `tests/s9-corporate.lisp` | skip — activates with C4 |

## Tiers

| Tier | Gate | CI |
|---|---|---|
| `mock` | default | always (`test` + `parity-live`) |
| `live-local` | `DEMIURGE_PARITY_LLM=` | skip unless set |
| `live-corporate` | compose stack | skipped until C4 (`docker-compose.yml` is a stub) |

```bash
ros -e '(asdf:test-system "demiurge-parity")' -q
```

Standalone stage:

```bash
ros -e '(asdf:load-system "demiurge-parity/tests")' \
    -e '(rove:run #p"tests/s1-resolve.lisp")' -q
```

## Demo evidence

Narrated mock-tier recordings for later human review live in
[`demos/`](demos/README.md). They are scripts, not tests — S3/S5/S8 stay
skipped here.

```bash
./demos/run-demo.sh s2-boot
./demos/run-demo.sh s4-answer
./demos/run-demo.sh s6-improve
./demos/run-demo.sh s7-resume
```

CI: `.github/workflows/demo-evidence.yml` (release tags + `workflow_dispatch`).

## License

MIT
