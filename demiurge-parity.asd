(defsystem "demiurge-parity"
  :version "0.1.0"
  :description "Product smoke / incremental integration harness for demiurge"
  :author "egao1980"
  :license "MIT"
  :depends-on ("demiurge"
               "demiurge/improve"
               "blackboard-protocol"
               "capability-protocol"
               "eval-protocol"
               "rag-protocol"
               "rag-backend-text"
               "rag-backend-memory"
               "doc-extract-protocol"
               "llm-protocol"
               "steer-protocol"
               "task-protocol"
               "task-backend-sql"
               "sql-protocol"
               "uiop")
  :properties (:cl-repo
               (:ci (:with ("event-backend-libuv"
                            "sql-backend-sqlite3")
                     :load-before-test ("event-backend-libuv"
                                        "sql-backend-sqlite3"))))
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
               (:file "live-local"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "demiurge-parity tests failed"))))
