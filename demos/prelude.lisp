;;;; Demo OCI bootstrap + isolated source registry.
;;;; Loaded by run-demo.sh before `demiurge demo` or demos/runner.lisp.
;;;; Narration lives in the product CLI (ask/research/improve/ingest) or
;;;; the one generic runner (boot/resume/corporate).

(setf *debugger-hook*
      (lambda (c h)
        (declare (ignore h))
        (format *error-output* "~&DEMO FAIL: ~A~%" c)
        (uiop:quit 1)))
#+sbcl (sb-ext:disable-debugger)

#+sbcl
(flet ((%linebuf (stream)
         (let ((inner (if (typep stream 'synonym-stream)
                          (symbol-value (synonym-stream-symbol stream))
                          stream)))
           (when (and (typep inner 'sb-sys:fd-stream)
                      (fboundp 'sb-impl::fd-stream-buffering))
             (setf (sb-impl::fd-stream-buffering inner) :line)))))
  (%linebuf *standard-output*)
  (%linebuf *error-output*))
(force-output *standard-output*)
(force-output *error-output*)

(defparameter *demo-root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname
    (or *load-truename* *compile-file-truename* (uiop:getcwd)))))

(defun %demo-oci-dest ()
  (or (let ((v (uiop:getenv "CL_REPOSITORY_DEST")))
        (and v (plusp (length v)) (uiop:ensure-directory-pathname v)))
      (merge-pathnames ".demo-oci/" *demo-root*)))

(defun %demo-client-dir ()
  (or (let ((v (uiop:getenv "CL_REPOSITORY_CLIENT_DIR")))
        (and v (plusp (length v)) (uiop:ensure-directory-pathname v)))
      (probe-file
       (merge-pathnames ".local/share/cl-repository-client/cl-oci-0.16.0/"
                        (user-homedir-pathname)))))

(defun %local-override-directories ()
  "Sibling first-party checkouts beat OCI dest (unpublished protocol fixes).
   Prefer demiurge-plan-vectors: B8 needs demiurge/cli (B9). Do not put
   demiurge-b4b or a stale demiurge/ checkout first — those trees lack the CLI."
  (let* ((parent (uiop:pathname-parent-directory-pathname *demo-root*))
         (cli (probe-file (merge-pathnames "demiurge-plan-vectors/" parent)))
         (cli-protocol (probe-file (merge-pathnames "cli-protocol/" parent))))
    (append
     (loop for name in '("http-backend-dexador" "http-backend-async"
                         "event-backend-libuv" "websearch-protocol"
                         "llm-protocol" "llm-protocol-openai")
           for dir = (probe-file (merge-pathnames (format nil "~A/" name) parent))
           when dir collect `(:directory ,dir))
     (when cli-protocol
       (list `(:directory ,cli-protocol)))
     (when cli
       (list `(:directory ,cli))))))

(defun %isolated-source-registry ()
  "Checkout + dest + client only. Inherited shared trees have stale demiurge."
  (let* ((dest (%demo-oci-dest))
         (client (%demo-client-dir))
         (entries (append (list `(:directory ,*demo-root*))
                          (%local-override-directories)
                          (list `(:tree ,dest)))))
    (when (and client (probe-file client))
      (setf entries (append entries (list `(:tree ,client)))))
    `(:source-registry
      ,@entries
      :ignore-inherited-configuration)))

(defun %pin-isolated-registry ()
  (asdf:initialize-source-registry (%isolated-source-registry)))

(defun %ensure-demo-oci-deps ()
  "Pull OCI deps into CL_REPOSITORY_DEST / .demo-oci. Local demos do not
   wait on CI and must not use a polluted shared systems tree.
   Slash systems (demiurge/cli, demiurge/workflows, …) live in published
   demiurge.asd :provides. Install the primary first, then CLI extras."
  (unless (asdf:find-system "cl-repository-client" nil)
    (%pin-isolated-registry)
    (unless (asdf:find-system "cl-repository-client" nil)
      (return-from %ensure-demo-oci-deps nil)))
  (asdf:load-system "cl-repository-client")
  (let ((dest (%demo-oci-dest))
        (installer (find-package :cl-repository-client/installer)))
    (ensure-directories-exist dest)
    (when installer
      (let ((root (find-symbol "*SYSTEMS-ROOT*" installer)))
        (when root (setf (symbol-value root) dest))))
    (%pin-isolated-registry)
    (uiop:symbol-call :cl-repo :add-registry "https://ghcr.io"
                      :namespace "egao1980/cl-systems"
                      :priority :prepend)
    (uiop:symbol-call :cl-repo :ensure-systems '("demiurge")
                      :default-source :oci)
    (%pin-isolated-registry)
    (uiop:symbol-call :cl-repo :ensure-system-dependencies
                      "demiurge-parity"
                      :also-tests nil
                      :default-source :oci
                      :with '("event-backend-libuv"
                              "sql-backend-sqlite3"
                              "crypto-backend-ironclad"
                              "json-backend-jzon"
                              "toml-backend-tomlet"
                              "cli-protocol"
                              "cli-backend-clingon"
                              "llm-protocol-openai"
                              "llm-protocol/schema"
                              "http-backend-dexador"
                              "http-backend-async"
                              "llm-backend-llama-cpp"))
    (%pin-isolated-registry)
    (uiop:symbol-call :cl-repo :load-system-init-files)
    dest))

(%ensure-demo-oci-deps)

(asdf:load-system "demiurge-parity")
(asdf:load-system "demiurge")
(asdf:load-system "demiurge/cli")
(demiurge-parity:ensure-ci-backends)

(defun %oci-version-from-path (path)
  "If PATH sits under .../systems/<name>/<version>/, return VERSION."
  (when path
    (let* ((ns (namestring (uiop:ensure-directory-pathname path)))
           (marker "/systems/")
           (pos (search marker ns :from-end t :test #'char-equal)))
      (when pos
        (let* ((rest (subseq ns (+ pos (length marker))))
               (parts (remove "" (uiop:split-string rest :separator '(#\/))
                              :test #'string=)))
          (when (>= (length parts) 2)
            (second parts)))))))

(defun %system-version-row (name)
  (let* ((sys (asdf:find-system name nil))
         (ver (and sys (asdf:component-version sys)))
         (dir (ignore-errors
                (namestring (asdf:system-source-directory sys))))
         (oci (and dir (%oci-version-from-path dir))))
    (list :name name
          :asdf (or ver "?")
          :oci oci
          :dir dir
          :loaded (and sys (asdf:component-loaded-p sys) t))))

(defun print-loaded-system-versions ()
  "Header: ASDF versions, plus OCI tag when the source path is a GHCR dest."
  (format t "~&=== loaded system versions ===~%")
  (let* ((root (ignore-errors (demiurge-parity:systems-root-dir)))
         (interesting '("demiurge-parity" "demiurge" "demiurge/cli"
                        "demiurge/improve" "demiurge/workflows"
                        "demiurge/serve" "demiurge/observe"
                        "cli-protocol" "blackboard-protocol"
                        "capability-protocol" "eval-protocol"
                        "rag-protocol" "rag-backend-text"
                        "rag-backend-memory" "doc-extract-protocol"
                        "llm-protocol" "websearch-protocol" "mcp-protocol"
                        "http-backend-dexador" "http-backend-async"
                        "json-backend-jzon"
                        "toml-backend-tomlet" "steer-protocol"
                        "task-protocol" "task-backend-sql" "sql-protocol"
                        "sql-backend-sqlite3" "event-backend-libuv")))
    (when root
      (format t "~&oci systems-root: ~A~%" root))
    (dolist (name interesting)
      (let ((row (%system-version-row name)))
        (format t "~&  ~A  asdf=~A~@[  oci=~A~]~@[  loaded=~A~]~%"
                (getf row :name)
                (getf row :asdf)
                (getf row :oci)
                (getf row :loaded))
        (when (getf row :dir)
          (format t "~&    ~A~%" (getf row :dir)))))
    (format t "~&=== end versions ===~%")
    (finish-output)))

(print-loaded-system-versions)
