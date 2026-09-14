(defpackage #:demiurge-parity
  (:use #:cl)
  (:nicknames #:stack-demiurge.parity)
  (:local-nicknames (#:bb #:blackboard-protocol)
                    (#:cap #:capability-protocol)
                    (#:eval #:eval-protocol)
                    (#:rag #:rag-protocol)
                    (#:dx #:doc-extract-protocol)
                    (#:llm #:llm-protocol)
                    (#:steer #:steer-protocol)
                    (#:task #:task-protocol)
                    (#:tbsql #:task-backend-sql))
  (:export
   #:parity-error
   #:parity-error-message
   #:parity-error-cause
   #:stage-unavailable
   #:stage-unavailable-stage
   #:stage-unavailable-reason
   #:call-with-parity-restarts
   #:with-parity-restarts
   #:invoke-retry
   #:invoke-skip
   #:invoke-use-value

   #:try-load-system
   #:system-available-p
   #:ingest-system-available-p
   #:serve-system-available-p
   #:ensure-ci-backends
   #:demiurge-version-string
   #:observe-b5b-available-p
   #:taxonomy-metric-present-p
   #:taxonomy-coverage
   #:s4-taxonomy-reasons
   #:parity-tier
   #:live-local-endpoint
   #:fixture-pathname
   #:with-tmp-dir

   #:make-scripted-llm
   #:make-revision-llm
   #:make-citing-llm
   #:citation-block-ids

   #:boot-personal-profile
   #:profile-sqlite-paths

   #:extract-fixture
   #:chunk-extracted
   #:store-chunks
   #:ingest-fixture
   #:memory-store-count
   #:chunk-ids
   #:chunk-block-ids
   #:copy-fixture-corpus
   #:make-fixture-file-source
   #:run-ingest-fixtures

   #:make-script-ks
   #:promote-demo-domain
   #:run-promote-cycle

   #:sbcl-runtime
   #:systems-root-dir
   #:child-registry-dirs
   #:write-kill-resume-child
   #:run-kill-resume)
  (:documentation
   "Staged product-smoke helpers for demiurge. Checkout-only: deps from GHCR."))

(in-package #:demiurge-parity)
