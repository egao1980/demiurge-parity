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
                      "websearch-protocol" "toml-protocol"))
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
         (trees (crash-registry-trees))))
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
                                         (%journal-steps journal task))))))
      (ignore-errors
        (uiop:delete-directory-tree
         root
         :validate (lambda (p) (search "parity-h7-crash-" (namestring p)))
         :if-does-not-exist :ignore)))))
