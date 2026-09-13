(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s5-feedback
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:eval #:eval-protocol)
                    (#:mcp #:mcp-protocol)
                    (#:ag-ui #:ag-ui-protocol)))

(in-package #:demiurge-parity/tests/s5-feedback)

;;; S5 feedback — add-case :human-feedback, plus serve-wire
;;; (handle-feedback-event / record-feedback / MCP record_feedback).

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
      (skip "demiurge/serve not loadable from OCI")
      (progn
        (ensure-ci-backends)
        (let* ((ds (eval:make-eval-dataset :name "fb" :cases nil))
               (domain (demiurge:make-echo-expert
                        :backend (make-scripted-llm)
                        :name "parity-echo-fb")))
          (setf (demiurge:expert-eval-suites domain) (list ds))
          (let ((new (demiurge/serve:handle-feedback-event
                      domain
                      (ag-ui:make-custom-event
                       :name "demiurge.feedback"
                       :value (ag-ui:json-object "rating" 5
                                                 "correction" "better"
                                                 "feedbackId" "fb-1"
                                                 "ksId" "echo"
                                                 "answer" "echo: hi")))))
            (ok (eval:eval-dataset-p new)
                "handle-feedback-event returned an eval-dataset")
            (ok (member :human-feedback (eval:eval-dataset-provenance new))
                "AG-UI event provenance is :human-feedback")
            (let* ((case (car (last (eval:eval-dataset-cases new))))
                   (tags (getf (eval:eval-case-metadata case) :tags)))
              (ok (equal "echo: hi" (eval:eval-case-input case)))
              (ok (equal "better" (eval:eval-case-expected case)))
              (ok (member :human-feedback tags))
              (ok (find "fb-1" tags :test #'equal))
              (ok (find "echo" tags :test #'equal)))))
        (let* ((domain (demiurge:make-echo-expert
                        :backend (make-scripted-llm)
                        :name "parity-echo-fb-direct")))
          (let ((ds (demiurge/serve:record-feedback
                     domain
                     :feedback-id "fb-direct"
                     :rating 2
                     :correction "fixed"
                     :answer "old"
                     :ks-id "echo")))
            (ok (eval:eval-dataset-p ds)
                "record-feedback returned an eval-dataset")
            (ok (member :human-feedback (eval:eval-dataset-provenance ds))
                "record-feedback provenance is :human-feedback")
            (let* ((case (car (last (eval:eval-dataset-cases ds))))
                   (tags (getf (eval:eval-case-metadata case) :tags)))
              (ok (equal "old" (eval:eval-case-input case)))
              (ok (equal "fixed" (eval:eval-case-expected case)))
              (ok (find "fb-direct" tags :test #'equal)))))
        (let* ((domain (demiurge:make-echo-expert
                        :backend (make-scripted-llm)
                        :name "parity-echo-fb-mcp"))
               (server (demiurge/serve:make-expert-mcp-server domain)))
          (setf (demiurge:expert-eval-suites domain)
                (list (eval:make-eval-dataset :name "fb-mcp" :cases nil)))
          (mcp:call-tool server "record_feedback"
                         (mcp:json-object "feedback_id" "fb-mcp-1"
                                          "rating" 1
                                          "correction" "fix"
                                          "ks_id" "echo"
                                          "answer" "old"))
          (let* ((ds (first (demiurge:expert-eval-suites domain)))
                 (case (car (last (eval:eval-dataset-cases ds))))
                 (tags (getf (eval:eval-case-metadata case) :tags)))
            (ok (member :human-feedback (eval:eval-dataset-provenance ds))
                "MCP record_feedback provenance is :human-feedback")
            (ok (find "fb-mcp-1" tags :test #'equal)
                "MCP record_feedback tagged the feedback id"))))))
