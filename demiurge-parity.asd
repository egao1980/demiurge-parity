(defsystem "demiurge-parity"
  :version "0.1.9"
  :description "Product smoke / incremental integration harness for demiurge"
  :author "egao1980"
  :license "MIT"
  :depends-on ((:version "demiurge" "0.4.1")
               (:version "demiurge/improve" "0.4.1")
               (:version "demiurge/ingest" "0.4.1")
               (:version "demiurge/serve" "0.4.1")
               (:version "demiurge/observe" "0.4.1")
               (:version "demiurge/workflows" "0.4.1")
               "blackboard-protocol"
               "blackboard-wire"
               "capability-protocol"
               "eval-protocol"
               "rag-protocol"
               "rag-backend-text"
               "rag-backend-memory"
               "rag-backend-hybrid"
               "doc-extract-protocol"
               "object-store-protocol"
               "mail-protocol"
               "cl-stack-pathlib"
               "cl-stack-oauth2"
               "cl-stack-jwt"
               "ldap-protocol"
               "llm-protocol"
               "steer-protocol"
               "task-protocol"
               "task-backend-sql"
               "sql-protocol"
               "websearch-protocol"
               "mcp-protocol"
               "a2a-protocol"
               "ag-ui-protocol"
               "mcp-backend-stdio"
               "mcp-backend-streamable-http"
               "a2a-backend-jsonrpc"
               "ag-ui-backend-sse"
               "uiop")
  :properties (:cl-repo
               (:ci (:with ("event-backend-libuv"
                            "sql-backend-sqlite3"
                            "crypto-backend-ironclad"
                            "json-backend-jzon")
                     :load-before-test ("event-backend-libuv"
                                        "sql-backend-sqlite3"
                                        "crypto-backend-ironclad"
                                        "json-backend-jzon"))))
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "conditions")
               (:file "env")
               (:file "mock-llm")
               (:file "profile")
               (:file "ingest")
               (:file "improve")
               (:file "durability"))
  :in-order-to ((test-op (test-op "demiurge-parity/tests"))))

(defsystem "demiurge-parity/tests"
  :depends-on ("demiurge-parity" "rove")
  :pathname "tests"
  :serial t
  :components ((:file "s1-resolve")
               (:file "s2-boot")
               (:file "s3-ingest")
               (:file "s4-answer")
               (:file "s5-feedback")
               (:file "s6-improve")
               (:file "s7-durability")
               (:file "s8-serve")
               (:file "s9-corporate")
               (:file "s10-research")
               (:file "h7-repeated-activation")
               (:file "h7-crash-boundary")
               (:file "h7-trial-isolation")
               (:file "h7-eval-integrity")
               (:file "h7-corporate-session")
               (:file "h7-ingest-failure")
               (:file "h7-serve-boundary")
               (:file "h7-chaos")
               (:file "live-local"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "demiurge-parity tests failed"))))
