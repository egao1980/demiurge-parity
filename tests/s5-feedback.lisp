(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s5-feedback
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:eval #:eval-protocol)))

(in-package #:demiurge-parity/tests/s5-feedback)

;;; S5 feedback — add-case :human-feedback lands in the dataset.
;;; Serve-wire path skips until B3.

(deftest s5-add-case-human-feedback
  (let* ((c1 (eval:make-eval-case :input "hi" :expected "echo: hi"))
         (c2 (eval:make-eval-case :input "fix" :expected "corrected"))
         (d1 (eval:make-eval-dataset :name "parity-fb" :cases (list c1)))
         (d2 (eval:add-case d1 c2 :source :human-feedback)))
    (ok (eval:eval-dataset-p d2))
    (ok (= 2 (length (eval:eval-dataset-cases d2)))
        "correction appended")
    (ok (not (eq d1 d2))
        "add-case returns a new dataset version")
    (ok (member :human-feedback (eval:eval-dataset-provenance d2))
        "provenance records :human-feedback")))

(deftest s5-serve-feedback
  (if (not (serve-system-available-p))
      (skip "serve/feedback not loadable")
      (ok (serve-system-available-p)
          "demiurge/serve loaded — wire AG-UI/MCP feedback into add-case")))
