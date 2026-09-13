(in-package #:demiurge-parity)

(defclass script-ks (bb:knowledge-source)
  ((fn :initarg :fn :accessor script-ks-fn)))

(defmethod bb:ks-precondition ((ks script-ks) board)
  (bb:section-bound-p board :prompt))

(defmethod bb:ks-execute ((ks script-ks) board)
  (let ((out (funcall (script-ks-fn ks) (bb:read-section board :prompt))))
    (bb:write-section board :result out)
    out))

(defun make-script-ks (name fn)
  (make-instance 'script-ks :name name :fn fn))

(defun promote-demo-domain (&key (name "parity-improve") cases ks profile)
  (demiurge:make-expert-domain
   :name name
   :ks-set (list (or ks (make-script-ks
                         'echo
                         (lambda (in) (format nil "old: ~a" in)))))
   :eval-suites (list (eval:make-eval-dataset
                       :name "parity-improve"
                       :cases (or cases
                                  (list (eval:make-eval-case
                                         :input "hi"
                                         :expected "echo: hi")))))
   :profile (or profile :personal)
   :catalogue (cap:make-catalogue :world)))

(defun run-promote-cycle (&key domain skill-store journal cycle-id)
  "Mock-LLM candidate wins; default gate promotes."
  (let* ((domain (or domain (promote-demo-domain)))
         (store skill-store))
    (demiurge/improve:run-improvement-cycle
     domain
     :target (first (demiurge:expert-ks-set domain))
     :llm (make-revision-llm "echo: ")
     :skill-store store
     :journal (or journal (task:make-in-memory-journal))
     :cycle-id (or cycle-id "parity-promote")
     :activity-floor 0)))
