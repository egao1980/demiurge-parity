# Demo evidence

Narrated mock-tier scripts for later human review. These are **not** Rove
tests: they print what is happening and what to look at (section writes,
citations, gate verdicts, journal replay counts). S3/S5/S8/S9 run in
Rove; recordings cover S2/S4/S6/S7 plus B8 v2 deep-research / corporate-boot.

## Run

```bash
./demos/run-demo.sh s2-boot
./demos/run-demo.sh s4-answer
./demos/run-demo.sh s6-improve
./demos/run-demo.sh s7-resume
./demos/run-demo.sh deep-research
./demos/run-demo.sh corporate-boot
```

`run-demo.sh` wraps SBCL in `asciinema rec demos/recordings/<version>/<name>.cast`
when asciinema is on `PATH`, otherwise `script`(1). It **always** tees
`demos/recordings/<version>/<name>.log`. The Lisp header prints ASDF versions
of loaded systems and the OCI tag when the source path is a GHCR dest.

Checkout-only: dependencies come from `ghcr.io/egao1980/cl-systems`. Do not
point `CL_SOURCE_REGISTRY` at a sibling `demiurge/` checkout.

CI: `.github/workflows/demo-evidence.yml` on `v*` tags and `workflow_dispatch`.
It uploads logs/casts as artifacts and does not auto-commit.

## Index

| Recording | What it proves | Date | System versions |
|---|---|---|---|
| [`recordings/0.1.1/s2-boot-demo`](recordings/0.1.1/s2-boot-demo.log) ([.cast](recordings/0.1.1/s2-boot-demo.cast)) | Personal profile factory in a clean temp dir: `:personal` kind, journal/session/chunker/rag/llm stores bound; SQLite files created | 2026-09-13 | `demiurge-parity` 0.1.1, `demiurge` 0.3.0, `llm-protocol` 0.3.0, `blackboard-protocol` 0.2.2, `steer-protocol` 0.2.0, `task-protocol` 0.1.0, `event-backend-libuv` 0.1.2 (full list in log header) |
| [`recordings/0.1.1/s4-answer-demo`](recordings/0.1.1/s4-answer-demo.log) ([.cast](recordings/0.1.1/s4-answer-demo.cast)) | cl-dev expert answers via mock LLM; board `:prompt`/`:result` writes; citation `:block-id`s from `fixtures/sample.html` | 2026-09-13 | same as s2-boot (see log header) |
| [`recordings/0.1.1/s6-improve-demo`](recordings/0.1.1/s6-improve-demo.log) ([.cast](recordings/0.1.1/s6-improve-demo.cast)) | Mock-LLM candidate wins → gate `:promote` + skill version with provenance; critical regression → `:demote` despite higher mean | 2026-09-13 | same as s2-boot (see log header) |
| [`recordings/0.1.1/s7-resume-demo`](recordings/0.1.1/s7-resume-demo.log) ([.cast](recordings/0.1.1/s7-resume-demo.cast)) | Child SBCL kill after step 1; parent replay: `before-count=1`, `after-count=2`, `fresh-1=0`, `fresh-2=1` | 2026-09-13 | same as s2-boot (see log header) |
| [`recordings/0.1.4/deep-research-demo`](recordings/0.1.4/deep-research-demo.log) | B4 `run-deep-research` with mock LLM + mock websearch: verdict, 3 children, markdown `ANSWER:` cites, board `:round-summary` | 2026-09-14 | `demiurge-parity` 0.1.4, `demiurge` 0.3.5 + `/workflows` (see log header when recorded) |
| [`recordings/0.1.4/corporate-boot-demo`](recordings/0.1.4/corporate-boot-demo.log) | C4 `make-corporate-profile` memory/sqlite fallback: `:corporate` kind, tenant-scoped ids, `/healthz`/`/readyz` 200, unauthenticated `/` → 302 `/login` | 2026-09-14 | `demiurge-parity` 0.1.4, `demiurge` 0.3.5 + `/serve` + `/observe` (see log header when recorded) |

B8 v2 recordings live under `recordings/0.1.4/`. If a local SBCL/OCI run cannot produce logs or `.cast` files, the scripts still land; CI `demo-evidence` is the other recorder.

Casts sit next to the logs (`.cast`). Play an asciinema cast with
`asciinema play demos/recordings/<version>/<name>.cast` when the recorder was
asciinema; `script`(1) typescripts are plain terminal captures.
