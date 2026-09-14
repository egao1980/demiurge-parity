(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s10-research
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:bb #:blackboard-protocol)
                    (#:cap #:capability-protocol)
                    (#:llm #:llm-protocol)
                    (#:task #:task-protocol)
                    (#:web #:websearch-protocol)
                    (#:wf #:demiurge/workflows)))

(in-package #:demiurge-parity/tests/s10-research)

;;; S10 research — B4b deep-research completeness (mock-tier).
;;; Skips until unpublished 0.3.6 APIs (collect-research-citations,
;;; format-research-budget-footer, :require-hitl) are loadable.

(defun %turns-text (turns)
  (cond
    ((stringp turns) turns)
    ((listp turns)
     (with-output-to-string (s)
       (dolist (tn turns)
         (write-string (if (stringp tn) tn (llm:turn-text tn)) s))))
    (t (princ-to-string turns))))

(defun %s10-llm (&key (questions '("What is KSAR?"))
                      gap-once
                      (include-answers-in-synthesis t)
                      synthesis-text)
  (let ((gap-remaining (if gap-once 1 0))
        (gap-q (if (stringp gap-once) gap-once "What is a restart?"))
        (all-qs (if (and gap-once (stringp gap-once))
                    (append questions (list gap-once))
                    questions)))
    (llm:make-mock-llm-backend
     :handler
     (lambda (backend turns &key &allow-other-keys)
       (declare (ignore backend))
       (let* ((text (%turns-text turns))
              (sub-pos (search "Subquestion: " text))
              (sub (when sub-pos
                     (let* ((start (+ sub-pos (length "Subquestion: ")))
                            (end (or (position #\Newline text :start start)
                                     (length text))))
                       (string-trim '(#\Space #\Tab #\Return)
                                    (subseq text start end)))))
              (q (or (find sub all-qs :test #'string-equal)
                     (find-if (lambda (item) (search item text)) all-qs))))
         (cond
           ((search "Gap analysis" text)
            (if (plusp gap-remaining)
                (progn
                  (decf gap-remaining)
                  (llm:make-llm-response
                   :parts (list (llm:make-llm-text-part :text "gap"))
                   :output (wf:make-research-plan
                            :question "q"
                            :subquestions
                            (list (wf:make-research-subquestion
                                   :id "gap-1" :question gap-q)))))
                (llm:make-llm-response
                 :parts (list (llm:make-llm-text-part :text "none"))
                 :output (wf:make-research-plan :question "q"
                                                :subquestions nil))))
           ((search "Decompose" text)
            (llm:make-llm-response
             :parts (list (llm:make-llm-text-part :text "plan"))
             :output (wf:make-research-plan
                      :question "CL expert systems"
                      :subquestions
                      (loop for item in questions
                            for i from 1
                            collect (wf:make-research-subquestion
                                     :id (format nil "q~d" i)
                                     :question item)))))
           ((or (search "ONE subquestion" text)
                (search "research child" text)
                (search "Subquestion:" text))
            (llm:make-llm-response
             :parts (list (llm:make-llm-text-part
                           :text (format nil "ANSWER:~a [~a]"
                                         (or q "unknown")
                                         (if q
                                             (format nil "src-~a"
                                                     (substitute #\- #\Space q))
                                             "src-1"))))))
           (t
            (llm:make-llm-response
             :parts (list (llm:make-llm-text-part
                           :text (or synthesis-text
                                     (if include-answers-in-synthesis
                                         (format nil "Cited briefing.~%~{~a~%~}"
                                                 (mapcar (lambda (item)
                                                           (format nil "ANSWER:~a" item))
                                                         all-qs))
                                         "I omit the expected findings."))))))))))))

(defun %s10-websearch ()
  (web:make-mock-websearch-backend
   :pages (list (cons "https://ex.test/What-is-KSAR?"
                      "<p>ANSWER:What is KSAR? page body.</p>")
                (cons "https://ex.test/What-is-a-restart?"
                      "<p>ANSWER:What is a restart? page body.</p>"))
   :handler
   (lambda (backend query &key &allow-other-keys)
     (declare (ignore backend))
     (list (web:make-search-hit
            :url (format nil "https://ex.test/~a"
                         (substitute #\- #\Space (string query)))
            :title (string query)
            :snippet (format nil "ANSWER:~a" query)
            :rank 1
            :source "mock")))))

(defun %s10-domain ()
  (demiurge:make-expert-domain :name "parity-research"
                               :catalogue (cap:make-catalogue :world)
                               :profile :personal))

(defun %s10-run (&key (question "CL expert systems")
                      llm websearch journal task-id
                      (max-rounds 1)
                      budget require-hitl)
  (wf:run-deep-research
   (%s10-domain) question
   :llm (or llm (%s10-llm))
   :websearch (or websearch (%s10-websearch))
   :journal (or journal (task:make-in-memory-journal))
   :task-id (or task-id "s10-research")
   :max-rounds max-rounds
   :budget budget
   :require-hitl require-hitl))

(deftest s10-two-rounds-when-gap-returns-subquestion
  (ensure-ci-backends)
  (if (not (research-b4b-available-p))
      (skip "demiurge B4b research APIs not on GHCR yet")
      (let* ((exec 0)
             (wf:*research-child-exec-hook*
              (lambda (in)
                (declare (ignore in))
                (incf exec)))
             (result (%s10-run :task-id "s10-gap"
                               :max-rounds 2
                               :llm (%s10-llm :gap-once "What is a restart?"))))
        (ok (= 2 exec) "gap re-spawns a second child")
        (ok (= 2 (length (getf result :children))))
        (ok (member (getf result :verdict) '(:pass :fail))))))

(deftest s10-rendered-markdown-has-url-and-block-id
  (ensure-ci-backends)
  (if (not (research-b4b-available-p))
      (skip "demiurge B4b research APIs not on GHCR yet")
      (let* ((result (%s10-run :task-id "s10-cites"))
             (md (getf result :markdown))
             (cites (wf:collect-research-citations
                     (getf result :children)
                     :workspace (getf result :workspace))))
        (ok (stringp md))
        (ok (search "https://ex.test/" md) "URL citation in rendered report")
        (ok (or (search "[" md) (find :block-id cites :key (lambda (c) (getf c :kind))))
            "block-id / source id in rendered report")
        (ok (search "Sources" md))
        (ok (search "Budget scope:" md)))))

(deftest s10-budget-zero-incomplete-keeps-footer
  (ensure-ci-backends)
  (if (not (research-b4b-available-p))
      (skip "demiurge B4b research APIs not on GHCR yet")
      (let ((result (%s10-run
                     :task-id "s10-budget"
                     :budget (llm:make-llm-budget :max-tokens 0))))
        (ok (eq :incomplete (getf result :verdict)))
        (ok (stringp (getf result :markdown)))
        (when (plusp (length (or (getf result :markdown) "")))
          (ok (search "Budget scope:" (getf result :markdown))
              "partial report still has the budget footer")))))

(deftest s10-hitl-restart-between-rounds
  (ensure-ci-backends)
  (if (not (research-b4b-available-p))
      (skip "demiurge B4b research APIs not on GHCR yet")
      (let* ((approved nil)
             (result
              (handler-bind ((wf:approval-required
                              (lambda (c)
                                (setf approved t)
                                (wf:invoke-approve c))))
                (%s10-run :task-id "s10-hitl"
                          :max-rounds 2
                          :require-hitl t
                          :llm (%s10-llm :gap-once "What is a restart?")))))
        (ok approved "HITL checkpoint was offered between rounds")
        (ok (member (getf result :verdict) '(:pass :fail)))
        (ok (= 2 (length (getf result :children)))))))
