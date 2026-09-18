(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/h7-serve-boundary
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:eval #:eval-protocol)
                    (#:mcp #:mcp-protocol)))

(in-package #:demiurge-parity/tests/h7-serve-boundary)

;;; H7 follow-on gate 7 — serve-boundary.
;;; Malformed / oversized HTTP /feedback and strict MCP record_feedback
;;; stay 4xx and must not mutate the eval dataset. Parity vs published
;;; demiurge/serve (H3 on 0.3.11), not a product rewrite.

(defun %feedback-env (body &key (content-type "application/json")
                             content-length)
  (list :request-method :post
        :path-info "/feedback"
        :content-type content-type
        :content-length (or content-length (length body))
        :raw-body body))

(defun %case-count (domain)
  (length (eval:eval-dataset-cases
           (first (demiurge:expert-eval-suites domain)))))

(deftest h7-serve-boundary-http-rejects-malformed-without-mutation
  (if (not (serve-system-available-p))
      (skip "demiurge/serve not loadable from OCI")
      (progn
        (ensure-ci-backends)
        (let* ((ds (eval:make-eval-dataset :name "h7-fb-http" :cases nil))
               (domain (demiurge:make-echo-expert
                        :backend (make-scripted-llm)
                        :name "h7-echo-fb-http"))
               (app (demiurge/serve:make-expert-app domain :personal)))
          (setf (demiurge:expert-eval-suites domain) (list ds))
          (ok (zerop (%case-count domain)))
          (let ((res (funcall app (%feedback-env "not-json"))))
            (ok (= 400 (first res)) "malformed JSON → 400"))
          (ok (zerop (%case-count domain))
              "malformed JSON does not add a case")
          (let ((res (funcall app (%feedback-env
                                   "{\"unknown\":true,\"rating\":1}"))))
            (ok (= 400 (first res)) "unknown fields → 400"))
          (let ((res (funcall app (%feedback-env "{\"feedback_id\":\"x\"}"))))
            (ok (= 400 (first res)) "missing rating → 400"))
          (let ((res (funcall app (%feedback-env
                                   "{\"feedback_id\":\"x\",\"rating\":1}"
                                   :content-type "text/plain"))))
            (ok (= 415 (first res)) "wrong content-type → 415"))
          (let ((res (funcall app (%feedback-env
                                   "{\"feedback_id\":\"x\",\"rating\":1}"
                                   :content-length
                                   (1+ demiurge/serve:*max-request-bytes*)))))
            (ok (= 413 (first res)) "content-length over *max-request-bytes* → 413"))
          (ok (zerop (%case-count domain))
              "ALL 4xx paths leave the dataset untouched")
          (let ((res (funcall app (%feedback-env
                                   "{\"feedback_id\":\"fb-ok\",\"rating\":5,\"answer\":\"hi\"}"))))
            (ok (= 200 (first res)) "valid body → 200")
            (ok (plusp (%case-count domain))
                "valid body adds a case (counter moves)"))))))

(deftest h7-serve-boundary-record-feedback-mcp-strict-schema
  (if (not (serve-system-available-p))
      (skip "demiurge/serve not loadable from OCI")
      (progn
        (ensure-ci-backends)
        (let* ((domain (demiurge:make-echo-expert
                        :backend (make-scripted-llm)
                        :name "h7-echo-fb-strict"))
               (server (demiurge/serve:make-expert-mcp-server domain)))
          (setf (demiurge:expert-eval-suites domain)
                (list (eval:make-eval-dataset :name "h7-fb-strict" :cases nil)))
          (ok (signals (mcp:call-tool server "record_feedback"
                                      (mcp:json-object "rating" 1))
                       'mcp:mcp-error)
              "missing feedback_id → mcp:mcp-error")
          (ok (signals (mcp:call-tool server "record_feedback"
                                      (mcp:json-object "feedback_id" "x"
                                                       "rating" 1
                                                       "evil" t))
                       'mcp:mcp-error)
              "unknown field → mcp:mcp-error")
          (ok (zerop (%case-count domain))
              "MCP 4xx paths leave the dataset untouched")))))
