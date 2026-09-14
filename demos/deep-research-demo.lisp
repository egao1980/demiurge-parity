;;;; Deep-research demo — narrated run-deep-research (B4).
;;;; Prefers a live local model (LM Studio OpenAI-compat, else llama.cpp GGUF).
;;;;   sbcl --load demos/deep-research-demo.lisp
;;;;   or:  ./demos/run-demo.sh deep-research
;;;;
;;;; DEMIURGE_PARITY_DEMO_LLM=auto|live|mock  (default auto)
;;;; LM Studio: OPENAI_BASE_URL / OPENAI_MODEL / LM_API_TOKEN (workspace .env)
;;;; llama.cpp: LLAMA_MODEL_PATH or DEMIURGE_PARITY_LLAMA_MODEL
;;;; Websearch stays mocked (fixture hits).

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
                    (setf i (if end (+ end 3) n)))))))))

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

(defun %nonempty (s)
  (and (stringp s) (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return) s))) s))

(defun %ci-p ()
  (or (%env "CI") (%env "GITHUB_ACTIONS")))

(defun %demo-llm-mode ()
  "auto (default) | live | mock."
  (let ((raw (or (%env "DEMIURGE_PARITY_DEMO_LLM")
                 (when (eq (parity-tier) :live-local) "live")
                 "auto")))
    (cond
      ((member raw '("live" "local" "lmstudio" "llama") :test #'string-equal) :live)
      ((member raw '("mock" "scripted") :test #'string-equal) :mock)
      (t :auto))))

(defun %dotenv-candidates ()
  (let* ((explicit (%env "DEMIURGE_PARITY_ENV"))
         (root-sym (find-symbol "*DEMO-ROOT*" :cl-user))
         (root (or (and root-sym (boundp root-sym) (symbol-value root-sym))
                   (uiop:getcwd)))
         (parent (uiop:pathname-parent-directory-pathname root)))
    (remove nil
            (list (and explicit (pathname explicit))
                  (merge-pathnames ".env" root)
                  (merge-pathnames ".env" parent)))))

