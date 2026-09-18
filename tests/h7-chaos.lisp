(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/h7-chaos
  (:use #:cl #:rove #:demiurge-parity))

(in-package #:demiurge-parity/tests/h7-chaos)

;;; H7 follow-on gate 8 — parity/chaos.
;;; Cross-process SBCL child kills mid fan-out / ingest / HITL / promotion.
;;; Parent resumes; journal event-count + side-effect files: no lost, no duplicate.

(defun %assert-fan-out (result)
  (ok (eq :fan-out (getf result :scenario)))
  (ok (getf result :killed-p) "child reached the spawn kill point")
  (ok (= 1 (getf result :before-child-spawned))
      "child journaled one child-spawned before the kill")
  (ok (= 1 (getf result :after-child-spawned))
      "resume did not spawn a second child for the same key")
  (ok (= 1 (getf result :effect-spawn))
      "spawn side-effect written exactly once")
  (ok (zerop (getf result :resume-exec))
      "finished child body did not re-execute on resume"))

(defun %assert-ingest (result)
  (ok (eq :ingest (getf result :scenario)))
  (ok (getf result :killed-p) "child reached the after-embed kill point")
  (ok (zerop (getf result :before-item-steps))
      "item step was not marked complete before the kill")
  (ok (= 1 (getf result :after-item-steps))
      "resume marked the item complete exactly once")
  (ok (plusp (getf result :chunk-count))
      "resume stored chunks (no lost upsert)")
  (ok (= (getf result :chunk-count) (getf result :unique-chunk-ids))
      "resume did not upsert duplicate chunks")
  (ok (= 1 (getf result :effect-embed))
      "embed side-effect written exactly once")
  (ok (= 1 (getf result :effect-store))
      "store side-effect written exactly once"))

(defun %assert-hitl (result)
  (ok (eq :hitl (getf result :scenario)))
  (ok (getf result :killed-p) "child reached the await-approval kill point")
  (ok (plusp (getf result :before-wait))
      "wait-input was journaled before the kill")
  (ok (= (getf result :before-wait) (getf result :after-wait))
      "resume re-armed the wait without a second wait-input")
  (ok (= 1 (getf result :approval-steps))
      "resume did not double-complete the milestone")
  (ok (getf result :completed-p)
      "approved resume completes the project")
  (ok (= 1 (getf result :effect-wait))
      "wait side-effect written exactly once")
  (ok (= 1 (getf result :effect-approved))
      "approval side-effect written exactly once"))

(defun %assert-promotion (result)
  (ok (eq :promotion (getf result :scenario)))
  (ok (getf result :killed-p) "child reached the promotion upsert kill point")
  (ok (zerop (getf result :before-promote-steps))
      "promote step was not journaled before the kill")
  (ok (= 1 (getf result :after-promote-steps))
      "resume journaled the promote step exactly once")
  (ok (= 1 (getf result :version-count))
      "resume left exactly one promotion write")
  (ok (= 1 (getf result :effect-promote))
      "promotion side-effect written exactly once")
  (ok (eq :promote (getf result :verdict))))

(deftest-parametrize h7-chaos-kill-and-resume
    ((scenario) :ids ("fan-out" "ingest" "hitl" "promotion")
     (:fan-out)
     (:ingest)
     (:hitl)
     (:promotion))
  #-sbcl
  (skip "cross-process chaos requires SBCL (sb-ext:exit :abort t)")
  #+sbcl
  (cond
    ((not (system-available-p "sql-backend-sqlite3"))
     (skip "sql-backend-sqlite3 not loadable"))
    (t
     (let ((reason (chaos-skip-reason scenario)))
       (if reason
           (skip reason)
           (let ((result (run-chaos-crash
                          :scenario scenario
                          :task-id (format nil "h7-chaos-~a" scenario))))
             (ecase scenario
               (:fan-out (%assert-fan-out result))
               (:ingest (%assert-ingest result))
               (:hitl (%assert-hitl result))
               (:promotion (%assert-promotion result)))))))))
