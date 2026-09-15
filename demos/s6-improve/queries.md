# S6 improve — scripted mock-LLM candidate; gate promotes then demotes.
# First cycle (RUN-PROMOTE-CYCLE): verdict :PROMOTE, baseline 0, candidate 1,
# skill "parity-improve" gains a version with cycle/eval provenance.
# Second cycle: critical case regresses → :DEMOTE despite a higher mean.
#
# Product `demiurge improve` / `improve:` on a bare echo expert skips
# (no eval history). This demo uses the one generic runner so the
# promote/demote narrative stays data-driven (no dedicated lisp file).

