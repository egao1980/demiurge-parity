(in-package #:demiurge-parity)

(defun try-load-system (name)
  "Load NAME when findable. Signals STAGE-UNAVAILABLE with SKIP / USE-VALUE."
  (check-type name string)
  (with-parity-restarts
    (let ((sys (asdf:find-system name nil)))
      (unless sys
        (error 'stage-unavailable
               :stage name
               :reason "system not findable"
               :message (format nil "asdf cannot find ~s" name)))
      (asdf:load-system sys :verbose nil)
      sys)))

(defun system-available-p (name)
  (and (asdf:find-system name nil)
       (or (asdf:component-loaded-p name)
           (ignore-errors (asdf:load-system name :verbose nil) t))
       t))

(defun ingest-system-available-p ()
  "True when B3 `demiurge/ingest` is published and loadable."
  (system-available-p "demiurge/ingest"))

(defun serve-system-available-p ()
  "True when B3 `demiurge/serve` is published and loadable."
  (or (system-available-p "demiurge/serve")
      (system-available-p "demiurge/feedback")))

(defun ensure-ci-backends ()
  "Load sqlite + libuv extras used by personal-profile / run-expert."
  (dolist (name '("sql-backend-sqlite3" "event-backend-libuv"))
    (ignore-errors (asdf:load-system name :verbose nil)))
  t)

(defun %env (name)
  (let ((v (uiop:getenv name)))
    (and v (plusp (length v)) v)))

(defun parity-tier ()
  "mock (default) | live-local | live-corporate."
  (let ((raw (or (%env "DEMIURGE_PARITY_TIER") "mock")))
    (cond
      ((member raw '("live-local" "live" "local") :test #'string-equal)
       :live-local)
      ((member raw '("live-corporate" "corporate" "compose") :test #'string-equal)
       :live-corporate)
      (t :mock))))

(defun live-local-endpoint ()
  "LM Studio / llama-cpp URL from DEMIURGE_PARITY_LLM, or NIL."
  (%env "DEMIURGE_PARITY_LLM"))

(defun fixture-pathname (name)
  (asdf:system-relative-pathname "demiurge-parity"
                                 (merge-pathnames name "fixtures/")))

(defmacro with-tmp-dir ((var) &body body)
  `(let ((,var (ensure-directories-exist
                (uiop:ensure-directory-pathname
                 (merge-pathnames (format nil "demiurge-parity-~a-~a/"
                                          (get-universal-time)
                                          (random 1000000))
                                  (uiop:temporary-directory))))))
     (unwind-protect (progn ,@body)
       (ignore-errors
         (uiop:delete-directory-tree
          ,var
          :validate (lambda (p)
                      (search "demiurge-parity-" (namestring p)))
          :if-does-not-exist :ignore)))))
