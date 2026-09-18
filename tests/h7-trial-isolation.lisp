(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/h7-trial-isolation
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:agent #:ai-agent-protocol)
                    (#:bb #:blackboard-protocol)
                    (#:cap #:capability-protocol)
                    (#:eval #:eval-protocol)
                    (#:llm #:llm-protocol)
                    (#:task #:task-protocol)))

(in-package #:demiurge-parity/tests/h7-trial-isolation)

;;; H7 gate 3 — trial-isolation (H2).
;;; Candidate board writes + denied op = no root leak; denial recorded;
;;; versioned-KS path used; restricted catalogue reaches tool construction.

(defun %h7-trial-api-present-p ()
  (and (fboundp 'demiurge/improve:make-versioned-ks)
       (fboundp 'demiurge/improve:make-restricted-catalogue)
       (fboundp 'demiurge/improve:restricted-catalogue-recordings)
       (fboundp 'demiurge/improve:apply-ks-revision)
       (fboundp 'demiurge:collect-agent-ks-tools)))

(deftest h7-trial-isolation-no-root-leak
  (ok (%h7-trial-api-present-p)
      "H2 trial/versioned-KS APIs are on published demiurge")
  (let* ((hits (list 0))
         (ks (make-script-ks
              'echo
              (lambda (in)
                (let ((ksar demiurge/improve:*current-ksar*))
                  (when ksar
                    (incf (car hits))
                    (let ((target (bb:ksar-blackboard ksar)))
                      (when target
                        (bb:write-section target :leaked t)))))
                (format nil "old: ~a" in))))
         (cases (list (eval:make-eval-case :input "hi" :expected "echo: hi")))
         (root (bb:make-blackboard))
         (domain (promote-demo-domain :name "h7-iso-root"
                                      :cases cases
                                      :ks ks)))
    (bb:write-section root :sentinel "keep")
    (let ((result (demiurge/improve:run-improvement-cycle
                   domain
                   :target ks
                   :llm (make-revision-llm "echo: ")
                   :journal (task:make-in-memory-journal)
                   :cycle-id "h7-iso-root"
                   :blackboard root
                   :activity-floor 0)))
      (ok (eq :promote (getf result :verdict)))
      (ok (plusp (car hits))
          "versioned KS ran through the fork scheduler (KSAR bound)")
      (ok (equal "keep" (bb:read-section root :sentinel))
          "root sentinel is unchanged")
      (ok (not (bb:section-bound-p root :leaked))
          "candidate board write did not leak onto the root")
      (ok (not (bb:section-bound-p root :prompt)))
      (ok (not (bb:section-bound-p root :result)))
      (ok (null (bb:list-watchers root)))
      (ok (null (bb:list-ks root))))))

(deftest h7-trial-isolation-denied-op-and-restricted-tools
  (ok (%h7-trial-api-present-p)
      "H2 restricted-catalogue APIs are on published demiurge")
  (let ((cat (cap:make-catalogue :world)))
    (cap:register-capability cat (make-instance 'cap:communication-capability))
    (let* ((restricted (demiurge/improve:make-restricted-catalogue cat))
           (orig (cap:get-capability cat :communication))
           (stub (cap:get-capability restricted :communication)))
      (ok (demiurge/improve:restricted-catalogue-p restricted))
      (ok (not (eq cat restricted)))
      (ok (find 'cap:send-message (cap:capability-operations orig)
                :key #'cap:capability-operation-name))
      (ok (null (find 'cap:send-message (cap:capability-operations stub)
                      :key #'cap:capability-operation-name)))
      (ok (signals (cap:invoke-operation stub 'cap:send-message "a" "b")
                   'cap:unknown-operation)
          "denied op is rejected")
      (ok (plusp (length (demiurge/improve:restricted-catalogue-recordings
                          restricted)))
          "denial is recorded on the restricted catalogue"))
    (let* ((restricted (demiurge/improve:make-restricted-catalogue cat))
           (agent (agent:make-ai-agent
                   :name "tools"
                   :backend (llm:make-mock-llm-backend :prefix "ok: ")
                   :instructions "base"))
           (ks (demiurge:make-agent-ks :name 'tools :agent agent :catalogue cat))
           (cand (demiurge/improve:apply-ks-revision
                  ks (demiurge/improve:make-ks-revision :prompt "rev")
                  :catalogue restricted))
           (tools (demiurge:collect-agent-ks-tools
                   (demiurge/improve:revised-ks-base cand)
                   :catalogue (demiurge/improve:revised-ks-catalogue cand)))
           (names (mapcar #'llm:llm-tool-name tools)))
      (ok (demiurge/improve:restricted-catalogue-p
           (demiurge/improve:revised-ks-catalogue cand))
          "revision carries the restricted catalogue")
      (ok (demiurge/improve:restricted-catalogue-p
           (demiurge:agent-ks-catalogue (demiurge/improve:revised-ks-base cand)))
          "restricted catalogue reached candidate tool construction")
      (ok (not (find "communication/send-message" names :test #'equal))
          "denied op is absent from constructed tools")
      (let* ((demiurge:*trial-restricted-catalogue* restricted)
             (via-special (demiurge:collect-agent-ks-tools ks)))
        (ok (not (find "communication/send-message"
                       (mapcar #'llm:llm-tool-name via-special)
                       :test #'equal))
            "*trial-restricted-catalogue* reaches tool construction")))))
