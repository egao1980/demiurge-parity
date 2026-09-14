;;;; Shared demo prelude. Loaded by each narrated demo script.
;;;; Prints loaded-system versions (ASDF + OCI path when present).

(setf *debugger-hook*
      (lambda (c h)
        (declare (ignore h))
        (format *error-output* "~&DEMO FAIL: ~A~%" c)
        (uiop:quit 1)))
#+sbcl (sb-ext:disable-debugger)

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
   Prefer demiurge-b4b over demiurge-plan-vectors so B4b and B10 do not share a tree."
  (let* ((parent (uiop:pathname-parent-directory-pathname *demo-root*))
         (b4b (probe-file (merge-pathnames "demiurge-b4b/" parent)))
         (b10 (probe-file (merge-pathnames "demiurge-plan-vectors/" parent)))
         (demiurge-dir (or b4b b10)))
    (append
     (loop for name in '("http-backend-dexador" "websearch-protocol")
           for dir = (probe-file (merge-pathnames (format nil "~A/" name) parent))
           when dir collect `(:directory ,dir))
     (when demiurge-dir
       (list `(:directory ,demiurge-dir))))))

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
   Slash systems (demiurge/workflows, …) are not GHCR packages — they
   live in published demiurge.asd :provides. Install the primary first."
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
                              "llm-protocol-openai"
                              "llm-protocol/schema"
                              "http-backend-dexador"
                              "llm-backend-llama-cpp"))
    (%pin-isolated-registry)
    (uiop:symbol-call :cl-repo :load-system-init-files)
    dest))

(%ensure-demo-oci-deps)

(asdf:load-system "demiurge-parity")
(asdf:load-system "demiurge")
(asdf:load-system "demiurge/improve")
(demiurge-parity:ensure-ci-backends)

(in-package #:demiurge-parity)

(defun demo-narrate (fmt &rest args)
  "What is happening."
  (format t "~&~%── ~?~%" fmt args)
  (finish-output))

(defun demo-look-at (fmt &rest args)
  "What a reviewer should look at."
  (format t "~&   look at: ~?~%" fmt args)
  (finish-output))

(defun demo-kv (key value)
  (format t "~&   ~A: ~S~%" key value)
  (finish-output))

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
  (let* ((root (systems-root-dir))
         (interesting '("demiurge-parity" "demiurge" "demiurge/improve"
                        "demiurge/workflows" "demiurge/serve" "demiurge/observe"
                        "blackboard-protocol" "capability-protocol"
                        "eval-protocol" "rag-protocol" "rag-backend-text"
                        "rag-backend-memory" "doc-extract-protocol"
                        "llm-protocol" "websearch-protocol" "mcp-protocol"
                        "http-backend-dexador" "json-backend-jzon"
                        "steer-protocol" "task-protocol"
                        "task-backend-sql" "sql-protocol"
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
