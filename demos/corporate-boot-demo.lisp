;;;; Corporate-boot demo — narrated make-corporate-profile (C4, memory/sqlite).
;;;;   sbcl --load demos/corporate-boot-demo.lisp
;;;;   or:  ./demos/run-demo.sh corporate-boot
;;;; No live Postgres. Live compose + readyz is the S9 parity-live job.

(load (merge-pathnames "prelude.lisp"
                       (or *load-truename* *compile-file-truename*)))

(dolist (name '("demiurge/serve" "demiurge/observe"))
  (unless (asdf:find-system name nil)
    (format *error-output* "~&DEMO FAIL: ~A is not findable from OCI~%" name)
    (uiop:quit 1))
  (asdf:load-system name))

(in-package #:demiurge-parity)

(defun %write-tmp-toml (text)
  (uiop:with-temporary-file (:pathname path :prefix "parity-corp-demo-"
                             :type "toml" :keep t)
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string text out))
    path))

(demo-narrate "Corporate boot — make-corporate-profile with memory/sqlite fallback")
(demo-look-at "kind, tenant, tenant-scoped ids; Clack /healthz /readyz 200; unauthenticated / → 302")

(with-tmp-dir (tmp)
  (let* ((cfg-path (%write-tmp-toml "
[corporate]
postgres.dsn = \"\"
tenant.id = \"acme\"

[corporate.oidc]
issuer = \"https://idp.example\"
client-id = \"app\"
"))
         (cfg (demiurge:load-demiurge-config :path cfg-path :env nil))
         (profile (demiurge:make-corporate-profile
                   :data-dir tmp
                   :config cfg
                   :tenant "acme"
                   :force-recording t
                   :journal (task:make-in-memory-journal)
                   :session-store (conversation-protocol:make-in-memory-conversation-store)
                   :rag-store (rag-backend-memory:make-memory-vector-store)
                   :chunker (rag-backend-text:make-recursive-character-chunker
                             :size 200 :overlap 20)
                   :llm-catalog (make-scripted-llm-catalog)
                   :default-model "mock")))
    (demo-narrate "Factory returned a corporate profile (no live Postgres)")
    (demo-kv "corporate-profile-p" (demiurge:corporate-profile-p profile))
    (demo-kv "profile-kind" (demiurge:profile-kind profile))
    (demo-kv "tenant" (demiurge:profile-tenant profile))
    (demo-look-at ":CORPORATE kind and tenant \"acme\" — memory journal/session/rag, not a DSN")
    (demiurge:with-tenant (demiurge:profile-tenant profile)
      (demo-narrate "Tenant-scoped identifiers")
      (demo-kv "tenant-task-id echo" (demiurge:tenant-task-id "echo"))
      (demo-kv "tenant-corpus-name docs" (demiurge:tenant-corpus-name "docs"))
      (demo-kv "current-tenant" (demiurge:current-tenant)))
    (let* ((domain (demiurge:make-echo-expert
                    :backend (make-scripted-llm)
                    :name "demo-corporate-echo"
                    :profile profile))
           (app (demiurge/serve:make-expert-app domain profile))
           (hz (funcall app '(:request-method :get :path-info "/healthz")))
           (rz (funcall app '(:request-method :get :path-info "/readyz")))
           (root (funcall app '(:request-method :get :path-info "/"))))
      (demo-narrate "make-expert-app Clack env (no session cookie)")
      (demo-kv "GET /healthz status" (first hz))
      (demo-kv "GET /readyz status" (first rz))
      (demo-kv "GET / status" (first root))
      (demo-kv "GET / Location" (getf (second root) :location))
      (demo-look-at "/healthz and /readyz stay unauthenticated (C4). GET / is a 302 to /login.")
      (demo-narrate "Corporate-boot done. Reviewer: kind/tenant scoped; probes 200; / challenges."))))

(uiop:quit 0)
