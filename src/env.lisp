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
  "True when `demiurge/ingest` is published and loadable."
  (system-available-p "demiurge/ingest"))

(defun serve-system-available-p ()
  "True when `demiurge/serve` is published and loadable."
  (system-available-p "demiurge/serve"))

(defun observe-system-available-p ()
  "True when `demiurge/observe` is published and loadable."
  (system-available-p "demiurge/observe"))

(defun workflows-system-available-p ()
  "True when `demiurge/workflows` is published and loadable."
  (system-available-p "demiurge/workflows"))

(defun demiurge-version-string ()
  (let ((sys (asdf:find-system "demiurge" nil)))
    (and sys (asdf:component-version sys))))

(defun observe-b5b-available-p ()
  "True when published demiurge is >= 0.3.5 and observe is loadable.
   Parity CI does not pin a local demiurge checkout."
  (let ((v (demiurge-version-string)))
    (and v
         (uiop:version<= "0.3.5" v)
         (system-available-p "demiurge/observe"))))

(defun research-b4b-available-p ()
  "True when workflows export B4b helpers (citations + budget footer).
   Skip s10 until unpublished 0.3.6 APIs are on GHCR."
  (and (workflows-system-available-p)
       (let* ((pkg (find-package '#:demiurge/workflows))
              (cites (and pkg (find-symbol "COLLECT-RESEARCH-CITATIONS" pkg)))
              (footer (and pkg (find-symbol "FORMAT-RESEARCH-BUDGET-FOOTER" pkg))))
         (and cites footer (fboundp cites) (fboundp footer)))))

(defun +taxonomy-metric-names+ ()
  '("demiurge.llm.tokens"
    "demiurge.llm.cost"
    "demiurge.ksar.duration"
    "demiurge.llm.latency"
    "demiurge.eval.score"
    "demiurge.task.queue-depth"
    "demiurge.ingest.documents"
    "demiurge.improve.promotions"
    "demiurge.improve.demotions"))

(defun taxonomy-metric-present-p (dump name)
  (find name (getf dump :metrics)
        :key (lambda (m) (getf m :name))
        :test #'equal))

(defun s4-taxonomy-reasons ()
  "Why an S4 answer dump may lack a taxonomy instrument."
  '(("demiurge.llm.latency"
     "S4 uses A2 record-usage, not observe-generate (no latency histogram)")
    ("demiurge.eval.score" "S4 is answer, not improve")
    ("demiurge.ingest.documents" "S4 is answer, not ingest")
    ("demiurge.improve.promotions" "S4 is answer, not improve")
    ("demiurge.improve.demotions" "S4 is answer, not improve")))

(defun taxonomy-coverage (dump &optional extra-reasons)
  "→ alist (NAME . :data | reason-string) for every taxonomy instrument."
  (let ((reasons (append extra-reasons (s4-taxonomy-reasons))))
    (mapcar (lambda (name)
              (cons name
                    (if (taxonomy-metric-present-p dump name)
                        :data
                        (or (second (assoc name reasons :test #'equal))
                            "missing — no documented reason"))))
            (+taxonomy-metric-names+))))

(defun ensure-ci-backends ()
  "Load sqlite + libuv extras used by personal-profile / run-expert.
   Ironclad + jzon are needed for S9 canned OIDC (HS256 + discovery JSON)."
  (dolist (name '("sql-backend-sqlite3" "event-backend-libuv"
                  "crypto-backend-ironclad" "json-backend-jzon"))
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

(defun corporate-postgres-dsn ()
  "Postgres DSN for the live-corporate tier."
  (or (%env "DEMIURGE_CORPORATE__POSTGRES__DSN")
      "postgres://demiurge:demiurge@127.0.0.1:5432/demiurge"))

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
