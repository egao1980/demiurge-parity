(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/h7-ingest-failure
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:llm #:llm-protocol)
                    (#:rag #:rag-protocol)
                    (#:task #:task-protocol)))

(in-package #:demiurge-parity/tests/h7-ingest-failure)

;;; H7 gate 6 — ingest-failure (H4).
;;; Extractor/embedder/store faults leave typed retryable state; never
;;; zero vectors or false completion.

(defun %h7-ingest-api-present-p ()
  (and (find-class 'demiurge/ingest:ingest-extractor-error nil)
       (find-class 'demiurge/ingest:ingest-embedder-error nil)
       (find-class 'demiurge/ingest:ingest-store-error nil)
       (find-class 'demiurge/ingest:ingest-stage-error nil)
       (fboundp 'demiurge/ingest:ingest-stage-error-retryable-p)
       (fboundp 'demiurge/ingest:ingest-one-item)
       (fboundp 'demiurge/ingest:list-stored-chunks)))

(defclass %h7-failing-embedder (llm:llm-backend) ())

(defmethod llm:embed ((backend %h7-failing-embedder) inputs
                      &key &allow-other-keys)
  (declare (ignore inputs))
  (error "h7 embedder failed"))

(defclass %h7-failing-store (rag:rag-vector-store) ())

(defmethod rag:upsert ((store %h7-failing-store) chunks)
  (declare (ignore chunks))
  (error "h7 store failed"))

(defun %task-completed-p (journal task-id)
  (let ((task (task:make-durable-task :id task-id :journal journal)))
    (find-if (lambda (ev) (typep ev 'task:task-completed))
             (task:journal-events journal task))))

(defun %item-step-completed-p (journal task-id)
  (let ((task (task:make-durable-task :id task-id :journal journal)))
    (find-if (lambda (ev)
               (and (typep ev 'task:step-completed)
                    (let ((name (task:step-name ev)))
                      (and (stringp name)
                           (search "ingest-item/" name)))))
             (task:journal-events journal task))))

(defun %retry-restart (condition)
  (find-restart (intern "RETRY" :demiurge/ingest) condition))

(deftest h7-ingest-failure-extractor-retryable
  (ok (%h7-ingest-api-present-p)
      "H4 typed ingest-stage errors are on published demiurge/ingest")
  (let* ((item (demiurge/ingest:make-ingest-item
                :id "x.bin" :uri "x.bin"
                :content "not-a-pdf"
                :hash "h7-extract"
                :format :no-such-h7-fmt))
         (store (rag:make-mock-vector-store))
         (seen (handler-case
                   (progn
                     (demiurge/ingest:ingest-one-item
                      item
                      :store store
                      :embedder (make-scripted-llm))
                     nil)
                 (demiurge/ingest:ingest-extractor-error (c) c))))
    (ok (typep seen 'demiurge/ingest:ingest-extractor-error)
        "unknown format is a typed extractor error")
    (ok (eq :extract (demiurge/ingest:ingest-stage-error-stage seen)))
    (ok (demiurge/ingest:ingest-stage-error-retryable-p seen)
        "extractor fault is retryable")
    (ok (null (demiurge/ingest:list-stored-chunks store))
        "failed extract must not upsert a plain-text fallback")))

(deftest h7-ingest-failure-embedder-no-zero-or-complete
  (ok (find-class 'demiurge/ingest:ingest-embedder-error nil)
      "ingest-embedder-error is on published demiurge/ingest")
  (with-tmp-dir (tmp)
    (let* ((root (copy-fixture-corpus tmp))
           (source (make-fixture-file-source root))
           (domain (demiurge:make-expert-domain :name "h7-emb-fail"))
           (store (rag:make-mock-vector-store))
           (journal (task:make-in-memory-journal))
           (demiurge/ingest:*ingest-profile* :live)
           (seen (handler-case
                     (progn
                       (demiurge/ingest:run-ingest
                        domain source
                        :store store
                        :journal journal
                        :task-id "h7-emb-fail"
                        :embedder (make-instance '%h7-failing-embedder))
                       nil)
                   (demiurge/ingest:ingest-embedder-error (c) c))))
      (ok (typep seen 'demiurge/ingest:ingest-embedder-error)
          "live embedder fault is typed")
      (ok (eq :embed (demiurge/ingest:ingest-stage-error-stage seen)))
      (ok (demiurge/ingest:ingest-stage-error-retryable-p seen)
          "embedder fault is retryable")
      (ok (null (demiurge/ingest:list-stored-chunks store))
          "failed embed must not store zero vectors")
      (ok (null (%item-step-completed-p journal "h7-emb-fail"))
          "item step is not journaled on embed failure")
      (ok (null (%task-completed-p journal "h7-emb-fail"))
          "task is not marked complete on embed failure"))))

(deftest h7-ingest-failure-store-retryable
  (ok (find-class 'demiurge/ingest:ingest-store-error nil)
      "ingest-store-error is on published demiurge/ingest")
  (with-tmp-dir (tmp)
    (let* ((root (copy-fixture-corpus tmp))
           (source (make-fixture-file-source root))
           (domain (demiurge:make-expert-domain :name "h7-store-fail"))
           (store (make-instance '%h7-failing-store))
           (journal (task:make-in-memory-journal))
           (tries 0)
           (demiurge/ingest:*ingest-profile* :live)
           (seen (handler-case
                     (handler-bind
                         ((demiurge/ingest:ingest-store-error
                           (lambda (c)
                             (incf tries)
                             (when (= tries 1)
                               (let ((r (%retry-restart c)))
                                 (when r (invoke-restart r)))))))
                       (demiurge/ingest:run-ingest
                        domain source
                        :store store
                        :journal journal
                        :task-id "h7-store-fail"
                        :embedder (make-scripted-llm))
                       nil)
                   (demiurge/ingest:ingest-store-error (c) c))))
      (ok (typep seen 'demiurge/ingest:ingest-store-error)
          "store fault is typed; continue is not offered")
      (ok (eq :store (demiurge/ingest:ingest-stage-error-stage seen)))
      (ok (demiurge/ingest:ingest-stage-error-retryable-p seen)
          "store fault is retryable")
      (ok (>= tries 2)
          "RETRY restart re-enters the store stage")
      (ok (null (%task-completed-p journal "h7-store-fail"))
          "store fault never reports completion"))))
