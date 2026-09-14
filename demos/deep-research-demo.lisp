;;;; Deep-research demo — narrated run-deep-research (B4, mock LLM + websearch).
;;;;   sbcl --load demos/deep-research-demo.lisp
;;;;   or:  ./demos/run-demo.sh deep-research

(load (merge-pathnames "prelude.lisp"
                       (or *load-truename* *compile-file-truename*)))

(unless (asdf:find-system "demiurge/workflows" nil)
  (format *error-output* "~&DEMO FAIL: demiurge/workflows is not findable from OCI~%")
  (uiop:quit 1))
(asdf:load-system "demiurge/workflows")

(in-package #:demiurge-parity)

(defparameter *research-questions*
  '("What is KSAR?" "What is a blackboard?" "What is a journal?"))

(defun %turns-text (turns)
  (cond
    ((stringp turns) turns)
    ((listp turns)
     (with-output-to-string (s)
       (dolist (tn turns)
         (write-string (if (stringp tn) tn (llm:turn-text tn)) s))))
    (t (princ-to-string turns))))

(defun %research-llm (&key (questions *research-questions*))
  (llm:make-mock-llm-backend
   :handler
   (lambda (backend turns &key &allow-other-keys)
     (declare (ignore backend))
     (let ((text (%turns-text turns)))
       (cond
         ((search "Gap analysis" text)
          (llm:make-llm-response
           :parts (list (llm:make-llm-text-part :text "none"))
           :output (demiurge/workflows:make-research-plan
                    :question "q" :subquestions nil)))
         ((search "Decompose" text)
          (llm:make-llm-response
           :parts (list (llm:make-llm-text-part :text "plan"))
           :output (demiurge/workflows:make-research-plan
                    :question "CL expert systems"
                    :subquestions
                    (loop for q in questions
                          for i from 1
                          collect (demiurge/workflows:make-research-subquestion
                                   :id (format nil "q~d" i)
                                   :question q)))))
         (t
          (llm:make-llm-response
           :parts (list (llm:make-llm-text-part :text "synthesis ok")))))))))

(defun %research-websearch ()
  (websearch-protocol:make-mock-websearch-backend
   :handler
   (lambda (backend query &key &allow-other-keys)
     (declare (ignore backend))
     (list (websearch-protocol:make-search-hit
            :url (format nil "https://ex.test/~a"
                         (substitute #\- #\Space (string query)))
            :title (string query)
            :snippet (format nil "ANSWER:~a" query)
            :rank 1
            :source "mock")))))

(demo-narrate "Deep research — run-deep-research with a scripted mock LLM + mock websearch")
(demo-look-at "verdict, child count, markdown excerpt, board :round-summary, ANSWER: citation lines")

(let* ((domain (demiurge:make-expert-domain
                :name "research-demo"
                :catalogue :world
                :profile :personal))
       (board (bb:make-blackboard))
       (question "CL expert systems"))
  (demo-narrate "Calling RUN-DEEP-RESEARCH on ~S" question)
  (demo-kv "subquestions" *research-questions*)
  (let ((result (demiurge/workflows:run-deep-research
                 domain question
                 :max-rounds 1
                 :llm (%research-llm)
                 :websearch (%research-websearch)
                 :journal (task:make-in-memory-journal)
                 :task-id "research-demo"
                 :blackboard board)))
    (demo-narrate "Workflow finished")
    (demo-kv "verdict" (getf result :verdict))
    (demo-kv "child count" (length (getf result :children)))
    (demo-look-at "verdict is :pass or :fail; three children match the three subquestions")
    (let ((md (or (getf result :markdown) "")))
      (demo-narrate "Markdown excerpt (first 400 chars)")
      (demo-kv "markdown-length" (length md))
      (format t "~&   --- markdown ---~%~A~%   --- end excerpt ---~%"
              (if (> (length md) 400) (subseq md 0 400) md))
      (demo-narrate "Citation-ish ANSWER: lines from the mock websearch snippets")
      (dolist (q *research-questions*)
        (let ((needle (format nil "ANSWER:~a" q)))
          (demo-kv needle (and (search needle md) t)))))
    (demo-narrate "Blackboard :round-summary")
    (demo-kv "section-bound-p :round-summary"
             (bb:section-bound-p board :round-summary))
    (when (bb:section-bound-p board :round-summary)
      (demo-kv ":round-summary" (bb:read-section board :round-summary)))
    (demo-narrate "Deep-research done. Reviewer: verdict + 3 children + ANSWER: cites in the markdown.")))

(uiop:quit 0)
