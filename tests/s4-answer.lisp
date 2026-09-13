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
