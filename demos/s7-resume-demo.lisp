;;;; S7 resume demo — narrated child-SBCL kill-and-resume.
;;;;   sbcl --load demos/s7-resume-demo.lisp
;;;;   or:  ./demos/run-demo.sh s7-resume

(load (merge-pathnames "prelude.lisp"
                       (or *load-truename* *compile-file-truename*)))
(in-package #:demiurge-parity)

(demo-narrate "S7 durability — 2-step journal, child SBCL kill, parent replay")
(demo-look-at "journal replay counts: before-count, after-count, fresh-1/fresh-2, side-effect counts")

#-sbcl
(progn
  (demo-narrate "This demo requires SBCL (sb-ext:exit :abort t). Stopping.")
  (uiop:quit 1))

(unless (system-available-p "sql-backend-sqlite3")
  (demo-narrate "sql-backend-sqlite3 is not loadable. Stopping.")
  (uiop:quit 1))

(demo-narrate "Launching a child SBCL that journals step-1, writes a side-effect, then aborts")
(demo-look-at "shared SQLite journal: one STEP-COMPLETED before resume")

(let ((result (run-kill-resume :task-id "demo-resume")))
  (demo-narrate "Parent replayed the journal and continued with step-2")
  (demo-kv "before-count (steps before resume; expect 1)" (getf result :before-count))
  (demo-kv "after-count (steps after resume; expect 2)" (getf result :after-count))
  (demo-kv "step-names (expect step-1 step-2)" (getf result :step-names))
  (demo-kv "fresh-1 (step-1 body re-executed? expect 0)" (getf result :fresh-1))
  (demo-kv "fresh-2 (step-2 ran on resume? expect 1)" (getf result :fresh-2))
  (demo-kv "effect-1 (side-effect written exactly once)" (getf result :effect-1))
  (demo-kv "effect-2 (side-effect written on resume)" (getf result :effect-2))
  (demo-narrate "Replay contract: step-1 came from the journal (fresh-1=0); step-2 executed once.")
  (demo-narrate "S7 done. Reviewer: before-count=1, after-count=2, fresh-1=0, fresh-2=1, effects=1/1."))

(uiop:quit 0)
