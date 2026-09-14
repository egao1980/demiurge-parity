;;;; Deep-research demo — narrated run-deep-research (B4).
;;;; Prefers a live local model (LM Studio OpenAI-compat, else llama.cpp GGUF).
;;;;   sbcl --load demos/deep-research-demo.lisp
;;;;   or:  ./demos/run-demo.sh deep-research
;;;;
;;;; DEMIURGE_PARITY_DEMO_LLM=auto|live|mock  (default auto)
;;;; LM Studio: OPENAI_BASE_URL / OPENAI_MODEL / LM_API_TOKEN (workspace .env)
;;;; llama.cpp: LLAMA_MODEL_PATH or DEMIURGE_PARITY_LLAMA_MODEL
;;;; Websearch: SearXNG JSON (SEARXNG_URL, default http://127.0.0.1:8888).
;;;;   docker compose --profile search up -d --wait searxng
;;;; DEMIURGE_PARITY_DEMO_WEBSEARCH=auto|live|mock  (default auto)

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

(defun %demo-mode (env-name)
  "auto (default) | live | mock."
  (let ((raw (or (%env env-name)
                 (when (eq (parity-tier) :live-local) "live")
                 "auto")))
    (cond
      ((member raw '("live" "local" "lmstudio" "llama" "searx" "searxng")
               :test #'string-equal)
       :live)
      ((member raw '("mock" "scripted") :test #'string-equal) :mock)
      (t :auto))))

(defun %demo-llm-mode ()
  (%demo-mode "DEMIURGE_PARITY_DEMO_LLM"))

(defun %demo-websearch-mode ()
  (%demo-mode "DEMIURGE_PARITY_DEMO_WEBSEARCH"))

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

(defun %bind-demo-http-client (backend)
  "Client-level 300s for LM Studio generate. search-web/fetch-page set their own request timeouts."
  (setf http-protocol:*http-backend* backend)
  (setf http-protocol:*http-client*
        (http-protocol:make-http-client backend :timeout 300))
  backend)

(defun %ensure-demo-http ()
  "Bind a sync HTTP backend so llm-protocol-openai / searxng-backend can SEND."
  (when http-protocol:*http-backend*
    (unless http-protocol:*http-client*
      (%bind-demo-http-client http-protocol:*http-backend*))
    (return-from %ensure-demo-http http-protocol:*http-backend*))
  (ignore-errors (asdf:load-system "http-backend-dexador" :verbose nil))
  (let ((fn (ignore-errors (find-symbol "MAKE-DEXADOR-BACKEND" :http-backend-dexador))))
    (when (and fn (fboundp fn))
      (return-from %ensure-demo-http
        (%bind-demo-http-client (funcall fn)))))
  (ignore-errors (asdf:load-system "http-backend-async" :verbose nil))
  (ignore-errors (asdf:load-system "event-backend-libuv" :verbose nil))
  (let ((maker (ignore-errors (find-symbol "MAKE-ASYNC-BACKEND" :http-backend-async)))
        (loop-fn (ignore-errors (find-symbol "MAKE-LIBUV-BACKEND" :event-backend-libuv)))
        (slot (ignore-errors (find-symbol "*EVENT-BACKEND-MAKER*" :http-backend-async))))
    (when (and maker (fboundp maker))
      (when (and slot loop-fn (fboundp loop-fn))
        (setf (symbol-value slot) loop-fn))
      (return-from %ensure-demo-http
        (%bind-demo-http-client (funcall maker)))))
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
  (%ensure-demo-http)
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
      (let ((backend (funcall fn :base-url url :api-key token
                              :default-model model)))
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
  "Keep system+user turns. Append a JSON hint user turn for plan/gap so
   live Qwen does not flatten the system prompt into one user blob."
  (let* ((normalized (llm:coerce-turns turns))
         (text (%turns-text normalized)))
    (cond
      ((search "Decompose this question" text)
       (append normalized
               (list (llm:user-turn
                      (format nil "Return ONLY JSON, no markdown:~%~
{\"question\":string,\"subquestions\":[{\"id\":string,\"question\":string,\"rationale\":string}]}~%~
Interpret CL as Common Lisp. Emit 3 short subquestions about KSAR, the blackboard, and the journal.")))))
      ((search "Gap analysis" text)
       (append normalized
               (list (llm:user-turn
                      "Return ONLY JSON {\"question\":string,\"subquestions\":[...]}. Use an empty subquestions array if there are no gaps."))))
      (t normalized))))

(defun %prefill-turns (turns)
  "Trailing assistant ' \\n' skips Qwen/Gemma thinking on LM Studio REST.
   Do not combine with response_format json_schema — the grammar rejects it."
  (append (llm:coerce-turns (%steer-turns turns))
          (list (llm:assistant-turn (format nil " ~%")))))

(defun %wire-settings (settings)
  (let ((s (and settings (llm:coerce-settings settings))))
    (llm:make-llm-settings
     :temperature (or (and s (llm:llm-settings-temperature s)) 0)
     :max-tokens (or (and s (llm:llm-settings-max-tokens s)) 512)
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

(defun %as-plain-list (x)
  "jzon decodes JSON arrays as vectors; make-research-plan mapcar's a list."
  (cond
    ((null x) nil)
    ((listp x) x)
    ((and (vectorp x) (not (stringp x))) (map 'list #'identity x))
    (t (list x))))

(defun %ht-ref (table &rest keys)
  (dolist (k keys)
    (let ((v (or (gethash k table)
                 (and (keywordp k)
                      (gethash (string-downcase (symbol-name k)) table)))))
      (when v (return v)))))

(defun %plan-from-json (json)
  (when (hash-table-p json)
    (demiurge/workflows:make-research-plan
     :question (or (%ht-ref json "question" :question) "")
     :subquestions (%as-plain-list
                    (%ht-ref json "subquestions" :subquestions)))))

(defun %parse-plan-output (schema text)
  "Do not use parse-structured-output here: schema-protocol/jzon leave
   JSON arrays as vectors, and make-research-plan mapcar's a list."
  (declare (ignore schema))
  (let* ((blob (or (%json-blob text) text))
         (json (ignore-errors (llm:try-parse-json-output blob))))
    (or (%plan-from-json json)
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
         (response (handler-case
                       (llm:generate (demo-llm-inner backend) payload
                                     :model model
                                     :settings wire
                                     :tools tools
                                     :tool-choice tool-choice)
                     (error (c)
                       (format t "~&   LLM generate #~D FAILED: ~A~%" n c)
                       (finish-output)
                       (llm:make-llm-response
                        :parts (list (llm:make-llm-text-part
                                      :text (format nil "LLM generate failed: ~A" c)))))))
         (text (%usable-response-text response)))
    (%log-generate backend n prompt response)
    ;; :around strips :output and puts the schema on SETTINGS. Read both.
    (let ((schema (or output
                      (and settings
                           (llm:llm-settings-output (llm:coerce-settings settings))))))
      (when schema
        (setf (llm:llm-response-output response)
              (or (%parse-plan-output schema text)
                  (demiurge/workflows:coerce-research-plan
                   nil :question "CL expert systems")))))
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
     (let* ((text (%turns-text turns))
            (sub-pos (search "Subquestion: " text))
            (sub (when sub-pos
                   (let* ((start (+ sub-pos (length "Subquestion: ")))
                          (end (or (position #\Newline text :start start)
                                   (length text))))
                     (string-trim '(#\Space #\Tab #\Return)
                                  (subseq text start end)))))
            (q (or (find sub questions :test #'string-equal)
                   (find-if (lambda (item) (search item text)) questions))))
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
                    (loop for item in questions
                          for i from 1
                          collect (demiurge/workflows:make-research-subquestion
                                   :id (format nil "q~d" i)
                                   :question item)))))
         ((or (search "ONE subquestion" text)
              (search "research child" text)
              (search "Subquestion:" text))
          (llm:make-llm-response
           :parts (list (llm:make-llm-text-part
                         :text (format nil "ANSWER:~a [src-cite]"
                                       (or q "unknown"))))))
         (t
          (llm:make-llm-response
           :parts (list (llm:make-llm-text-part
                         :text "Cited briefing over KSAR, the blackboard, and the journal.")))))))))

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

(defun %scripted-websearch ()
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

(defun %searxng-url ()
  (or (%env "SEARXNG_URL")
      (%env "DEMIURGE_PARITY_SEARXNG")
      "http://127.0.0.1:8888"))

(defun %ensure-demo-json ()
  (ignore-errors (asdf:load-system "json-backend-jzon" :verbose nil))
  (let ((fn (ignore-errors (find-symbol "USE-JZON-BACKEND" :json-backend-jzon))))
    (when (and fn (fboundp fn) (null json-protocol:*json-backend*))
      (funcall fn)))
  json-protocol:*json-backend*)

(defun %make-searxng (url)
  (%ensure-demo-http)
  (%ensure-demo-json)
  (unless json-protocol:*json-backend*
    (error "json-protocol *json-backend* is unbound"))
  (websearch-protocol:make-searxng-backend :base-url url))

(defun %probe-searxng (url)
  (ignore-errors
    (let ((hits (websearch-protocol:search-web (%make-searxng url)
                                               "common lisp" :count 1)))
      (and hits (plusp (length hits))))))

(defclass demo-logging-websearch (websearch-protocol:websearch-backend)
  ((inner :initarg :inner :accessor demo-ws-inner)
   (kind :initarg :kind :accessor demo-ws-kind)
   (call-n :initform 0 :accessor demo-ws-call-n)
   (fetch-n :initform 0 :accessor demo-ws-fetch-n)))

(defmethod websearch-protocol:search-web ((backend demo-logging-websearch) query
                                          &key count freshness site)
  (incf (demo-ws-call-n backend))
  (let* ((n (demo-ws-call-n backend))
         (hits (websearch-protocol:search-web (demo-ws-inner backend) query
                                              :count count
                                              :freshness freshness
                                              :site site)))
    (format t "~&~%── websearch #~D (~A) ~S → ~D hit~:P~%"
            n (demo-ws-kind backend) query (length hits))
    (dolist (h hits)
      (format t "~&   ~A~%        ~A~%        ~A~%"
              (or (websearch-protocol:search-hit-url h) "")
              (or (websearch-protocol:search-hit-title h) "")
              (%clip (or (websearch-protocol:search-hit-snippet h) "") 220)))
    (finish-output)
    hits))

(defmethod websearch-protocol:fetch-page ((backend demo-logging-websearch) url)
  (incf (demo-ws-fetch-n backend))
  (let ((text (websearch-protocol:fetch-page (demo-ws-inner backend) url)))
    (format t "~&   fetch-page #~D ~A → ~A~%"
            (demo-ws-fetch-n backend) url
            (if (and text (plusp (length text)))
                (format nil "~D chars" (length text))
                "nil"))
    (finish-output)
    text))

(defun %research-websearch ()
  "Live SearXNG via websearch-protocol:make-searxng-backend, else mock."
  (let ((mode (%demo-websearch-mode))
        (url (%searxng-url)))
    (demo-kv "demo-websearch-mode" mode)
    (when (eq mode :mock)
      (demo-narrate "Using scripted mock websearch")
      (return-from %research-websearch (%scripted-websearch)))
    (cond
      ((%probe-searxng url)
       (demo-narrate "Using SearXNG backend at ~A" url)
       (demo-kv "websearch" (list :kind :searxng :url url
                                  :system (asdf:component-version
                                           (asdf:find-system "websearch-protocol" nil))))
       (make-instance 'demo-logging-websearch
                      :kind :searxng
                      :inner (%make-searxng url)))
      ((eq mode :live)
       (format *error-output*
               "~&DEMO FAIL: no SearXNG at ~A. docker compose --profile search up -d --wait searxng~%"
               url)
       (uiop:quit 1))
      ((%ci-p)
       (demo-narrate "No SearXNG in CI — falling back to scripted mock websearch")
       (%scripted-websearch))
      (t
       (format *error-output*
               "~&DEMO FAIL: no SearXNG at ~A. Start it or set DEMIURGE_PARITY_DEMO_WEBSEARCH=mock.~%"
               url)
       (uiop:quit 1)))))

(defun %print-step-instructions (ws)
  (demo-narrate "Initial LLM instructions for each research step / expert")
  (demo-look-at "system prompts for :plan :child :gap :synthesize :expert")
  (dolist (step '(:plan :child :gap :synthesize :expert))
    (%demo-print-block (format nil "instructions ~A" step)
                       (demiurge/workflows:research-instruction ws step))))

(defun %resource-uri (res)
  (if (typep res 'mcp-protocol:mcp-resource)
      (mcp-protocol:mcp-resource-uri res)
      (getf res :uri)))

(defun %resource-text (contents)
  (cond
    ((stringp contents) contents)
    ((hash-table-p contents)
     (let ((vec (or (gethash "contents" contents) (gethash :contents contents))))
       (if (and vec (plusp (length vec)))
           (let ((item (elt vec 0)))
             (if (hash-table-p item)
                 (or (gethash "text" item) "")
                 (princ-to-string item)))
           "")))
    (t (princ-to-string contents))))

(demo-narrate "Deep research — workspace sources (board + RAG + MCP) + per-step instructions")
(demo-look-at "step system prompts, board :source-index, RAG retrieve, MCP list/read, short child answers, synthesis")

(let* ((llm (%research-llm))
       (domain (demiurge:make-cl-dev-expert
                :backend llm
                :name "research-demo"
                :ingest nil
                :profile :personal))
       (board (bb:make-blackboard))
       (question "CL expert systems")
       (ws (demiurge/workflows:make-research-workspace
            :name "research-demo"
            :board board
            :domain domain)))
  (setf demiurge/workflows:*research-phase-hook*
        (lambda (name)
          (format t "~&── phase ~A~%" name)
          (finish-output)))
  (%print-step-instructions ws)
  (demo-narrate "Calling RUN-DEEP-RESEARCH on ~S" question)
  (demo-kv "scripted-subquestions (fallback only)" *research-questions*)
  (demo-kv "expert" (demiurge:expert-name domain))
  (let ((result (llm:with-auto-ignore-output
                  (demiurge/workflows:run-deep-research
                   domain question
                   :max-rounds 1
                   :llm llm
                   :websearch (%research-websearch)
                   :journal (task:make-in-memory-journal)
                   :task-id "research-demo"
                   :blackboard board
                   :workspace ws))))
    (demo-narrate "Workflow finished")
    (demo-kv "verdict" (getf result :verdict))
    (demo-kv "child count" (length (getf result :children)))
    (demo-narrate "Per-child cited answers (summaries, not page dumps)")
    (dolist (child (getf result :children))
      (format t "~&~%   ### ~A~%" (or (getf child :question) "?"))
      (format t "~&   answer:~%~{   ~A~%~}"
              (uiop:split-string (%clip (or (getf child :answer) "") 800)
                                 :separator '(#\Newline)))
      (demo-kv "answer-chars" (length (or (getf child :answer) "")))
      (dolist (cite (getf child :citations))
        (demo-kv "cite" cite))
      (when (getf child :source-ids)
        (demo-kv "source-ids" (getf child :source-ids))))
    (demo-narrate "Blackboard workspace — source index (ids/URIs, not full text)")
    (demo-kv "section-bound-p :sources" (bb:section-bound-p board :sources))
    (demo-kv "section-bound-p :source-index" (bb:section-bound-p board :source-index))
    (when (bb:section-bound-p board :source-index)
      (dolist (e (bb:read-section board :source-index))
        (format t "~&   [~A] ~A~%        ~A (~A chars)~%"
                (getf e :id) (or (getf e :title) "")
                (or (getf e :uri) "") (or (getf e :chars) 0))))
    (when (bb:section-bound-p board :round-summary)
      (demo-kv ":round-summary" (bb:read-section board :round-summary)))
    (demo-narrate "RAG-style retrieve over the workspace store")
    (dolist (hit (demiurge/workflows:retrieve-research-sources ws "KSAR" :top-k 2))
      (demo-kv "rag-hit" (list :id (getf hit :id)
                               :uri (getf hit :uri)
                               :title (getf hit :title)
                               :score (getf hit :score)
                               :chars (getf hit :chars))))
    (demo-narrate "MCP resources (list + read catalog + one source + one instruction)")
    (let* ((listed (demiurge/workflows:list-research-resources ws))
           (uris (mapcar #'%resource-uri listed))
           (src (find-if (lambda (u) (eql (search "research://source/" u) 0)) uris)))
      (dolist (u uris)
        (demo-kv "mcp-resource" u))
      (%demo-print-block "MCP read research://catalog"
                         (demiurge/workflows:clip-research-text
                          (%resource-text
                           (demiurge/workflows:read-research-resource
                            ws "research://catalog"))
                          1200))
      (%demo-print-block "MCP read research://instructions/child"
                         (%resource-text
                          (demiurge/workflows:read-research-resource
                           ws "research://instructions/child")))
      (when src
        (%demo-print-block (format nil "MCP read ~A (clipped)" src)
                           (demiurge/workflows:clip-research-text
                            (%resource-text
                             (demiurge/workflows:read-research-resource ws src))
                            600))))
    (let ((md (or (getf result :markdown) ""))
          (readable (%strip-markup-comments (or (getf result :markdown) ""))))
      (%demo-print-block "Full research report (markup comments stripped)"
                         readable)
      (demo-kv "raw-markdown-length" (length md)))
    (demo-narrate "Deep-research done. Reviewer: instructions, source-index, RAG hits, MCP reads, short answers, synthesis.")))

(uiop:quit 0)

