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

(unless (asdf:find-system "demiurge-parity" nil)
  (asdf:initialize-source-registry
   `(:source-registry
     (:directory ,*demo-root*)
     :inherit-configuration)))

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
                        "blackboard-protocol" "capability-protocol"
                        "eval-protocol" "rag-protocol" "rag-backend-text"
                        "rag-backend-memory" "doc-extract-protocol"
                        "llm-protocol" "steer-protocol" "task-protocol"
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
