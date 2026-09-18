(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s9-corporate
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:cap #:capability-protocol)
                    (#:conv #:conversation-protocol)
                    (#:jwt #:cl-stack-jwt)
                    (#:llm #:llm-protocol)
                    (#:oauth2 #:cl-stack-oauth2)
                    (#:task #:task-protocol)))

(in-package #:demiurge-parity/tests/s9-corporate)

;;; S9 corporate — mock-tier always (in-memory + canned OIDC). Live compose
;;; readyz only when DEMIURGE_PARITY_TIER=live-corporate.

(defparameter *corporate-oidc-discovery-json*
  "{
  \"issuer\": \"https://idp.example\",
  \"authorization_endpoint\": \"https://idp.example/authorize\",
  \"token_endpoint\": \"https://idp.example/token\",
  \"jwks_uri\": \"https://idp.example/jwks\",
  \"userinfo_endpoint\": \"https://idp.example/userinfo\",
  \"id_token_signing_alg_values_supported\": [\"HS256\"]
}")

(defun %s9-systems-available-p ()
  (and (system-available-p "demiurge")
       (serve-system-available-p)
       (observe-system-available-p)))

(defun %corporate-hs-key ()
  "secret-key-123456789012345678901234")

(defun %write-tmp-toml (text)
  (uiop:with-temporary-file (:pathname path :prefix "parity-corp-cfg-"
                             :type "toml" :keep t)
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string text out))
    path))

(defun %corporate-cfg (&key (issuer "https://idp.example")
                            (client "app")
                            (dsn "postgres://demiurge:demiurge@127.0.0.1:5432/demiurge")
                            (tenant "acme")
                            (env t))
  (let ((path (%write-tmp-toml
               (format nil "
[corporate]
postgres.dsn = ~S
otlp.endpoint = \"http://127.0.0.1:4318\"
tenant.id = ~S

[corporate.oidc]
issuer = ~S
client-id = ~S

[corporate.session]
secret = ~S
kid = \"k1\"
issuer = \"demiurge\"
audience = \"demiurge-session\"

[corporate.role-grants]
reader = [\"lookup-symbol\", \"search-corpus\"]
admin = [\"lookup-symbol\", \"search-corpus\", \"run-tests\"]
"
                       dsn tenant issuer client (%corporate-hs-key)))))
    (demiurge:load-demiurge-config :path path :prefix "DEMIURGE" :env env)))

(defun %corporate-id-token (&key (iss "https://idp.example")
                                 (aud "app")
                                 (nonce "n1")
                                 (sub "alice")
                                 (tenant "acme")
                                 (exp (+ (jwt:unix-time) 3600))
                                 (kid "k1"))
  (jwt:encode
   :hs256 (%corporate-hs-key)
   `(("iss" . ,iss)
     ("aud" . ,aud)
     ("nonce" . ,nonce)
     ("sub" . ,sub)
     ("tenant" . ,tenant)
     ("exp" . ,exp))
   :headers `(("kid" . ,kid))))

(defun %memory-corporate (tmp &key config tenant
                              oidc-discovery oidc-jwks oidc-key
                              oidc-algorithms token-exchange
                              role-grants)
  (demiurge:make-corporate-profile
   :data-dir tmp
   :config (or config (demiurge:current-demiurge-config))
   :tenant (or tenant "acme")
   :force-recording t
   :journal (task:make-in-memory-journal)
   :session-store (conv:make-in-memory-conversation-store)
   :rag-store (rag-backend-memory:make-memory-vector-store)
   :chunker (rag-backend-text:make-recursive-character-chunker
             :size 200 :overlap 20)
   :llm-catalog (make-scripted-llm-catalog)
   :default-model "mock"
   :oidc-discovery oidc-discovery
   :oidc-jwks oidc-jwks
   :oidc-key oidc-key
   :oidc-algorithms (or oidc-algorithms '("HS256"))
   :token-exchange token-exchange
   :role-grants role-grants
   :session-secret (%corporate-hs-key)))

(defun %query-param (url name)
  (let* ((qpos (position #\? url))
         (qs (and qpos (subseq url (1+ qpos)))))
    (when qs
      (dolist (pair (uiop:split-string qs :separator '(#\&)))
        (let ((eq-pos (position #\= pair)))
          (when (and eq-pos (string= name (subseq pair 0 eq-pos)))
            (return (subseq pair (1+ eq-pos)))))))))

(defun %url-encode (s)
  (with-output-to-string (o)
    (loop for c across (string s)
          do (if (or (alphanumericp c) (find c "-_.~" :test #'char=))
                 (write-char c o)
                 (format o "%~2,'0X" (char-code c))))))

(defun %cookie-value (set-cookie name)
  (let* ((prefix (format nil "~a=" name))
         (pos (search prefix set-cookie)))
    (when pos
      (let* ((start (+ pos (length prefix)))
             (end (or (position #\; set-cookie :start start)
                      (length set-cookie))))
        (subseq set-cookie start end)))))

(defun %header-table (&rest pairs)
  (let ((ht (make-hash-table :test #'equal)))
    (loop for (k v) on pairs by #'cddr
          do (setf (gethash k ht) v))
    ht))

(defun %pending-table (profile)
  (let ((acc (find-symbol "CORPORATE-PROFILE-PENDING" :demiurge)))
    (and acc (fboundp acc) (funcall acc profile))))

(defun %try-live-backends ()
  (dolist (name '("sql-backend-postgres" "sql-query-postgres"
                  "rag-backend-pgvector"))
    (ignore-errors (asdf:load-system name :verbose nil)))
  t)

(defun %dump-readyz (label status response)
  (format *error-output*
          "~&S9 ~A readyz failed~%  status=~S~%  response=~S~%  components=~S~%  details=~S~%"
          label
          (getf status :status)
          response
          (getf status :components)
          (getf status :details)))

(deftest s9-corporate-profile-memory
  (if (not (%s9-systems-available-p))
      (skip "demiurge + demiurge/serve + demiurge/observe not loadable from OCI")
      (progn
        (ensure-ci-backends)
        (with-tmp-dir (tmp)
          (let* ((cfg (%corporate-cfg :env nil))
                 (profile (%memory-corporate tmp :config cfg)))
            (ok (demiurge:corporate-profile-p profile)
                "make-corporate-profile returns a corporate-profile")
            (ok (eq :corporate (demiurge:profile-kind profile)))
            (ok (equal "acme" (demiurge:profile-tenant profile))
                "tenant is bound on the profile")
            (ok (equal "acme"
                       (demiurge:with-tenant (demiurge:profile-tenant profile)
                         (demiurge:current-tenant)))
                "with-tenant binds *tenant*"))))))

(deftest s9-corporate-tenant-isolation
  (if (not (%s9-systems-available-p))
      (skip "demiurge + demiurge/serve + demiurge/observe not loadable from OCI")
      (demiurge:with-tenant "acme"
        (ok (signals (demiurge:assert-tenant-scope "tenant/other/domain/x")
                     'demiurge:tenant-isolation-error)
            "cross-tenant id signals tenant-isolation-error")
        (ok (equal "tenant/acme/domain/echo"
                   (demiurge:assert-tenant-scope (demiurge:tenant-task-id "echo")))
            "tenant-task-id is in-scope")
        (ok (equal "tenant/acme/corpus/docs"
                   (demiurge:tenant-corpus-name "docs"))
            "tenant-corpus-name is scoped"))))

(deftest s9-corporate-oidc-gated-serve
  (if (not (%s9-systems-available-p))
      (skip "demiurge + demiurge/serve + demiurge/observe not loadable from OCI")
      (progn
        (ensure-ci-backends)
        (with-tmp-dir (tmp)
          (let* ((cfg (%corporate-cfg :env nil))
                 (discovery (oauth2:parse-oidc-discovery
                             *corporate-oidc-discovery-json*))
                 (jwks (oauth2:make-jwks-cache))
                 (tok nil)
                 (profile (%memory-corporate
                           tmp
                           :config cfg
                           :oidc-discovery discovery
                           :oidc-jwks jwks
                           :oidc-key (%corporate-hs-key)
                           :token-exchange
                           (lambda (code prof)
                             (declare (ignore code prof))
                             tok)))
                 (domain (demiurge:make-echo-expert
                          :backend (make-scripted-llm)
                          :name "parity-s9-echo"
                          :profile profile))
                 (app (demiurge/serve:make-expert-app domain profile)))
            (oauth2:jwks-cache-put jwks "k1" (%corporate-hs-key))
            (let ((hz (funcall app '(:request-method :get :path-info "/healthz")))
                  (rz (funcall app '(:request-method :get :path-info "/readyz"))))
              (ok (= 200 (first hz))
                  "GET /healthz is 200 without a session cookie")
              (ok (= 200 (first rz))
                  "GET /readyz is 200 without a session cookie"))
            (let ((root (funcall app '(:request-method :get :path-info "/")))
                  (fb (funcall app '(:request-method :get :path-info "/feedback"))))
              (ok (= 302 (first root))
                  "unauthenticated GET / is 302")
              (ok (equal "/login" (getf (second root) :location))
                  "unauthenticated GET / Location is /login")
              (ok (= 302 (first fb))
                  "unauthenticated GET /feedback is 302"))
            (let* ((login (funcall app '(:request-method :get
                                         :path-info "/login"
                                         :url-scheme :http
                                         :server-name "app.example"
                                         :server-port 80)))
                   (loc (getf (second login) :location))
                   (state (or (%query-param loc "state")
                              (let ((pending (%pending-table profile)))
                                (and pending
                                     (block found
                                       (maphash (lambda (k v)
                                                  (declare (ignore v))
                                                  (return-from found k))
                                                pending))))))
                   (pending (and state
                                 (gethash state (%pending-table profile))))
                   (nonce (or (getf pending :nonce)
                              (%query-param loc "nonce"))))
              (ok (= 302 (first login)) "GET /login redirects to the IdP")
              (ok (and loc (search "https://idp.example/authorize" loc))
                  "login Location is the mock authorize URL")
              (ok (stringp state) "authorize URL carries state")
              (setf tok (%corporate-id-token :nonce nonce :aud "app"))
              (let* ((cb (funcall app
                                  (list :request-method :get
                                        :path-info "/callback"
                                        :query-string
                                        (format nil "code=abc&state=~a&id_token=~a"
                                                (%url-encode state)
                                                (%url-encode tok)))))
                     (cookie (getf (second cb) :set-cookie))
                     (raw (and cookie (%cookie-value cookie "demiurge_session"))))
                (ok (= 302 (first cb)) "callback redirects after mock login")
                (ok (and cookie (search "demiurge_session=" cookie))
                    "callback Set-Cookie holds demiurge_session")
                (ok (stringp raw) "session cookie value is present")
                (let ((authed
                       (funcall app
                                (list :request-method :get
                                      :path-info "/feedback"
                                      :headers
                                      (%header-table
                                       "cookie"
                                       (format nil "demiurge_session=~a" raw))))))
                  (ok (/= 302 (first authed))
                      "authenticated GET /feedback is not a login redirect")))))))))

(deftest s9-corporate-authz-denied
  (if (not (%s9-systems-available-p))
      (skip "demiurge + demiurge/serve + demiurge/observe not loadable from OCI")
      (let ((demiurge::*capability-denial-audit* nil)
            (root (demiurge:make-cl-dev-catalogue :grant-compute t)))
        (let* ((filtered (demiurge:filter-catalogue-for-roles
                          root '("reader")
                          '(("reader" . ("lookup-symbol" "search-corpus")))
                          :principal "alice"
                          :tenant "acme"))
               (prin-cap (cap:get-capability filtered :lisp-dev)))
          ;; Op names must be the DEMIURGE GFs (defcapability interned them
          ;; there). A test-package 'lookup-symbol is unknown-operation.
          (ok (signals (cap:invoke-operation prin-cap 'demiurge:run-tests
                                            "demiurge")
                       'demiurge:capability-denied)
              "missing op signals capability-denied")
          (ok (stringp (cap:invoke-operation prin-cap 'demiurge:lookup-symbol
                                            "car"))
              "granted op still invokes")))))

(deftest s9-corporate-live-compose-readyz
  (cond
    ((not (eq (parity-tier) :live-corporate))
     (skip "parity-live compose tier"))
    ((not (%s9-systems-available-p))
     (skip "demiurge + demiurge/serve + demiurge/observe not loadable from OCI"))
    (t
     (ensure-ci-backends)
     (%try-live-backends)
     (with-tmp-dir (tmp)
       (let* ((dsn (corporate-postgres-dsn))
              (cfg (%corporate-cfg :dsn dsn :env t))
              (catalog (make-scripted-llm-catalog))
              (profile (demiurge:make-corporate-profile
                        :data-dir tmp
                        :config cfg
                        :llm-catalog catalog
                        :default-model "mock"
                        :session-secret (%corporate-hs-key)))
              (llm-backend (llm:resolve-backend
                            catalog
                            (or (demiurge:profile-default-model profile) "mock")))
              (st (demiurge/observe:readyz-status
                   :journal (demiurge:profile-journal profile)
                   :rag-store (demiurge:profile-rag-store profile)
                   :llm-backend llm-backend))
              (resp (demiurge/observe:readyz-response
                     :journal (demiurge:profile-journal profile)
                     :rag-store (demiurge:profile-rag-store profile)
                     :llm-backend llm-backend))
              (domain (demiurge:make-echo-expert
                       :backend (make-scripted-llm)
                       :name "parity-s9-live"
                       :profile profile))
              (app (demiurge/serve:make-expert-app domain profile))
              (http (funcall app '(:request-method :get :path-info "/readyz"))))
         (unless (and (= 200 (first resp))
                      (eq :ok (getf st :status))
                      (= 200 (first http)))
           (%dump-readyz "live-corporate" st resp))
         (ok (demiurge:corporate-profile-p profile)
             "live make-corporate-profile (DSN, no in-memory override)")
         (ok (= 200 (first resp))
             (format nil "readyz-response HTTP 200 (status=~S components=~S)"
                     (getf st :status) (getf st :components)))
         (ok (eq :ok (getf st :status)) "readyz status is :ok")
         (ok (= 200 (first http))
             "make-expert-app GET /readyz is 200"))))))
