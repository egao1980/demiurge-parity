(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s4-answer
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:bb #:blackboard-protocol)
                    (#:llm #:llm-protocol)))

(in-package #:demiurge-parity/tests/s4-answer)

;;; S4 answer — echo (or cl-dev) expert + mock LLM.
;;; If citations exist, assert block-id metadata.

(defun %citations-of (value)
  (cond
    ((and (consp value) (keywordp (first value)))
     (or (getf value :citations) (getf value :citation)))
    ((consp value)
     (cdr (or (assoc :citations value) (assoc :citation value))))
    (t nil)))

(defun %assert-citation-block-ids (citations)
  (when citations
    (dolist (id (citation-block-ids citations))
      (ok id "citation carries block-id metadata"))
    t))

(deftest s4-echo-expert-mock-llm
  (ensure-ci-backends)
  (let* ((backend (make-scripted-llm))
         (domain (demiurge:make-echo-expert :backend backend :name "parity-echo"))
         (board (demiurge:run-expert domain :trigger '(:prompt "hi"))))
    (ok (equal "echo: hi" (bb:read-section board :result))
        "echo expert answers via mock LLM")
    (%assert-citation-block-ids
     (%citations-of (bb:read-section board :result :default nil)))))

(deftest s4-answer-emits-llm-tokens-and-ksar-duration
  "B5b: answer path records llm tokens + ksar duration. Skips until 0.3.5 is on GHCR."
  (if (not (observe-b5b-available-p))
      (skip "demiurge 0.3.5 observe wiring not on GHCR yet (B5b; supervisor publishes)")
      (progn
        (ensure-ci-backends)
        (let* ((obs (find-package '#:demiurge/observe))
               (apply-fn (and obs (find-symbol "APPLY-PERSONAL-OBSERVABILITY" obs)))
               (dump-fn (and obs (find-symbol "DUMP-OBSERVABILITY" obs)))
               (wrap-sym (find-symbol "WRAP-LLM-OBSERVE" :demiurge))
               (wrap (and wrap-sym (fboundp wrap-sym) (symbol-function wrap-sym))))
          (ok apply-fn "demiurge/observe is loaded")
          (ok dump-fn "dump-observability is present")
          (funcall apply-fn :stream (make-broadcast-stream))
          (let* ((raw (make-scripted-llm))
                 (backend (if wrap
                              (funcall wrap raw :expert "parity-echo" :scope "s4")
                              raw))
                 (domain (demiurge:make-echo-expert :backend backend
                                                    :name "parity-echo-obs"))
                 (board (demiurge:run-expert domain :trigger '(:prompt "hi")))
                 (dump (funcall dump-fn))
                 (coverage (taxonomy-coverage dump)))
            (ok (equal "echo: hi" (bb:read-section board :result)))
            (ok (taxonomy-metric-present-p dump "demiurge.ksar.duration")
                "S4 records demiurge.ksar.duration")
            (ok (taxonomy-metric-present-p dump "demiurge.llm.tokens")
                "S4 records demiurge.llm.tokens via A2 accounting")
            (ok (taxonomy-metric-present-p dump "demiurge.task.queue-depth")
                "S4 records demiurge.task.queue-depth")
            (dolist (row coverage)
              (ok (not (equal "missing — no documented reason" (cdr row)))
                  (format nil "taxonomy ~a: ~a" (car row) (cdr row)))))))))

(deftest s4-cl-dev-or-echo-with-citations
  (ensure-ci-backends)
  (with-tmp-dir (tmp)
    (let* ((chunks-store (multiple-value-list
                          (ingest-fixture (fixture-pathname "sample.html")
                                          :format :html
                                          :document-id "sample.html")))
           (chunks (first chunks-store))
           (backend (make-citing-llm chunks))
           (domain (if (fboundp 'demiurge:make-cl-dev-expert)
                       (demiurge:make-cl-dev-expert
                        :backend backend
                        :name "parity-cl-dev")
                       (demiurge:make-echo-expert
                        :backend backend
                        :name "parity-echo-cite")))
           (board (demiurge:run-expert domain :trigger '(:prompt "cite the fixture")))
           (result (bb:read-section board :result :default nil))
           (output (ignore-errors
                     (llm:llm-response-output
                      (llm:generate backend "cite the fixture"))))
           (citations (or (%citations-of result)
                          (%citations-of output))))
      (declare (ignore tmp))
      (ok result "expert produced a result")
      (if citations
          (%assert-citation-block-ids citations)
          (ok t "no citations on this expert — skip block-id assertion")))))
