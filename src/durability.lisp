(in-package #:demiurge-parity)

;;; Thinner A6c: 2-step durable task, child SBCL self-kills after step 1,
;;; parent replays then runs step 2.

(defun sbcl-runtime ()
  (or (let ((env (uiop:getenv "SBCL")))
        (and env (plusp (length env)) env))
      #+sbcl (ignore-errors
               (namestring (truename sb-ext:*runtime-pathname*)))
      (let ((which (ignore-errors
                     (string-trim '(#\Space #\Newline #\Return #\Tab)
                                  (uiop:run-program '("which" "sbcl")
                                                    :output :string
                                                    :ignore-error-status t)))))
        (and which (plusp (length which)) which))
      "sbcl"))

(defun %probe-dir (path)
  (when (and path (plusp (length (namestring path))) (probe-file path))
    (namestring (truename (uiop:ensure-directory-pathname path)))))

(defun %system-dir (name)
  (ignore-errors
    (namestring (truename (asdf:system-source-directory name)))))

(defun systems-root-dir ()
  (or (ignore-errors
        (let* ((pkg (find-package '#:cl-repository-client/installer))
               (sym (and pkg (find-symbol "SYSTEMS-ROOT" pkg))))
          (when (and sym (fboundp sym))
            (%probe-dir (funcall sym)))))
      (%probe-dir (uiop:getenv "CL_REPOSITORY_DEST"))
      (%probe-dir (merge-pathnames ".local/share/cl-repository/systems/"
                                   (user-homedir-pathname)))))

(defun child-registry-dirs ()
  (let ((dirs '()))
    (flet ((add (p)
             (let ((dir (%probe-dir p)))
               (when dir
                 (pushnew dir dirs :test #'string-equal)))))
      (dolist (name '("task-backend-sql" "task-protocol"
                      "sql-protocol" "sql-backend-sqlite3"
                      "dbd-sqlite3" "dbi" "cl-dbi"))
        (add (%system-dir name))))
    (nreverse dirs)))

(defun write-kill-resume-child (script &key db fx-dir marker task-id dirs trees)
  (with-open-file (out script :direction :output :if-exists :supersede)
    (format out ";;;; Generated S7 kill-and-resume child. Do not edit.~%")
    (format out "(require :asdf)~%")
    (format out "#+sbcl (sb-ext:disable-debugger)~%")
    (format out "(setf *debugger-hook*~%")
    (format out "      (lambda (c h)~%")
    (format out "        (declare (ignore h))~%")
    (format out "        (format *error-output* \"~~&CHILD-ERROR: ~~A~~%\" c)~%")
    (format out "        #+sbcl (sb-ext:exit :code 1)~%")
    (format out "        #-sbcl (uiop:quit 1)))~%")
    (format out "(asdf:initialize-source-registry~%")
    (format out " '(:source-registry~%")
    (dolist (dir dirs)
      (format out "   (:directory ~s)~%" (pathname dir)))
    (dolist (tree trees)
      (format out "   (:tree ~s)~%" (pathname tree)))
    (format out "   :inherit-configuration))~%")
    (format out "(asdf:load-system \"sql-backend-sqlite3\")~%")
    (format out "(asdf:load-system \"task-backend-sql\")~%")
    (format out "(let* ((db ~s)~%" (namestring db))
    (format out "       (fx #p~s)~%" (namestring (uiop:ensure-directory-pathname fx-dir)))
    (format out "       (marker #p~s)~%" (namestring marker))
    (format out "       (task-id ~s))~%" task-id)
    (format out "  (flet ((write-effect (name)~%")
    (format out "           (let ((path (merge-pathnames (format nil \"~~a.txt\" name) fx)))~%")
    (format out "             (ensure-directories-exist path)~%")
    (format out "             (with-open-file (o path :direction :output~%")
    (format out "                              :if-exists :append~%")
    (format out "                              :if-does-not-exist :create)~%")
    (format out "               (write-line name o)~%")
    (format out "               (finish-output o)))))~%")
    (format out "    (sql-protocol:with-connection (c :driver :sqlite3 :database-name db)~%")
    (format out "      (let* ((journal (task-backend-sql:make-sql-task-journal :connection c))~%")
    (format out "             (task (task-protocol:make-durable-task :id task-id)))~%")
    (format out "        (task-protocol:with-durable-task (task journal)~%")
    (format out "          (task-protocol:with-durable-step (\"step-1\" :idempotency-key \"k-1\")~%")
    (format out "            (write-effect \"step-1\")~%")
    (format out "            :step-1)~%")
    (format out "          (sql-protocol:execute c \"SELECT COUNT(*) FROM task_journal\")~%")
    (format out "          (with-open-file (m marker :direction :output :if-exists :supersede)~%")
    (format out "            (write-line \"killed-after-step-1\" m)~%")
    (format out "            (finish-output m))~%")
    (format out "          #+sbcl (sb-ext:exit :abort t)~%")
    (format out "          #-sbcl (uiop:quit 0)~%")
    (format out "          (task-protocol:with-durable-step (\"step-2\" :idempotency-key \"k-2\")~%")
    (format out "            (write-effect \"step-2\")~%")
    (format out "            :step-2))))))~%")))

(defun %wait-child (proc &key (timeout 90))
  (loop with start = (get-internal-real-time)
        for elapsed = (/ (- (get-internal-real-time) start)
                         internal-time-units-per-second)
        do (unless (uiop:process-alive-p proc)
             (return (uiop:wait-process proc)))
           (when (> elapsed timeout)
             (uiop:terminate-process proc :urgent t)
             (error 'parity-error
                    :message (format nil "child SBCL timed out after ~a seconds"
                                     timeout)))
           (sleep 0.2)))

(defun %effect-count (fx-dir name)
  (let ((path (merge-pathnames (format nil "~a.txt" name)
                               (uiop:ensure-directory-pathname fx-dir))))
    (if (probe-file path)
        (with-open-file (in path)
          (loop for line = (read-line in nil nil)
                while line
                count t))
        0)))

(defun %journal-steps (journal task)
  (remove-if-not (lambda (e) (typep e 'task:step-completed))
                 (task:journal-events journal task)))

(defun run-kill-resume (&key (task-id "parity-resume"))
  "Kill after step 1, replay, run step 2. Returns a plist of assertions."
  (ensure-ci-backends)
  (unless (find-package '#:sql-backend-sqlite3)
    (error 'stage-unavailable
           :stage :s7-durability
           :reason "sql-backend-sqlite3 is not loadable"))
  (let* ((root (ensure-directories-exist
                (merge-pathnames
                 (format nil "parity-resume-~d-~d/"
                         (get-universal-time)
                         (random 1000000))
                 (uiop:temporary-directory))))
         (db (merge-pathnames "journal.sqlite" root))
         (script (merge-pathnames "child.lisp" root))
         (log (merge-pathnames "child.log" root))
         (fx (ensure-directories-exist (merge-pathnames "fx/" root)))
         (marker (merge-pathnames "killed-after-step-1" root))
         (dirs (child-registry-dirs))
         (trees (remove nil (list (systems-root-dir)
                                  (%probe-dir (uiop:getenv "CL_REPOSITORY_DEST"))))))
    (unwind-protect
         (progn
           (write-kill-resume-child script
                                    :db db :fx-dir fx :marker marker
                                    :task-id task-id
                                    :dirs dirs
                                    :trees trees)
           (let* ((argv (list (sbcl-runtime) "--noinform" "--non-interactive"
                              "--disable-debugger"
                              "--load" (uiop:native-namestring script)))
                  (proc (uiop:launch-program
                         argv
                         :output (uiop:native-namestring log)
                         :error-output :output
                         :if-output-exists :supersede))
                  (code (%wait-child proc)))
             (unless (probe-file marker)
               (error 'parity-error
                      :message (format nil
                                       "child did not reach step-1 abort (exit ~a)~%~a"
                                       code
                                       (if (probe-file log)
                                           (uiop:read-file-string log)
                                           "")))))
           (sql-protocol:with-connection (c :driver :sqlite3
                                            :database-name (namestring db))
             (let* ((journal (tbsql:make-sql-task-journal :connection c))
                    (task (task:make-durable-task :id task-id))
                    (before (%journal-steps journal task))
                    (fresh (vector 0 0)))
               (task:with-durable-task (task journal)
                 (task:with-durable-step ("step-1" :idempotency-key "k-1")
                   (incf (aref fresh 0))
                   :must-not-reexec-1)
                 (task:with-durable-step ("step-2" :idempotency-key "k-2")
                   (incf (aref fresh 1))
                   (let ((path (merge-pathnames "step-2.txt" fx)))
                     (ensure-directories-exist path)
                     (with-open-file (o path :direction :output
                                        :if-exists :append
                                        :if-does-not-exist :create)
                       (write-line "step-2" o)))
                   :step-2))
               (list :before-count (length before)
                     :after-count (length (%journal-steps journal task))
                     :fresh-1 (aref fresh 0)
                     :fresh-2 (aref fresh 1)
                     :effect-1 (%effect-count fx "step-1")
                     :effect-2 (%effect-count fx "step-2")
                     :step-names (mapcar #'task:step-name
                                         (%journal-steps journal task))))))
      (ignore-errors
        (uiop:delete-directory-tree
         root
         :validate (lambda (p) (search "parity-resume-" (namestring p)))
         :if-does-not-exist :ignore)))))

(defun crash-registry-dirs ()
  "Parent-resolved system dirs so the crash child can load demiurge
   without inheriting stale workspace trees. Demiurge is first."
  (let ((dirs '())
        (demiurge (%probe-dir (%system-dir "demiurge"))))
    (flet ((add (p)
             (let ((dir (%probe-dir p)))
               (when (and dir (not (and demiurge (string-equal dir demiurge))))
                 (pushnew dir dirs :test #'string-equal)))))
      (dolist (name (child-registry-dirs))
        (add name))
      (dolist (name '("mcp-protocol" "a2a-protocol" "ag-ui-protocol"
                      "http-protocol" "encoding-protocol" "json-protocol"
                      "log-protocol" "blackboard-protocol" "blackboard-journal"
                      "capability-protocol" "ai-agent-protocol"
                      "conversation-protocol" "steer-protocol"
                      "eval-protocol" "llm-protocol" "rag-protocol"
                      "telemetry-protocol" "event-protocol"
                      "cl-stack-config" "cl-stack-oauth2" "cl-stack-jwt"
                      "ldap-protocol" "doc-extract-protocol"
                      "object-store-protocol" "mail-protocol"
                      "websearch-protocol" "toml-protocol"
                      "rag-backend-memory" "rag-backend-text"
                      "demiurge-parity"))
        (add (%system-dir name)))
      (dolist (name (ignore-errors (asdf:already-loaded-systems)))
        (add (%system-dir name))))
    (if demiurge
        (cons demiurge (nreverse dirs))
        (nreverse dirs))))

(defun crash-registry-trees ()
  "Dest + XDG trees. Dest is preferred when both exist; demiurge itself
   is pinned via CRASH-REGISTRY-DIRS."
  (remove-duplicates
   (remove nil
           (list (systems-root-dir)
                 (%probe-dir (uiop:getenv "CL_REPOSITORY_DEST"))
                 (%probe-dir (merge-pathnames
                              ".local/share/cl-repository/systems/"
                              (user-homedir-pathname)))))
   :test #'string-equal))

(defun %kill-point-name (kill-point)
  (let ((name (string-downcase (string kill-point))))
    (cond
      ((member name '("before" "before-receipt") :test #'string=) "before")
      ((member name '("after" "after-receipt") :test #'string=) "after")
      (t (error 'parity-error
                :message (format nil "unknown effect-receipt kill-point ~s"
                                 kill-point))))))

(defun write-effect-receipt-child (script &key db fx-dir marker task-id
                                  activation-id kill-point dirs trees)
  "Child: durable step writes the effect, then journals a receipt.
   KILL-POINT is :before or :after the receipt append."
  (let ((point (%kill-point-name kill-point)))
    (with-open-file (out script :direction :output :if-exists :supersede)
      (format out ";;;; Generated H7 effect-receipt crash child. Do not edit.~%")
      (format out "(require :asdf)~%")
      ;; cl-stack-pathlib (via demiurge) fasls reference SB-POSIX:S-IXUSR.
      (format out "#+sbcl (require :sb-posix)~%")
      (format out "#+sbcl (sb-ext:disable-debugger)~%")
      (format out "(setf *debugger-hook*~%")
      (format out "      (lambda (c h)~%")
      (format out "        (declare (ignore h))~%")
      (format out "        (format *error-output* \"~~&CHILD-ERROR: ~~A~~%\" c)~%")
      (format out "        #+sbcl (sb-ext:exit :code 1)~%")
      (format out "        #-sbcl (uiop:quit 1)))~%")
      (format out "(asdf:initialize-source-registry~%")
      (format out " '(:source-registry~%")
      (dolist (dir dirs)
        (format out "   (:directory ~s)~%" (pathname dir)))
      (dolist (tree trees)
        (format out "   (:tree ~s)~%" (pathname tree)))
      ;; Inherited workspace trees still carry stale demiurge checkouts.
      (format out "   :ignore-inherited-configuration))~%")
      (format out "(asdf:load-system \"sql-backend-sqlite3\")~%")
      (format out "(asdf:load-system \"task-backend-sql\")~%")
      (let ((demiurge-asd (ignore-errors
                            (probe-file
                             (merge-pathnames "demiurge.asd"
                                              (first dirs))))))
        (when demiurge-asd
          (format out "(asdf:clear-system \"demiurge\")~%")
          (format out "(asdf:load-asd ~s)~%" demiurge-asd)))
      (format out "(asdf:load-system \"demiurge\")~%")
      (format out "(unless (and (fboundp 'demiurge:journal-effect-receipt)~%")
      (format out "             (fboundp 'demiurge:find-effect-receipt))~%")
      (format out "  (error \"published demiurge is missing effect-receipt APIs\"))~%")
      ;; demiurge may bind serdes JSON. Parent journal-events then
      ;; decode-payload READs the wire as sexp and sees `{`.
      (format out "(let* ((pkg (find-package '#:serdes-protocol))~%")
      (format out "       (sym (and pkg (find-symbol \"*SERDES-FORMAT*\" pkg))))~%")
      (format out "  (when (and sym (boundp sym)) (set sym nil)))~%")
      (format out "(let* ((db ~s)~%" (namestring db))
      (format out "       (fx #p~s)~%" (namestring (uiop:ensure-directory-pathname fx-dir)))
      (format out "       (marker #p~s)~%" (namestring marker))
      (format out "       (task-id ~s)~%" task-id)
      (format out "       (activation ~s)~%" activation-id)
      (format out "       (kill-point ~s))~%" point)
      (format out "  (flet ((write-effect ()~%")
      (format out "           (let ((path (merge-pathnames \"effect.txt\" fx)))~%")
      (format out "             (ensure-directories-exist path)~%")
      (format out "             (with-open-file (o path :direction :output~%")
      (format out "                              :if-exists :append~%")
      (format out "                              :if-does-not-exist :create)~%")
      (format out "               (write-line \"effect\" o)~%")
      (format out "               (finish-output o))))~%")
      (format out "         (mark (label)~%")
      (format out "           (with-open-file (m marker :direction :output~%")
      (format out "                            :if-exists :supersede)~%")
      (format out "             (write-line label m)~%")
      (format out "             (finish-output m))))~%")
      (format out "    (sql-protocol:with-connection (c :driver :sqlite3 :database-name db)~%")
      (format out "      (let* ((journal (task-backend-sql:make-sql-task-journal~%")
      (format out "                       :connection c :ensure-schema t))~%")
      (format out "             (task (task-protocol:make-durable-task :id task-id)))~%")
      (format out "        (task-protocol:with-durable-task (task journal)~%")
      (format out "          (task-protocol:with-durable-step~%")
      (format out "              ((format nil \"execute/~~a\" activation)~%")
      (format out "               :idempotency-key activation)~%")
      (format out "            (write-effect)~%")
      (format out "            :effect)~%")
      (format out "          (when (string= kill-point \"before\")~%")
      (format out "            (mark \"killed-before-receipt\")~%")
      (format out "            #+sbcl (sb-ext:exit :abort t)~%")
      (format out "            #-sbcl (uiop:quit 0))~%")
      (format out "          (demiurge:journal-effect-receipt~%")
      (format out "           journal activation~%")
      (format out "           (list :kind :ksar-activation :effect :once)~%")
      (format out "           :task task)~%")
      (format out "          (mark \"killed-after-receipt\")~%")
      (format out "          #+sbcl (sb-ext:exit :abort t)~%")
      (format out "          #-sbcl (uiop:quit 0))))))))~%"))))

(defun %call-without-json-wire (fn)
  "Force sexp-plist journal payloads so a child/parent pair match S7."
  (let* ((pkg (find-package '#:serdes-protocol))
         (sym (and pkg (find-symbol "*SERDES-FORMAT*" pkg))))
    (if (and sym (boundp sym))
        (let ((old (symbol-value sym)))
          (unwind-protect
               (progn (set sym nil) (funcall fn))
            (set sym old)))
        (funcall fn))))

(defun %receipt-present-p (journal activation &key task)
  (and (fboundp 'demiurge:find-effect-receipt)
       (demiurge:find-effect-receipt journal activation :task task)
       t))

(defun run-effect-receipt-crash (&key (task-id "h7-receipt")
                                      (activation-id "h7-act-1")
                                      (kill-point :before))
  "Kill before or after journal-effect-receipt. Resume must not lose or
   duplicate the side effect. Returns a plist of assertions."
  (ensure-ci-backends)
  (unless (find-package '#:sql-backend-sqlite3)
    (error 'stage-unavailable
           :stage :h7-crash-boundary
           :reason "sql-backend-sqlite3 is not loadable"))
  (unless (and (fboundp 'demiurge:journal-effect-receipt)
               (fboundp 'demiurge:find-effect-receipt))
    (error 'stage-unavailable
           :stage :h7-crash-boundary
           :reason "published demiurge is missing journal-effect-receipt / find-effect-receipt"))
  (let* ((point (%kill-point-name kill-point))
         (root (ensure-directories-exist
                (merge-pathnames
                 (format nil "parity-h7-crash-~d-~d/"
                         (get-universal-time)
                         (random 1000000))
                 (uiop:temporary-directory))))
         (db (merge-pathnames "journal.sqlite" root))
         (script (merge-pathnames "child.lisp" root))
         (log (merge-pathnames "child.log" root))
         (fx (ensure-directories-exist (merge-pathnames "fx/" root)))
         (marker (merge-pathnames "killed" root))
         (dirs (crash-registry-dirs))
         (trees (crash-registry-trees)))
    (unwind-protect
         (progn
           (write-effect-receipt-child script
                                       :db db :fx-dir fx :marker marker
                                       :task-id task-id
                                       :activation-id activation-id
                                       :kill-point point
                                       :dirs dirs
                                       :trees trees)
           (let* ((argv (list (sbcl-runtime) "--noinform" "--non-interactive"
                              "--disable-debugger"
                              "--load" (uiop:native-namestring script)))
                  (proc (uiop:launch-program
                         argv
                         :output (uiop:native-namestring log)
                         :error-output :output
                         :if-output-exists :supersede))
                  (code (%wait-child proc :timeout 180)))
             (unless (probe-file marker)
               (error 'parity-error
                      :message (format nil
                                       "child did not reach ~a abort (exit ~a)~%~a"
                                       point
                                       code
                                       (if (probe-file log)
                                           (uiop:read-file-string log)
                                           "")))))
           (%call-without-json-wire
            (lambda ()
              (sql-protocol:with-connection (c :driver :sqlite3
                                               :database-name (namestring db))
                (let* ((journal (tbsql:make-sql-task-journal :connection c
                                                             :ensure-schema t))
                       (task (task:make-durable-task :id task-id))
                       (before-steps (%journal-steps journal task))
                       (before-receipt (%receipt-present-p journal activation-id
                                                           :task task))
                       (fresh 0))
                  (task:with-durable-task (task journal)
                    (task:with-durable-step
                        ((format nil "execute/~a" activation-id)
                         :idempotency-key activation-id)
                      (incf fresh)
                      (let ((path (merge-pathnames "effect.txt" fx)))
                        (ensure-directories-exist path)
                        (with-open-file (o path :direction :output
                                           :if-exists :append
                                           :if-does-not-exist :create)
                          (write-line "effect" o)))
                      :must-not-reexec)
                    (unless (demiurge:find-effect-receipt journal activation-id
                                                          :task task)
                      (demiurge:journal-effect-receipt
                       journal activation-id
                       (list :kind :ksar-activation :effect :once)
                       :task task)))
                  (list :kill-point (intern (string-upcase point) :keyword)
                        :before-count (length before-steps)
                        :after-count (length (%journal-steps journal task))
                        :before-receipt-p before-receipt
                        :after-receipt-p (%receipt-present-p journal activation-id
                                                             :task task)
                        :fresh fresh
                        :effect-count (%effect-count fx "effect")
                        :step-names (mapcar #'task:step-name
                                            (%journal-steps journal task))))))))
      (ignore-errors
        (uiop:delete-directory-tree
         root
         :validate (lambda (p) (search "parity-h7-crash-" (namestring p)))
         :if-does-not-exist :ignore)))))

;;; H7 follow-on gate 8 — cross-process chaos (fan-out / ingest / HITL / promotion).

(defun %append-effect-once (fx-dir name)
  (when (zerop (%effect-count fx-dir name))
    (let ((path (merge-pathnames (format nil "~a.txt" name)
                                 (uiop:ensure-directory-pathname fx-dir))))
      (ensure-directories-exist path)
      (with-open-file (o path :direction :output
                         :if-exists :append
                         :if-does-not-exist :create)
        (write-line name o)
        (finish-output o))))
  (%effect-count fx-dir name))

(defun %chaos-abort (marker label)
  (with-open-file (m marker :direction :output :if-exists :supersede)
    (write-line label m)
    (finish-output m))
  #+sbcl (sb-ext:exit :abort t)
  #-sbcl (uiop:quit 0))

(defun %special-present-p (package-name symbol-name)
  (let* ((pkg (find-package package-name))
         (sym (and pkg (find-symbol symbol-name pkg))))
    (and sym (boundp sym) t)))

(defun %count-typed-events (journal task type)
  (count-if (lambda (e) (typep e type))
            (task:journal-events journal task)))

(defun %item-step-events (journal task)
  (remove-if-not (lambda (e)
                   (and (typep e 'task:step-completed)
                        (let ((name (task:step-name e)))
                          (and (stringp name)
                               (search "ingest-item/" name)))))
                 (task:journal-events journal task)))

(defun chaos-skip-reason (scenario)
  "One-line skip reason naming the missing public API, or NIL when runnable."
  (let ((name (intern (string-upcase (string scenario)) :keyword)))
    (case name
      (:fan-out
       (cond
         ((not (workflows-system-available-p))
          "demiurge/workflows not loadable")
         ((not (fboundp 'demiurge/workflows:run-deep-research))
          "published 0.3.11 missing demiurge/workflows:run-deep-research")
         ((not (%special-present-p '#:demiurge/workflows "*RESEARCH-CHILD-HOOK*"))
          "published 0.3.11 missing demiurge/workflows:*research-child-hook*")
         (t nil)))
      (:ingest
       (cond
         ((not (ingest-system-available-p))
          "demiurge/ingest not loadable")
         ((not (fboundp 'demiurge/ingest:run-ingest))
          "published 0.3.11 missing demiurge/ingest:run-ingest")
         (t nil)))
      (:hitl
       (cond
         ((not (workflows-system-available-p))
          "demiurge/workflows not loadable")
         ((not (fboundp 'demiurge/workflows:start-project))
          "published 0.3.11 missing demiurge/workflows:start-project")
         ((not (fboundp 'demiurge/workflows:await-approval))
          "published 0.3.11 missing demiurge/workflows:await-approval")
         ((not (find-class 'demiurge/workflows:approval-required nil))
          "published 0.3.11 missing demiurge/workflows:approval-required")
         (t nil)))
      (:promotion
       (cond
         ((not (system-available-p "demiurge/improve"))
          "demiurge/improve not loadable")
         ((not (fboundp 'demiurge/improve:run-improvement-cycle))
          "published 0.3.11 missing demiurge/improve:run-improvement-cycle")
         (t nil)))
      (t
       (format nil "unknown chaos scenario ~s" scenario)))))

(defclass chaos-embedder (llm:llm-backend)
  ((inner :initarg :inner :accessor chaos-embedder-inner)
   (fx-dir :initarg :fx-dir :accessor chaos-embedder-fx-dir)
   (marker :initarg :marker :accessor chaos-embedder-marker)
   (kill-p :initarg :kill-p :initform nil :accessor chaos-embedder-kill-p)))

(defmethod llm:embed ((backend chaos-embedder) inputs &key &allow-other-keys)
  (let ((result (llm:embed (chaos-embedder-inner backend) inputs)))
    (%append-effect-once (chaos-embedder-fx-dir backend) "embed")
    (when (chaos-embedder-kill-p backend)
      (%chaos-abort (chaos-embedder-marker backend) "killed-after-embed"))
    result))

(defclass chaos-skill-store (steer:file-skill-store)
  ((fx-dir :initarg :fx-dir :accessor chaos-skill-store-fx-dir)
   (marker :initarg :marker :accessor chaos-skill-store-marker)
   (kill-p :initarg :kill-p :initform nil :accessor chaos-skill-store-kill-p)))

(defmethod steer:save-skill-version :around ((store chaos-skill-store) skill
                                             &key provenance)
  (declare (ignore skill provenance))
  (%append-effect-once (chaos-skill-store-fx-dir store) "promote")
  (when (chaos-skill-store-kill-p store)
    (%chaos-abort (chaos-skill-store-marker store) "killed-around-promotion"))
  (call-next-method))

(defun %chaos-research-llm (&key (question "What is KSAR?"))
  (llm:make-mock-llm-backend
   :handler
   (lambda (backend turns &key &allow-other-keys)
     (declare (ignore backend))
     (let ((text (with-output-to-string (s)
                   (dolist (tn (if (listp turns) turns (list turns)))
                     (write-string (if (stringp tn)
                                       tn
                                       (or (ignore-errors (llm:turn-text tn))
                                           (princ-to-string tn)))
                                 s)))))
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
                    (list (demiurge/workflows:make-research-subquestion
                           :id "q1" :question question)))))
         (t
          (llm:make-llm-response
           :parts (list (llm:make-llm-text-part
                         :text (format nil "ANSWER:~a [src-1]" question))))))))))

(defun %chaos-research-websearch ()
  (websearch-protocol:make-mock-websearch-backend
   :pages (list (cons "https://ex.test/What-is-KSAR?"
                      "<p>ANSWER:What is KSAR? page body.</p>"))
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

(defun %chaos-research-domain ()
  (demiurge:make-expert-domain :name "h7-chaos-research"
                               :catalogue (cap:make-catalogue :world)
                               :profile :personal))

(defun %call-with-research-child-hook (hook thunk)
  (let ((sym (find-symbol "*RESEARCH-CHILD-HOOK*" '#:demiurge/workflows)))
    (unless (and sym (boundp sym))
      (error 'stage-unavailable
             :stage :h7-chaos
             :reason "published 0.3.11 missing demiurge/workflows:*research-child-hook*"))
    (progv (list sym) (list hook)
      (funcall thunk))))

(defun %chaos-child-fan-out (&key db fx-dir marker task-id)
  (%call-with-research-child-hook
   (lambda (child input)
     (declare (ignore child input))
     (%append-effect-once fx-dir "spawn")
     (%chaos-abort marker "killed-after-spawn"))
   (lambda ()
     (sql-protocol:with-connection (c :driver :sqlite3 :database-name db)
       (let ((journal (tbsql:make-sql-task-journal :connection c
                                                   :ensure-schema t)))
         (demiurge/workflows:run-deep-research
          (%chaos-research-domain) "CL expert systems"
          :llm (%chaos-research-llm)
          :websearch (%chaos-research-websearch)
          :journal journal
          :task-id task-id
          :max-rounds 1))))))

(defun %chaos-child-ingest (&key db fx-dir marker task-id corpus-dir)
  (sql-protocol:with-connection (c :driver :sqlite3 :database-name db)
    (let* ((journal (tbsql:make-sql-task-journal :connection c
                                                 :ensure-schema t))
           (source (make-fixture-file-source corpus-dir))
           (domain (demiurge:make-expert-domain :name "h7-chaos-ingest"))
           (store (rag:make-mock-vector-store))
           (embedder (make-instance 'chaos-embedder
                                    :inner (make-scripted-llm)
                                    :fx-dir fx-dir
                                    :marker marker
                                    :kill-p t))
           (demiurge/ingest:*ingest-profile* :live))
      (demiurge/ingest:run-ingest
       domain source
       :store store
       :journal journal
       :task-id task-id
       :embedder embedder))))

(defun %chaos-child-hitl (&key db fx-dir marker task-id)
  (sql-protocol:with-connection (c :driver :sqlite3 :database-name db)
    (let* ((journal (tbsql:make-sql-task-journal :connection c
                                                 :ensure-schema t))
           (domain (demiurge:make-expert-domain
                    :name "h7-chaos-project"
                    :catalogue (cap:make-catalogue :world)
                    :profile :personal))
           (spec (demiurge/workflows:make-project-spec
                  :name "h7-chaos"
                  :milestones '("review"))))
      (handler-case
          (demiurge/workflows:start-project
           domain spec :journal journal :task-id task-id)
        (demiurge/workflows:approval-required ()
          (%append-effect-once fx-dir "wait")
          (%chaos-abort marker "killed-around-await-approval"))))))

(defun %chaos-child-promotion (&key db fx-dir marker task-id cycle-id skill-dir)
  (sql-protocol:with-connection (c :driver :sqlite3 :database-name db)
    (let* ((journal (tbsql:make-sql-task-journal :connection c
                                                 :ensure-schema t))
           (store (make-instance 'chaos-skill-store
                                 :root (uiop:ensure-directory-pathname skill-dir)
                                 :fx-dir fx-dir
                                 :marker marker
                                 :kill-p t)))
      (run-promote-cycle :skill-store store
                         :journal journal
                         :cycle-id (or cycle-id task-id)))))

(defun chaos-child-entry (&key scenario db fx-dir marker task-id
                            cycle-id skill-dir corpus-dir)
  "SBCL child entry. Journals work, then aborts at the named scenario."
  (let ((name (intern (string-upcase (string scenario)) :keyword)))
    (ensure-ci-backends)
    (%call-without-json-wire
     (lambda ()
       (ecase name
         (:fan-out
          (%chaos-child-fan-out :db db :fx-dir fx-dir :marker marker
                                :task-id task-id))
         (:ingest
          (%chaos-child-ingest :db db :fx-dir fx-dir :marker marker
                               :task-id task-id :corpus-dir corpus-dir))
         (:hitl
          (%chaos-child-hitl :db db :fx-dir fx-dir :marker marker
                             :task-id task-id))
         (:promotion
          (%chaos-child-promotion :db db :fx-dir fx-dir :marker marker
                                  :task-id task-id
                                  :cycle-id cycle-id
                                  :skill-dir skill-dir)))))))

(defun write-chaos-child (script &key scenario db fx-dir marker task-id
                          cycle-id skill-dir corpus-dir dirs trees)
  "Child: load published demiurge via crash-registry, then CHAOS-CHILD-ENTRY."
  (with-open-file (out script :direction :output :if-exists :supersede)
    (format out ";;;; Generated H7 chaos crash child. Do not edit.~%")
    (format out "(require :asdf)~%")
    (format out "#+sbcl (require :sb-posix)~%")
    (format out "#+sbcl (sb-ext:disable-debugger)~%")
    (format out "(setf *debugger-hook*~%")
    (format out "      (lambda (c h)~%")
    (format out "        (declare (ignore h))~%")
    (format out "        (format *error-output* \"~~&CHILD-ERROR: ~~A~~%\" c)~%")
    (format out "        #+sbcl (sb-ext:exit :code 1)~%")
    (format out "        #-sbcl (uiop:quit 1)))~%")
    (format out "(asdf:initialize-source-registry~%")
    (format out " '(:source-registry~%")
    (dolist (dir dirs)
      (format out "   (:directory ~s)~%" (pathname dir)))
    (dolist (tree trees)
      (format out "   (:tree ~s)~%" (pathname tree)))
    (format out "   :ignore-inherited-configuration))~%")
    (format out "(asdf:load-system \"sql-backend-sqlite3\")~%")
    (format out "(asdf:load-system \"task-backend-sql\")~%")
    (let ((demiurge-asd (ignore-errors
                          (probe-file
                           (merge-pathnames "demiurge.asd"
                                            (first dirs))))))
      (when demiurge-asd
        (format out "(asdf:clear-system \"demiurge\")~%")
        (format out "(asdf:load-asd ~s)~%" demiurge-asd)))
    (format out "(asdf:load-system \"demiurge-parity\")~%")
    (format out "(let* ((pkg (find-package '#:serdes-protocol))~%")
    (format out "       (sym (and pkg (find-symbol \"*SERDES-FORMAT*\" pkg))))~%")
    (format out "  (when (and sym (boundp sym)) (set sym nil)))~%")
    (format out "(demiurge-parity:chaos-child-entry~%")
    (format out " :scenario ~s~%" (intern (string-upcase (string scenario)) :keyword))
    (format out " :db ~s~%" (namestring db))
    (format out " :fx-dir ~s~%" (namestring (uiop:ensure-directory-pathname fx-dir)))
    (format out " :marker ~s~%" (namestring marker))
    (format out " :task-id ~s~%" task-id)
    (format out " :cycle-id ~s~%" cycle-id)
    (format out " :skill-dir ~s~%" (and skill-dir (namestring skill-dir)))
    (format out " :corpus-dir ~s)~%" (and corpus-dir (namestring corpus-dir)))))

(defun %resume-fan-out (&key db fx-dir task-id)
  (sql-protocol:with-connection (c :driver :sqlite3 :database-name db)
    (let* ((journal (tbsql:make-sql-task-journal :connection c
                                                 :ensure-schema t))
           (task (task:make-durable-task :id task-id :journal journal))
           (before-spawned (%count-typed-events journal task
                                                'task:child-spawned))
           (resume-exec 0))
      (let ((exec-sym (find-symbol "*RESEARCH-CHILD-EXEC-HOOK*"
                                   '#:demiurge/workflows)))
        (progv (if (and exec-sym (boundp exec-sym)) (list exec-sym) '())
            (if (and exec-sym (boundp exec-sym))
                (list (lambda (in)
                        (declare (ignore in))
                        (incf resume-exec)
                        (%append-effect-once fx-dir "resume-exec")))
                '())
          (%call-with-research-child-hook
           nil
           (lambda ()
             (demiurge/workflows:run-deep-research
              (%chaos-research-domain) "CL expert systems"
              :llm (%chaos-research-llm)
              :websearch (%chaos-research-websearch)
              :journal journal
              :task-id task-id
              :max-rounds 1)))))
      (list :before-child-spawned before-spawned
            :after-child-spawned (%count-typed-events
                                  journal task 'task:child-spawned)
            :effect-spawn (%effect-count fx-dir "spawn")
            :resume-exec resume-exec
            :after-count (length (task:journal-events journal task))))))

(defun %resume-ingest (&key db fx-dir task-id corpus-dir)
  (sql-protocol:with-connection (c :driver :sqlite3 :database-name db)
    (let* ((journal (tbsql:make-sql-task-journal :connection c
                                                 :ensure-schema t))
           (task (task:make-durable-task :id task-id :journal journal))
           (before-items (length (%item-step-events journal task)))
           (source (make-fixture-file-source corpus-dir))
           (domain (demiurge:make-expert-domain :name "h7-chaos-ingest"))
           (store (rag:make-mock-vector-store))
           (demiurge/ingest:*ingest-profile* :live))
      (demiurge/ingest:run-ingest
       domain source
       :store store
       :journal journal
       :task-id task-id
       :embedder (make-scripted-llm))
      (let* ((chunks (demiurge/ingest:list-stored-chunks store))
             (ids (mapcar #'rag:rag-chunk-id chunks)))
        (dolist (id ids)
          (%append-effect-once fx-dir (format nil "chunk-~a" id)))
        (%append-effect-once fx-dir "store")
        (list :before-item-steps before-items
              :after-item-steps (length (%item-step-events journal task))
              :chunk-count (length chunks)
              :unique-chunk-ids (length (remove-duplicates ids :test #'equal))
              :effect-embed (%effect-count fx-dir "embed")
              :effect-store (%effect-count fx-dir "store")
              :after-count (length (task:journal-events journal task)))))))

(defun %resume-hitl (&key db fx-dir task-id)
  (sql-protocol:with-connection (c :driver :sqlite3 :database-name db)
    (let* ((journal (tbsql:make-sql-task-journal :connection c
                                                 :ensure-schema t))
           (task (task:make-durable-task :id task-id :journal journal))
           (before-wait (%count-typed-events journal task 'task:wait-input))
           (domain (demiurge:make-expert-domain
                    :name "h7-chaos-project"
                    :catalogue (cap:make-catalogue :world)
                    :profile :personal))
           (spec (demiurge/workflows:make-project-spec
                  :name "h7-chaos"
                  :milestones '("review")))
           (rearmed nil))
      (handler-case
          (demiurge/workflows:start-project
           domain spec :journal journal :task-id task-id)
        (demiurge/workflows:approval-required ()
          (setf rearmed t)))
      (unless rearmed
        (error 'parity-error
               :message "resume did not re-arm await-approval / wait-input"))
      (let ((wf (handler-bind
                    ((demiurge/workflows:approval-required
                      (lambda (c)
                        (demiurge/workflows:invoke-approve c))))
                  (demiurge/workflows:start-project
                   domain spec :journal journal :task-id task-id))))
        (%append-effect-once fx-dir "approved")
        (list :before-wait before-wait
              :after-wait (%count-typed-events journal task 'task:wait-input)
              :approval-steps
              (count-if (lambda (e)
                          (and (typep e 'task:step-completed)
                               (equal "await-approval" (task:step-name e))))
                        (task:journal-events journal task))
              :completed-p (eq :completed
                               (demiurge/workflows:project-workflow-status wf))
              :effect-wait (%effect-count fx-dir "wait")
              :effect-approved (%effect-count fx-dir "approved")
              :after-count (length (task:journal-events journal task)))))))

(defun %resume-promotion (&key db fx-dir task-id cycle-id skill-dir)
  (sql-protocol:with-connection (c :driver :sqlite3 :database-name db)
    (let* ((journal (tbsql:make-sql-task-journal :connection c
                                                 :ensure-schema t))
           (task (task:make-durable-task :id (or cycle-id task-id)
                                         :journal journal))
           (before-promote
            (count-if (lambda (e)
                        (and (typep e 'task:step-completed)
                             (equal "promote" (task:step-name e))))
                      (task:journal-events journal task)))
           (store (make-instance 'chaos-skill-store
                                 :root (uiop:ensure-directory-pathname skill-dir)
                                 :fx-dir fx-dir
                                 :marker (merge-pathnames "unused" fx-dir)
                                 :kill-p nil))
           (result (run-promote-cycle :skill-store store
                                      :journal journal
                                      :cycle-id (or cycle-id task-id)))
           (versions (steer:skill-versions store "parity-improve")))
      (list :before-promote-steps before-promote
            :after-promote-steps
            (count-if (lambda (e)
                        (and (typep e 'task:step-completed)
                             (equal "promote" (task:step-name e))))
                      (task:journal-events journal task))
            :version-count (length versions)
            :verdict (getf result :verdict)
            :effect-promote (%effect-count fx-dir "promote")
            :after-count (length (task:journal-events journal task))))))

(defun run-chaos-crash (&key (scenario :fan-out)
                             (task-id "h7-chaos")
                             (cycle-id "h7-chaos-promote"))
  "Kill a worker mid fan-out / ingest / HITL / promotion. Resume must not
   lose or duplicate journal events or side-effect files."
  (ensure-ci-backends)
  (unless (find-package '#:sql-backend-sqlite3)
    (error 'stage-unavailable
           :stage :h7-chaos
           :reason "sql-backend-sqlite3 is not loadable"))
  (let ((reason (chaos-skip-reason scenario)))
    (when reason
      (error 'stage-unavailable :stage :h7-chaos :reason reason)))
  (let* ((name (intern (string-upcase (string scenario)) :keyword))
         (root (ensure-directories-exist
                (merge-pathnames
                 (format nil "parity-h7-chaos-~a-~d-~d/"
                         (string-downcase (symbol-name name))
                         (get-universal-time)
                         (random 1000000))
                 (uiop:temporary-directory))))
         (db (merge-pathnames "journal.sqlite" root))
         (script (merge-pathnames "child.lisp" root))
         (log (merge-pathnames "child.log" root))
         (fx (ensure-directories-exist (merge-pathnames "fx/" root)))
         (marker (merge-pathnames "killed" root))
         (skill-dir (ensure-directories-exist
                     (merge-pathnames "skills/" root)))
         (corpus-dir (ensure-directories-exist
                      (merge-pathnames "corpus/" root)))
         (dirs (crash-registry-dirs))
         (trees (crash-registry-trees)))
    (when (eq name :ingest)
      (let ((src (fixture-pathname "sample.txt")))
        (uiop:copy-file src (merge-pathnames "sample.txt" corpus-dir))))
    (unwind-protect
         (progn
           (write-chaos-child script
                              :scenario name
                              :db db :fx-dir fx :marker marker
                              :task-id task-id
                              :cycle-id cycle-id
                              :skill-dir skill-dir
                              :corpus-dir corpus-dir
                              :dirs dirs
                              :trees trees)
           (let* ((argv (list (sbcl-runtime) "--noinform" "--non-interactive"
                              "--disable-debugger"
                              "--load" (uiop:native-namestring script)))
                  (proc (uiop:launch-program
                         argv
                         :output (uiop:native-namestring log)
                         :error-output :output
                         :if-output-exists :supersede))
                  (code (%wait-child proc :timeout 300)))
             (unless (probe-file marker)
               (error 'parity-error
                      :message (format nil
                                       "child did not reach ~a abort (exit ~a)~%~a"
                                       name
                                       code
                                       (if (probe-file log)
                                           (uiop:read-file-string log)
                                           "")))))
           (%call-without-json-wire
            (lambda ()
              (let ((base (list :scenario name
                                :killed-p (and (probe-file marker) t))))
                (append
                 base
                 (ecase name
                   (:fan-out
                    (%resume-fan-out :db (namestring db)
                                     :fx-dir fx :task-id task-id))
                   (:ingest
                    (%resume-ingest :db (namestring db)
                                    :fx-dir fx :task-id task-id
                                    :corpus-dir corpus-dir))
                   (:hitl
                    (%resume-hitl :db (namestring db)
                                  :fx-dir fx :task-id task-id))
                   (:promotion
                    (%resume-promotion :db (namestring db)
                                       :fx-dir fx
                                       :task-id task-id
                                       :cycle-id cycle-id
                                       :skill-dir skill-dir))))))))
      (ignore-errors
        (uiop:delete-directory-tree
         root
         :validate (lambda (p) (search "parity-h7-chaos-" (namestring p)))
         :if-does-not-exist :ignore)))))
