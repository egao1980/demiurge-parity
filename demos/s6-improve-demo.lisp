;;;; S6 improve demo — narrated mock-LLM promote + critical-regression demote.
;;;;   sbcl --load demos/s6-improve-demo.lisp
;;;;   or:  ./demos/run-demo.sh s6-improve

(load (merge-pathnames "prelude.lisp"
                       (or *load-truename* *compile-file-truename*)))
(in-package #:demiurge-parity)

(demo-narrate "S6 improve — scripted mock-LLM candidate wins; gate promotes")
(demo-look-at "gate verdict, baseline vs candidate scores, skill-store versions + provenance")

(with-tmp-dir (tmp)
  (let* ((store (steer:make-file-skill-store tmp))
         (result (run-promote-cycle
                  :skill-store store
                  :cycle-id "demo-promote"))
         (versions (steer:skill-versions store "parity-improve")))
    (demo-narrate "Promote cycle finished (RUN-PROMOTE-CYCLE)")
    (demo-kv "verdict" (getf result :verdict))
    (demo-kv "cycle-id" (getf result :cycle-id))
    (demo-kv "baseline-score (old: prefix → 0)" (getf result :baseline-score))
    (demo-kv "candidate-score (echo: prefix → 1)" (getf result :candidate-score))
    (demo-kv "eval-run-id" (getf result :eval-run-id))
    (demo-narrate "Skill store after promotion")
    (demo-look-at "a new version of skill \"parity-improve\" with cycle/eval provenance")
    (demo-kv "version count" (length versions))
    (dolist (v versions)
      (demo-kv "version id" (steer:skill-version-id v))
      (demo-kv "version name" (steer:skill-version-name v))
      (demo-kv "provenance" (steer:skill-version-provenance v)))))

(demo-narrate "Second pass — critical case regresses: gate must DEMOTE despite a higher mean")
(demo-look-at "verdict :DEMOTE while candidate-score > baseline-score")

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
       (domain (promote-demo-domain :name "demo-demote" :cases cases :ks ks))
       (result (demiurge/improve:run-improvement-cycle
                domain
                :target ks
                :llm (make-revision-llm "echo: ")
                :journal (task:make-in-memory-journal)
                :cycle-id "demo-demote"
                :activity-floor 0)))
  (demo-kv "verdict" (getf result :verdict))
  (demo-kv "baseline-score" (getf result :baseline-score))
  (demo-kv "candidate-score" (getf result :candidate-score))
  (demo-kv "candidate > baseline"
           (and (getf result :candidate-score)
                (getf result :baseline-score)
                (> (getf result :candidate-score)
                   (getf result :baseline-score))))
  (demo-narrate "S6 done. Reviewer: first cycle :PROMOTE + skill version; second :DEMOTE on :critical."))

(uiop:quit 0)
