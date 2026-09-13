(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s8-serve
  (:use #:cl #:rove #:demiurge-parity))

(in-package #:demiurge-parity/tests/s8-serve)

;;; S8 serve — MCP/A2A/AG-UI round-trips. Activates with B3.

(deftest s8-serve-stub
  (skip "activates with B3/C4"))
