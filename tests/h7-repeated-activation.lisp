(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/h7-repeated-activation
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:bb #:blackboard-protocol)
                    (#:conv #:conversation-protocol)
                    (#:llm #:llm-protocol)
                    (#:task #:task-protocol)))

(in-package #:demiurge-parity/tests/h7-repeated-activation)

;;; H7 gate 1 — repeated-activation (H1 identity/receipts).
;;; Same KS twice = two executions. Replay of a completed activation
;;; executes neither. Fresh run IDs; no constant "execute" / "ksar/<name>".

(defun %h7-identity-api-present-p ()
  (and (fboundp 'demiurge:durable-activation-id)
       (fboundp 'demiurge:fresh-durable-id)
       (fboundp 'demiurge:call-with-durable-ksar)
       (fboundp 'demiurge:find-effect-receipt)
       (fboundp 'demiurge:journal-effect-receipt)
       (fboundp 'demiurge:ensure-board-run-id)
       (fboundp 'demiurge:assign-board-run-id)))

(defun %memory-profile (tmp journal)
  (demiurge:make-personal-profile
   :data-dir tmp
   :journal journal
   :session-store (conv:make-in-memory-conversation-store)
   :rag-store (rag-backend-memory:make-memory-vector-store)
   :chunker (rag-backend-text:make-recursive-character-chunker
             :size 200 :overlap 20)))

(defun %counting-echo-backend (counter)
  (llm:make-mock-llm-backend
   :handler (lambda (backend turns &key &allow-other-keys)
              (declare (ignore backend turns))
              (incf (car counter))
              (llm:make-llm-response
               :parts (list (llm:make-llm-text-part
                             :text (format nil "echo: n=~a" (car counter))))))))

(defun %enqueue-ksar-ids (journal task-id)
  (let ((task (task:make-durable-task :id task-id :journal journal)))
    (loop for ev in (task:journal-events journal task)
          when (and (typep ev 'task:step-completed)
                    (equal (task:step-name ev) "enqueue-ksar"))
            collect (getf (task:step-result ev) :id))))

(defun %execute-step-names (journal)
  (loop for tid in (task:journal-task-ids journal)
        for task = (task:make-durable-task :id tid :journal journal)
        append (loop for ev in (task:journal-events journal task)
                     when (and (typep ev 'task:step-completed)
                               (let ((name (task:step-name ev)))
                                 (and (stringp name)
                                      (>= (length name) 8)
                                      (string= name "execute/" :end1 8))))
                       collect (task:step-name ev))))

(deftest h7-repeated-activation-same-ks-twice
  (ok (%h7-identity-api-present-p)
      "H1 identity/receipt APIs are on published demiurge")
  (ensure-ci-backends)
  (with-tmp-dir (tmp)
    (let* ((journal (task:make-in-memory-journal))
           (profile (%memory-profile tmp journal))
           (counter (list 0))
           (domain (demiurge:make-echo-expert
                    :backend (%counting-echo-backend counter)
                    :name "h7-ksar-twice"
                    :profile profile))
           (controller (demiurge:make-controller domain
                                                 :journal journal
                                                 :profile profile))
           (board (demiurge:controller-blackboard controller))
           (ks (first (demiurge:expert-ks-set domain))))
      (demiurge:run-controller controller :trigger '(:prompt "one"))
      (demiurge:run-controller controller :trigger '(:prompt "two"))
      (ok (= 2 (car counter))
          "same KS twice = two live executions")
      (ok (equal "echo: n=2" (bb:read-section board :result)))
      (let* ((ids (%enqueue-ksar-ids journal (demiurge:domain-task-id domain)))
             (first-id (first ids))
             (activation
              (let ((demiurge:*current-ksar* (bb:make-ksar :id first-id)))
                (demiurge:durable-activation-id board ks :domain domain)))
             (receipt (demiurge:find-effect-receipt journal activation
                                                    :domain domain))
             (exec-names (%execute-step-names journal)))
        (ok (= 2 (length ids))
            "two distinct KSAR enqueue events")
        (ok (not (equal (first ids) (second ids))))
        (ok (not (equal activation "execute"))
            "activation id is not the constant \"execute\"")
        (ok (not (search "ksar/echo" activation))
            "activation id is not the old ksar/<name> key")
        (ok (plusp (length exec-names))
            "activation steps were journaled")
        (ok (not (find "execute" exec-names :test #'equal))
            "no constant \"execute\" durable key")
        (ok (every (lambda (name)
                     (and (>= (length name) 8)
                          (string= name "execute/" :end1 8)))
                   exec-names)
            "durable step names are execute/<activation>")
        (ok (equal (length exec-names)
                   (length (remove-duplicates exec-names :test #'equal)))
            "each activation has its own execute step")
        (ok receipt "side-effect receipt keyed by first activation")
        (ok (typep receipt 'task:effect-receipt)
            "receipt is a task-protocol effect-receipt, not the step result")
        (let ((demiurge:*current-ksar* (bb:make-ksar :id first-id)))
          (demiurge:call-with-durable-ksar
           board ks
           (lambda ()
             (incf (car counter))
             "should-not-run")))
        (ok (= 2 (car counter))
            "replay of a completed activation executes neither")))))

(deftest h7-repeated-activation-fresh-run-ids
  (ok (fboundp 'demiurge:ensure-board-run-id)
      "ensure-board-run-id is on published demiurge")
  (ensure-ci-backends)
  (with-tmp-dir (tmp)
    (let* ((journal (task:make-in-memory-journal))
           (profile (%memory-profile tmp journal))
           (domain (demiurge:make-echo-expert
                    :backend (make-scripted-llm)
                    :name "h7-run-ids"
                    :profile profile))
           (c1 (demiurge:make-controller domain
                                         :journal journal
                                         :profile profile))
           (id1 (demiurge:ensure-board-run-id
                 (demiurge:controller-blackboard c1) domain))
           (c2 (demiurge:make-controller domain
                                         :blackboard (bb:make-blackboard)
                                         :journal journal
                                         :profile profile))
           (id2 (demiurge:ensure-board-run-id
                 (demiurge:controller-blackboard c2) domain))
           (c3 (demiurge:make-controller domain
                                         :blackboard (bb:make-blackboard)
                                         :journal journal
                                         :profile profile
                                         :run-id id1))
           (id3 (demiurge:ensure-board-run-id
                 (demiurge:controller-blackboard c3) domain)))
      (ok (and (stringp id1) (plusp (length id1))))
      (ok (not (equal id1 id2))
          "new controller mints a fresh run id")
      (ok (equal id1 id3)
          "explicit run-id resumes")
      (ok (not (equal id1 "execute")))
      (let ((fresh-a (demiurge:fresh-durable-id "run" "h7"))
            (fresh-b (demiurge:fresh-durable-id "run" "h7")))
        (ok (not (equal fresh-a fresh-b))
            "fresh-durable-id is unique per call")))))
