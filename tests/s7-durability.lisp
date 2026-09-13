(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s7-durability
  (:use #:cl #:rove #:demiurge-parity))

(in-package #:demiurge-parity/tests/s7-durability)

;;; S7 durability — 2-step journal, child SBCL kill, parent replay.

(deftest s7-kill-and-resume
  #-sbcl
  (skip "cross-process resume requires SBCL (sb-ext:exit :abort t)")
  #+sbcl
  (if (not (system-available-p "sql-backend-sqlite3"))
      (skip "sql-backend-sqlite3 not loadable")
      (let ((result (run-kill-resume :task-id "parity-resume")))
        (ok (= 1 (getf result :before-count))
            "shared journal has step 1 before resume")
        (ok (equal '("step-1" "step-2") (getf result :step-names))
            "resume journal has both steps")
        (ok (zerop (getf result :fresh-1))
            "step 1 body did not re-execute")
        (ok (= 1 (getf result :fresh-2))
            "step 2 body ran once on resume")
        (ok (= 1 (getf result :effect-1))
            "step-1 side-effect written exactly once")
        (ok (= 1 (getf result :effect-2))
            "step-2 side-effect written on resume")
        (ok (= 2 (getf result :after-count))
            "resume appended only the fresh step 2"))))
