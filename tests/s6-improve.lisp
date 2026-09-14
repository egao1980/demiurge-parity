(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s6-improve
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:steer #:steer-protocol)
                    (#:eval #:eval-protocol)))

(in-package #:demiurge-parity/tests/s6-improve)

;;; S6 improve — mock-LLM candidate wins; gate promotes (GHCR 0.2.0 APIs).

(deftest s6-mock-llm-candidate-promotes
  (with-tmp-dir (tmp)
    (let* ((store (steer:make-file-skill-store tmp))
           (result (run-promote-cycle
                    :skill-store store
                    :cycle-id "parity-promote")))
      (ok (eq :promote (getf result :verdict))
          "gate promotes the scripted winner")
      (ok (= 0 (getf result :baseline-score))
          "baseline (old: prefix) scores 0")
      (ok (= 1 (getf result :candidate-score))
          "candidate (echo: prefix) scores 1")
      (ok (steer:skill-versions store "parity-improve")
          "skill store gained a version with provenance"))))

(deftest s6-improve-emits-eval-score-and-promotion
  "B5b: improve records eval-score + promotion counter. Skips until 0.3.5 is on GHCR."
  (if (not (observe-b5b-available-p))
      (skip "demiurge 0.3.5 observe wiring not on GHCR yet (B5b; supervisor publishes)")
      (let* ((obs (find-package '#:demiurge/observe))
             (apply-fn (and obs (find-symbol "APPLY-PERSONAL-OBSERVABILITY" obs)))
             (dump-fn (and obs (find-symbol "DUMP-OBSERVABILITY" obs))))
        (ok apply-fn "demiurge/observe is loaded")
        (ok dump-fn "dump-observability is present")
        (funcall apply-fn :stream (make-broadcast-stream))
        (with-tmp-dir (tmp)
          (let* ((store (steer:make-file-skill-store tmp))
                 (result (run-promote-cycle
                          :skill-store store
                          :cycle-id "parity-promote-obs"))
                 (dump (funcall dump-fn)))
            (ok (eq :promote (getf result :verdict)))
            (ok (taxonomy-metric-present-p dump "demiurge.eval.score")
                "S6 records demiurge.eval.score")
            (ok (taxonomy-metric-present-p dump "demiurge.improve.promotions")
                "S6 records demiurge.improve.promotions"))))))

(deftest s6-gate-demotes-critical-regression
  (let* ((cases (list (eval:make-eval-case :input "x" :expected "echo: x")
                      (eval:make-eval-case :input "y" :expected "echo: y")
                      (eval:make-eval-case
                       :input "crit" :expected "keep"
                       :metadata '(:tags (:critical)))))
         (ks (make-script-ks
              'echo
              (lambda (in)
                (if (equal in "crit")
                    "keep"
                    (format nil "old: ~a" in)))))
         (domain (promote-demo-domain :name "parity-demote" :cases cases :ks ks))
         (result (demiurge/improve:run-improvement-cycle
                  domain
                  :target ks
                  :llm (make-revision-llm "echo: ")
                  :journal (task-protocol:make-in-memory-journal)
                  :cycle-id "parity-demote"
                  :activity-floor 0)))
    (ok (eq :demote (getf result :verdict))
        "critical regression demotes despite higher mean")
    (ok (> (getf result :candidate-score)
           (getf result :baseline-score)))))
