(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s9-corporate
  (:use #:cl #:rove #:demiurge-parity))

(in-package #:demiurge-parity/tests/s9-corporate)

;;; S9 corporate — compose profile boots and readyz goes green. Activates with C4.

(deftest s9-corporate-stub
  (skip "activates with C4"))
