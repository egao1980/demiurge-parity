# Corporate boot — make-corporate-profile with memory/sqlite fallback.
# Expected: :CORPORATE kind, tenant "acme", tenant-scoped ids.
# Clack GET /healthz and /readyz → 200; unauthenticated GET / → 302 /login.
# No live Postgres. Live compose + readyz is the S9 parity-live job.
#
# This file has no query lines. `command = "corporate"` in demo.toml is enough.
