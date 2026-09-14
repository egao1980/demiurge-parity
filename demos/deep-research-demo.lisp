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

(defparameter *research-hits*
  '(("What is KSAR?"
     "https://ex.test/ksar"
     "KSAR (Knowledge-Source Activation Record) is one KS firing: agenda item, COW workspace, journaled steps.")
    ("What is a blackboard?"
     "https://ex.test/blackboard"
     "The blackboard is the shared working memory. KSs read/write named sections; the controller picks the next KSAR.")
    ("What is a journal?"
     "https://ex.test/journal"
     "The journal is the durable event log. Kill-and-resume replays completed steps; it does not re-execute them.")))

(defun %hit-for (query)
  (or (find query *research-hits* :key #'first :test #'string-equal)
      (list query (format nil "https://ex.test/~a" query) query)))

(defun %strip-markup-comments (md)
  "C3d dump-markup prefixes every block with <!-- {#hash ...} -->. Drop those
   so the report is readable in a terminal recording."
  (with-output-to-string (out)
    (loop with i = 0
          with n = (length md)
          while (< i n)
          do (let ((start (search "<!--" md :start2 i)))
               (cond
                 ((null start)
                  (write-string md out :start i)
                  (setf i n))
                 (t
                  (write-string md out :start i :end start)
                  (let ((end (search "-->" md :start2 start)))
                    (setf i (if end (+ end 3) n))))))))

(defun %demo-print-block (label text)
  (format t "~&~%── ~A~%~A~%" label (string-right-trim '(#\Newline) text))
  (finish-output))

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
           :parts (list (llm:make-llm-text-part
                         :text (format nil
                                       "CL expert systems here are a blackboard + KSAR controller. ~%~
Sub-answers cover the activation record, the shared board, and the durable journal."))))))))))

(defun %research-websearch ()
  (websearch-protocol:make-mock-websearch-backend
   :handler
   (lambda (backend query &key &allow-other-keys)
     (declare (ignore backend))
     (destructuring-bind (title url snippet) (%hit-for query)
       (list (websearch-protocol:make-search-hit
              :url url
              :title title
              :snippet snippet
              :rank 1
              :source "mock"))))))

(demo-narrate "Deep research — run-deep-research with a scripted mock LLM + mock websearch")
(demo-look-at "full synthesized report, each child's answer + citations, board :round-summary")

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
    (demo-look-at "three children, one answer + URL cite each; then the full report")
    (demo-narrate "Per-child results (question → composed answer + citations)")
    (dolist (child (getf result :children))
      (format t "~&~%   ### ~A~%" (or (getf child :question) "?"))
      (format t "~&   answer:~%~{   ~A~%~}"
              (uiop:split-string (or (getf child :answer) "")
                                 :separator '(#\Newline)))
      (dolist (cite (getf child :citations))
        (demo-kv "cite" cite))
      (dolist (hit (getf child :web-hits))
        (format t "~&   hit ~A~%        ~A~%"
                (getf hit :url) (getf hit :snippet))))
    (let* ((md (or (getf result :markdown) ""))
           (readable (%strip-markup-comments md)))
      (%demo-print-block "Full research report (markup comments stripped)"
                         readable)
      (demo-kv "raw-markdown-length" (length md)))
    (demo-narrate "Blackboard :round-summary")
    (demo-kv "section-bound-p :round-summary"
             (bb:section-bound-p board :round-summary))
    (when (bb:section-bound-p board :round-summary)
      (demo-kv ":round-summary" (bb:read-section board :round-summary)))
    (demo-narrate "Deep-research done. Reviewer: read the per-child answers and the full report.")))

(uiop:quit 0)