(defun %apply-dotenv-file (path)
  "Set env from PATH. Does not override a non-empty existing value."
  (dolist (raw (uiop:split-string (uiop:read-file-string path)
                                  :separator '(#\Newline #\Return)))
    (let ((line (string-trim '(#\Space #\Tab) raw)))
      (when (and (plusp (length line)) (char/= (char line 0) #\#))
        (when (eql (search "export " line) 0)
          (setf line (string-trim '(#\Space #\Tab) (subseq line 7))))
        (let ((eqpos (position #\= line)))
          (when eqpos
            (let* ((k (string-trim '(#\Space #\Tab) (subseq line 0 eqpos)))
                   (v (string-trim '(#\Space #\Tab) (subseq line (1+ eqpos))))
                   (n (length v)))
              (when (and (>= n 2)
                         (or (and (char= (char v 0) #\") (char= (char v (1- n)) #\"))
                             (and (char= (char v 0) #\') (char= (char v (1- n)) #\'))))
                (setf v (subseq v 1 (1- n))))
              (when (and (plusp (length k)) (not (%env k)))
                (setf (uiop:getenv k) v))))))))
  path)

(defun %load-workspace-dotenv ()
  (dolist (p (%dotenv-candidates))
    (let ((found (probe-file p)))
      (when (and found (not (uiop:directory-pathname-p found)))
        (%apply-dotenv-file found)
        (return found)))))

(defun %ensure-demo-http ()
  "Bind a sync HTTP backend so llm-protocol-openai can hit LM Studio."
  (when http-protocol:*http-backend*
    (return-from %ensure-demo-http http-protocol:*http-backend*))
  (ignore-errors (asdf:load-system "http-backend-dexador" :verbose nil))
  (let ((fn (ignore-errors (find-symbol "MAKE-DEXADOR-BACKEND" :http-backend-dexador))))
    (when (and fn (fboundp fn))
      (return-from %ensure-demo-http
        (setf http-protocol:*http-backend* (funcall fn)))))
  (ignore-errors (asdf:load-system "http-backend-async" :verbose nil))
  (ignore-errors (asdf:load-system "event-backend-libuv" :verbose nil))
  (let ((maker (ignore-errors (find-symbol "MAKE-ASYNC-BACKEND" :http-backend-async)))
        (loop-fn (ignore-errors (find-symbol "MAKE-LIBUV-BACKEND" :event-backend-libuv)))
        (slot (ignore-errors (find-symbol "*EVENT-BACKEND-MAKER*" :http-backend-async))))
    (when (and maker (fboundp maker))
      (when (and slot loop-fn (fboundp loop-fn))
        (setf (symbol-value slot) loop-fn))
      (return-from %ensure-demo-http
        (setf http-protocol:*http-backend* (funcall maker)))))
  (error "no http-protocol backend (need http-backend-dexador or http-backend-async)"))

(defun %lmstudio-base-url ()
  (or (live-local-endpoint)
      (%env "OPENAI_BASE_URL")
      (%env "LM_STUDIO_BASE_URL")
      "http://127.0.0.1:1234/v1"))

(defun %lmstudio-model ()
  (or (%env "DEMIURGE_PARITY_LLM_MODEL")
      (%env "OPENAI_MODEL")
      "local"))

(defun %lmstudio-token ()
  (or (%env "LM_API_TOKEN") (%env "OPENAI_API_KEY")))

(defun %gguf-path ()
  (or (%env "LLAMA_MODEL_PATH")
      (%env "LLAMA_CPP_MODEL")
      (%env "DEMIURGE_PARITY_LLAMA_MODEL")))

(defun %try-lmstudio ()
  "→ (values backend model url) or NIL."
  (ignore-errors (asdf:load-system "llm-protocol-openai" :verbose nil))
  (let ((pkg (find-package '#:llm-protocol-openai)))
    (unless pkg
      (return-from %try-lmstudio nil))
    (let ((fn (find-symbol "MAKE-OPENAI-COMPAT-BACKEND" pkg))
          (url (%lmstudio-base-url))
          (model (%lmstudio-model))
          (token (%lmstudio-token)))
      (unless (and fn (fboundp fn))
        (return-from %try-lmstudio nil))
      (%ensure-demo-http)
      (let ((backend (funcall fn :base-url url :api-key token :default-model model)))
        (handler-case
            (let ((models (llm:list-models backend)))
              (unless models
                (return-from %try-lmstudio nil))
              (values backend model url))
          (error (c)
            (format *error-output* "~&   LM Studio probe failed: ~A~%" c)
            nil))))))

(defun %try-llama-cpp ()
  "→ (values backend model-path) or NIL."
  (let ((path (%gguf-path)))
    (unless (and path (probe-file path))
      (return-from %try-llama-cpp nil))
    (ignore-errors (asdf:load-system "llm-backend-llama-cpp" :verbose nil))
    (let ((pkg (find-package '#:llm-backend-llama-cpp)))
      (unless pkg
        (return-from %try-llama-cpp nil))
      (let ((fn (find-symbol "MAKE-LLAMA-CPP-BACKEND" pkg)))
        (unless (and fn (fboundp fn))
          (return-from %try-llama-cpp nil))
        (values (funcall fn :model-path path) path)))))

(defclass demo-logging-llm (llm:llm-backend)
  ((inner :initarg :inner :accessor demo-llm-inner)
   (kind :initarg :kind :accessor demo-llm-kind)
   (label :initarg :label :accessor demo-llm-label)
   (prefill-p :initarg :prefill-p :accessor demo-llm-prefill-p :initform t)
   (call-n :initform 0 :accessor demo-llm-call-n)))

(defmethod llm:backend-model ((backend demo-logging-llm))
  (or (demo-llm-label backend)
      (llm:backend-model (demo-llm-inner backend))))

(defun %steer-turns (turns)
  "Workflow prompts do not mention JSON. Live Qwen then dumps markdown and
   coerce-research-plan treats the whole blob as one subquestion. Ask for
   JSON only; CL = Common Lisp so the plan matches this stack."
  (let ((text (%turns-text turns)))
    (cond
      ((search "Decompose this question" text)
       (format nil "~A~%~%Return ONLY JSON, no markdown:~%~
{\"question\":string,\"subquestions\":[{\"id\":string,\"question\":string,\"rationale\":string}]}~%~
Interpret CL as Common Lisp. Emit 3 short subquestions about KSAR, the blackboard, and the journal."
               text))
      ((search "Gap analysis" text)
       (format nil "~A~%~%Return ONLY JSON {\"question\":string,\"subquestions\":[...]}. ~
Use an empty subquestions array if there are no gaps."
               text))
      (t turns))))

(defun %prefill-turns (turns)
  "Trailing assistant ' \\n' skips Qwen/Gemma thinking on LM Studio REST.
   Do not combine with response_format json_schema — the grammar rejects it."
  (append (llm:coerce-turns (%steer-turns turns))
          (list (llm:assistant-turn (format nil " ~%")))))

(defun %wire-settings (settings)
  (let ((s (and settings (llm:coerce-settings settings))))
    (llm:make-llm-settings
     :temperature (or (and s (llm:llm-settings-temperature s)) 0)
     :max-tokens (or (and s (llm:llm-settings-max-tokens s)) 2048)
     :stop (and s (llm:llm-settings-stop s))
     :top-p (and s (llm:llm-settings-top-p s))
     :response-format nil
     :output nil
     :extra (or (and s (llm:llm-settings-extra s))
                '(:chat-template-kwargs (:enable-thinking nil))))))

(defun %clip (text &optional (limit 4000))
  (let ((s (or text "")))
    (if (<= (length s) limit)
        s
        (format nil "~A~%… [truncated ~D chars]"
                (subseq s 0 limit) (- (length s) limit)))))

(defun %usable-response-text (response)
  (or (%nonempty (llm:llm-response-text response))
      (%nonempty (llm:llm-response-thinking response))
      ""))

(defun %json-blob (text)
  (let ((s (string-trim '(#\Space #\Tab #\Newline #\Return) (or text ""))))
    (cond
      ((zerop (length s)) nil)
      ((or (char= (char s 0) #\{) (char= (char s 0) #\[)) s)
      (t
       (let ((start (or (search "{" s) (search "[" s))))
         (when start (subseq s start)))))))

(defun %parse-plan-output (schema text)
  (let ((blob (or (%json-blob text) text)))
    (or (ignore-errors (llm:parse-structured-output schema blob))
        (let ((json (ignore-errors (llm:try-parse-json-output blob))))
          (when json
            (ignore-errors (demiurge/workflows:coerce-research-plan json))))
        (when (%nonempty text)
          (ignore-errors (demiurge/workflows:coerce-research-plan text))))))

(defun %log-generate (backend n prompt response)
  (let* ((usage (and response (llm:llm-response-usage response)))
         (text (%usable-response-text response)))
    (format t "~&~%── LLM generate #~D (~A ~A)~%"
            n (demo-llm-kind backend) (or (demo-llm-label backend) "?"))
    (format t "~&   prompt:~%~{   ~A~%~}"
            (uiop:split-string (%clip prompt 2000) :separator '(#\Newline)))
    (format t "~&   response:~%~{   ~A~%~}"
            (uiop:split-string (%clip text 4000) :separator '(#\Newline)))
    (when (and response (llm:llm-response-model response))
      (demo-kv "wire-model" (llm:llm-response-model response)))
    (when (and response (llm:llm-response-finish-reason response))
      (demo-kv "finish" (llm:llm-response-finish-reason response)))
    (when usage
      (demo-kv "tokens"
               (list :in (llm:llm-usage-input-tokens usage)
                     :out (llm:llm-usage-output-tokens usage)
                     :total (llm:llm-usage-total-tokens usage))))
    (finish-output)))

(defmethod llm:generate ((backend demo-logging-llm) turns &key model settings
                         tools tool-choice output)
  (incf (demo-llm-call-n backend))
  (let* ((n (demo-llm-call-n backend))
         (prompt (%turns-text turns))
         (payload (if (demo-llm-prefill-p backend)
                      (%prefill-turns turns)
                      (%steer-turns turns)))
         (wire (%wire-settings settings))
         (response (llm:generate (demo-llm-inner backend) payload
                                 :model model
                                 :settings wire
                                 :tools tools
                                 :tool-choice tool-choice))
         (text (%usable-response-text response)))
    (%log-generate backend n prompt response)
    (when (and output (null (llm:llm-response-output response)))
      (setf (llm:llm-response-output response)
            (or (%parse-plan-output output text)
                (demiurge/workflows:coerce-research-plan nil
                                                        :question "CL expert systems"))))
    (when (and (not (%nonempty (llm:llm-response-text response)))
               (%nonempty text)
               (llm:llm-response-p response))
      (setf (llm:llm-response-parts response)
            (append (llm:llm-response-parts response)
                    (list (llm:make-llm-text-part :text text)))))
    response))

(defun %scripted-research-llm (&key (questions *research-questions*))
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

(defun %research-llm ()
  "Live LM Studio, else llama.cpp, else scripted mock (CI / explicit mock)."
  (let ((mode (%demo-llm-mode))
        (dotenv (%load-workspace-dotenv)))
    (when dotenv
      (demo-kv "dotenv" (namestring dotenv)))
    (demo-kv "demo-llm-mode" mode)
    (when (eq mode :mock)
      (demo-narrate "Using scripted mock LLM (DEMIURGE_PARITY_DEMO_LLM=mock)")
      (return-from %research-llm (%scripted-research-llm)))
    (multiple-value-bind (backend model url)
        (%try-lmstudio)
      (when backend
        (demo-narrate "Using LM Studio ~A at ~A" model url)
        (demo-kv "llm" (list :kind :lmstudio :model model :url url))
        (return-from %research-llm
          (make-instance 'demo-logging-llm
                         :inner backend
                         :kind :lmstudio
                         :label model
                         :prefill-p t))))
    (multiple-value-bind (backend path)
        (%try-llama-cpp)
      (when backend
        (demo-narrate "Using llama.cpp GGUF ~A" path)
        (demo-kv "llm" (list :kind :llama-cpp :model path))
        (return-from %research-llm
          (make-instance 'demo-logging-llm
                         :inner backend
                         :kind :llama-cpp
                         :label path
                         :prefill-p nil))))
    (cond
      ((eq mode :live)
       (format *error-output*
               "~&DEMO FAIL: no live LLM. LM Studio (~A) did not answer and no GGUF at LLAMA_MODEL_PATH.~%"
               (%lmstudio-base-url))
       (uiop:quit 1))
      ((%ci-p)
       (demo-narrate "No live LLM in CI — falling back to scripted mock")
       (%scripted-research-llm))
      (t
       (format *error-output*
               "~&DEMO FAIL: no LM Studio on ~A and no LLAMA_MODEL_PATH. Set DEMIURGE_PARITY_DEMO_LLM=mock to force the scripted backend.~%"
               (%lmstudio-base-url))
       (uiop:quit 1)))))

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

(demo-narrate "Deep research — run-deep-research against a live local LLM (LM Studio / llama.cpp)")
(demo-look-at "LLM generate logs, full synthesized report, each child's answer + citations, board :round-summary")

(let* ((domain (demiurge:make-expert-domain
                :name "research-demo"
                :catalogue :world
                :profile :personal))
       (board (bb:make-blackboard))
       (question "CL expert systems")
       (llm (%research-llm))
       (demiurge/workflows:*research-phase-hook*
        (lambda (name)
          (format t "~&── phase ~A~%" name)
          (finish-output))))
    (demo-narrate "Calling RUN-DEEP-RESEARCH on ~S" question)
    (demo-kv "scripted-subquestions (fallback only)" *research-questions*)
    (let ((result (llm:with-auto-ignore-output
                    (demiurge/workflows:run-deep-research
                     domain question
                     :max-rounds 1
                     :llm llm
                     :websearch (%research-websearch)
                     :journal (task:make-in-memory-journal)
                     :task-id "research-demo"
                     :blackboard board))))
      (demo-narrate "Workflow finished")
      (demo-kv "verdict" (getf result :verdict))
      (demo-kv "child count" (length (getf result :children)))
      (demo-look-at "live plan subquestions, one answer + URL cite each; then the full report")
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
      (demo-narrate "Deep-research done. Reviewer: read the LLM logs, per-child answers, and the full report.")))

(uiop:quit 0)
