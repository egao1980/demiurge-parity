(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s8-serve
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:bb #:blackboard-protocol)
                    (#:mcp #:mcp-protocol)
                    (#:a2a #:a2a-protocol)
                    (#:ag-ui #:ag-ui-protocol)))

(in-package #:demiurge-parity/tests/s8-serve)

;;; S8 serve — in-process MCP / A2A / AG-UI round-trips vs echo + mock LLM.

(defun %mcp-text (result)
  (let ((content (and (hash-table-p result) (gethash "content" result))))
    (cond
      ((and (vectorp content) (plusp (length content)))
       (or (gethash "text" (aref content 0)) ""))
      ((stringp result) result)
      (t (princ-to-string result)))))

(defun %event-types (events)
  (mapcar #'ag-ui:ag-ui-event-type events))

(deftest s8-echo-expert-mcp-roundtrip
  (if (not (serve-system-available-p))
      (skip "demiurge/serve not loadable from OCI")
      (progn
        (ensure-ci-backends)
        (let* ((domain (demiurge:make-echo-expert
                        :backend (make-scripted-llm)
                        :name "parity-echo-mcp"))
               (server (demiurge/serve:make-expert-mcp-server domain))
               (names (mapcar #'mcp:mcp-tool-name (mcp:list-tools server))))
          (ok (find "ask_expert" names :test #'equal)
              "MCP server exposes ask_expert")
          (ok (find "record_feedback" names :test #'equal)
              "MCP server exposes record_feedback")
          (let* ((result (mcp:call-tool server "ask_expert"
                                        (mcp:json-object "prompt" "hi")))
                 (text (%mcp-text result)))
            (ok (hash-table-p result) "ask_expert returned a tool result")
            (ok (search "echo: hi" text) "ask_expert echoed the prompt")
            (ok (search "feedback-id:" text)
                "ask_expert attached a feedback-id"))))))

(deftest s8-echo-expert-a2a-roundtrip
  (if (not (serve-system-available-p))
      (skip "demiurge/serve not loadable from OCI")
      (progn
        (ensure-ci-backends)
        (let* ((domain (demiurge:make-echo-expert
                        :backend (make-scripted-llm)
                        :name "parity-echo-a2a"))
               (board (bb:make-blackboard))
               (task (demiurge/serve:run-expert-as-a2a-task
                      domain
                      :blackboard board
                      :prompt "hi")))
          (ok (eq :completed (a2a:a2a-task-state task))
              "A2A task completed")
          (ok (plusp (length (a2a:a2a-task-artifacts task)))
              "A2A task produced artifacts")
          (ok (equal "echo: hi" (bb:read-section board :result))
              "board :result is the echo")
          (let* ((art (find "result" (a2a:a2a-task-artifacts task)
                            :key #'a2a:a2a-artifact-name :test #'equal))
                 (part (and art (first (a2a:a2a-artifact-parts art)))))
            (ok art "result artifact is present")
            (ok (equal "echo: hi" (a2a:a2a-part-text part))
                "result artifact text is the echo"))))))

(deftest s8-echo-expert-ag-ui-roundtrip
  (if (not (serve-system-available-p))
      (skip "demiurge/serve not loadable from OCI")
      (progn
        (ensure-ci-backends)
        (let* ((domain (demiurge:make-echo-expert
                        :backend (make-scripted-llm)
                        :name "parity-echo-ag"))
               (events (demiurge/serve:run-expert-as-ag-ui-events
                        domain "hi"
                        :thread-id "t1"
                        :run-id "r1"))
               (types (%event-types events)))
          (ok (equal "RUN_STARTED" (first types))
              "AG-UI stream starts with RUN_STARTED")
          (ok (equal "RUN_FINISHED" (car (last types)))
              "AG-UI stream ends with RUN_FINISHED")
          (ok (find "STEP_STARTED" types :test #'equal))
          (ok (find "STEP_FINISHED" types :test #'equal))
          (ok (find "STATE_DELTA" types :test #'equal))
          (let ((delta (find-if (lambda (ev)
                                  (equal "STATE_DELTA"
                                         (ag-ui:ag-ui-event-type ev)))
                                events)))
            (ok delta "STATE_DELTA event is present")
            (let* ((patch (aref (ag-ui:state-delta-patch delta) 0)))
              (ok (equal "add" (ag-ui:param patch "op")))
              (ok (equal "/result" (ag-ui:param patch "path")))
              (ok (equal "echo: hi" (ag-ui:param patch "value")))))
          (let* ((started (first events))
                 (encoded (ag-ui:encode-ag-ui-event started :format :json))
                 (json (ag-ui:decode-json encoded))
                 (tid (or (gethash "threadId" json)
                          (gethash "thread-id" json)
                          (gethash :thread-id json))))
            (ok (equal "t1" (ag-ui:run-started-thread-id started))
                "RUN_STARTED thread-id is t1")
            (ok (equal "t1" tid)
                "RUN_STARTED JSON carries thread id (camelCase or kebab)"))))))
