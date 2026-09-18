(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/h7-crash-boundary
  (:use #:cl #:rove #:demiurge-parity))

(in-package #:demiurge-parity/tests/h7-crash-boundary)

;;; H7 gate 2 — crash-boundary.
;;; Kill before/after effect-receipt append = no lost and no duplicate effect.
;;; Cross-process SBCL child, same shape as S7.

(deftest-parametrize h7-crash-boundary-effect-receipt
    ((kill-point) :ids ("before" "after")
     (:before)
     (:after))
  #-sbcl
  (skip "cross-process receipt crash requires SBCL (sb-ext:exit :abort t)")
  #+sbcl
  (cond
    ((not (system-available-p "sql-backend-sqlite3"))
     (skip "sql-backend-sqlite3 not loadable"))
    (t
     (ok (and (fboundp 'demiurge:journal-effect-receipt)
              (fboundp 'demiurge:find-effect-receipt))
         "H1 effect-receipt APIs are on published demiurge")
     (let* ((activation (format nil "h7-act-~a" kill-point))
            (result (run-effect-receipt-crash
                     :task-id (format nil "h7-receipt-~a" kill-point)
                     :activation-id activation
                     :kill-point kill-point)))
       (ok (eq kill-point (getf result :kill-point)))
       (ok (= 1 (getf result :before-count))
           "child journaled the activation step before the kill")
       (ok (zerop (getf result :fresh))
           "resume did not re-execute the activation body")
       (ok (= 1 (getf result :effect-count))
           "side effect written exactly once (no lost, no duplicate)")
       (ok (getf result :after-receipt-p)
           "resume leaves a journaled effect-receipt")
       (ok (= 1 (getf result :after-count))
           "resume did not append a second activation step")
       (if (eq kill-point :before)
           (ok (not (getf result :before-receipt-p))
               "kill before append left no receipt")
           (ok (getf result :before-receipt-p)
               "kill after append left the receipt in place"))))))
