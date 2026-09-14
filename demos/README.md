# Demo evidence

Demos are **data**, not Lisp scripts: each name is a directory with
`demo.toml` (expert / command / tier prefs) and `queries.md` (ordered
queries; `#` comments are expected-behavior notes). The product runner
is `demiurge demo <dir>` (B9). Boot / resume / corporate-boot / the
scripted S6 promote+demote pair go through the one generic
`demos/runner.lisp` because those commands are parity-specific
(product `improve` on a bare echo expert skips).

These are **not** Rove tests: they print what is happening and what to
look at (section writes, citations, gate verdicts, journal replay
counts). S3/S5/S8/S9 run in Rove; recordings cover S2/S4/S6/S7 plus
B8 v2 deep-research / corporate-boot.

`deep-research` prefers a live local model: LM Studio (`OPENAI_BASE_URL`,
`OPENAI_MODEL`, `LM_API_TOKEN` from the workspace `.env`) then
`llm-backend-llama-cpp` (`LLAMA_MODEL_PATH`). `DEMIURGE_PARITY_DEMO_LLM=mock`
forces the scripted backend. CI falls back to mock when nothing is listening.

Websearch uses `websearch-protocol:make-searxng-backend` against a local
SearXNG with JSON enabled (`demos/searxng/settings.yml`). Default
`SEARXNG_URL=http://127.0.0.1:8888`. `run-demo.sh` starts
`docker compose --profile search up -d --wait searxng` when `:8888` is down
and the demo is `deep-research` with a non-mock websearch tier.
`DEMIURGE_PARITY_DEMO_WEBSEARCH=mock` uses `demos/deep-research/websearch.toml`.

## Layout

```
demos/
  run-demo.sh          # recording wrapper (asciinema + tee)
  prelude.lisp         # OCI dest + source-registry bootstrap
  runner.lisp          # boot / resume / corporate only
  s2-boot/             # command=boot     → runner
  s4-answer/           # command=ask      → demiurge demo
  s6-improve/          # command=improve  → runner (promote + demote helpers)
  s7-resume/           # command=resume   → runner
  deep-research/       # command=research → demiurge demo
  corporate-boot/      # command=corporate → runner
  searxng/settings.yml
  recordings/0.1.1/    # B8 v1 casts+logs (kept)
  recordings/0.1.4/    # B8 v2 casts+logs (kept)
```

A new demo is a new directory (`demo.toml` + `queries.md`). No new Lisp.

## Run

```bash
./demos/run-demo.sh s2-boot
./demos/run-demo.sh s4-answer
./demos/run-demo.sh s6-improve
./demos/run-demo.sh s7-resume
./demos/run-demo.sh deep-research
./demos/run-demo.sh corporate-boot
```

Mock-tier verification (no live LLM / SearXNG):

```bash
DEMIURGE_PARITY_DEMO_LLM=mock \
DEMIURGE_PARITY_DEMO_WEBSEARCH=mock \
  ./demos/run-demo.sh s4-answer
```

`run-demo.sh` resolves `demos/<name>/`, isolates dest to `.demo-oci`, then
loads `prelude.lisp` and either `scripts/demiurge.lisp -- demo <dir>`
(from the sibling `demiurge-plan-vectors` checkout, which has B9
`demiurge/cli`) or `runner.lisp` for boot/resume/corporate. It wraps SBCL
in `asciinema rec demos/recordings/<version>/<name>.cast` when asciinema
is on `PATH`, otherwise `script`(1). It **always** tees
`demos/recordings/<version>/<name>.log`. The Lisp header prints ASDF
versions of loaded systems and the OCI tag when the source path is a
GHCR dest.

Checkout-only: dependencies come from `ghcr.io/egao1980/cl-systems`.
`%local-override-directories` prefers sibling `demiurge-plan-vectors`
so B8 can load `demiurge/cli`. Do not point `CL_SOURCE_REGISTRY` at a
stale `demiurge/` or `demiurge-b4b` checkout.

CI: `.github/workflows/demo-evidence.yml` on `v*` tags and `workflow_dispatch`.
It uploads logs/casts as artifacts and does not auto-commit.

## Index

| Recording | What it proves | Date | System versions |
|---|---|---|---|
| [`recordings/0.1.1/s2-boot-demo`](recordings/0.1.1/s2-boot-demo.log) ([.cast](recordings/0.1.1/s2-boot-demo.cast)) | Personal profile factory in a clean temp dir: `:personal` kind, journal/session/chunker/rag/llm stores bound; SQLite files created | 2026-09-13 | `demiurge-parity` 0.1.1, `demiurge` 0.3.0, `llm-protocol` 0.3.0, `blackboard-protocol` 0.2.2, `steer-protocol` 0.2.0, `task-protocol` 0.1.0, `event-backend-libuv` 0.1.2 (full list in log header) |
| [`recordings/0.1.1/s4-answer-demo`](recordings/0.1.1/s4-answer-demo.log) ([.cast](recordings/0.1.1/s4-answer-demo.cast)) | cl-dev expert answers via mock LLM; board `:prompt`/`:result` writes; citation `:block-id`s from `fixtures/sample.html` | 2026-09-13 | same as s2-boot (see log header) |
| [`recordings/0.1.1/s6-improve-demo`](recordings/0.1.1/s6-improve-demo.log) ([.cast](recordings/0.1.1/s6-improve-demo.cast)) | Mock-LLM candidate wins → gate `:promote` + skill version with provenance; critical regression → `:demote` despite higher mean | 2026-09-13 | same as s2-boot (see log header) |
| [`recordings/0.1.1/s7-resume-demo`](recordings/0.1.1/s7-resume-demo.log) ([.cast](recordings/0.1.1/s7-resume-demo.cast)) | Child SBCL kill after step 1; parent replay: `before-count=1`, `after-count=2`, `fresh-1=0`, `fresh-2=1` | 2026-09-13 | same as s2-boot (see log header) |
| [`recordings/0.1.4/deep-research-demo`](recordings/0.1.4/deep-research-demo.log) ([.cast](recordings/0.1.4/deep-research-demo.cast)) | B4 `run-deep-research`: per-step system prompts, SearXNG fetch → board/RAG/MCP `research://source/<id>`, short cited child answers, synthesis | 2026-09-14 | `demiurge-parity` 0.1.4, `demiurge` 0.3.6 + `/workflows`, `websearch-protocol` 0.1.1 (log header) |
| [`recordings/0.1.4/corporate-boot-demo`](recordings/0.1.4/corporate-boot-demo.log) ([.cast](recordings/0.1.4/corporate-boot-demo.cast)) | C4 `make-corporate-profile` memory/sqlite fallback: `:corporate` kind, tenant-scoped ids, `/healthz`/`/readyz` 200, unauthenticated `/` → 302 `/login` | 2026-09-14 | `demiurge-parity` 0.1.4, `demiurge` 0.3.5 + `/serve` + `/observe` (log header) |

B8 v3 sources are the directories above (`demo.toml` + `queries.md`).
Record locally with `./demos/run-demo.sh` — CI is not required. `demo-evidence` only
re-records on tags / dispatch. Live re-record of the six names after this
layout change is deferred.

Casts sit next to the logs (`.cast`). Play an asciinema cast with
`asciinema play demos/recordings/<version>/<name>.cast` when the recorder was
asciinema; `script`(1) typescripts are plain terminal captures.
