(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s3-ingest
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:rag #:rag-protocol)
                    (#:task #:task-protocol)))

(in-package #:demiurge-parity/tests/s3-ingest)

;;; S3 ingest — fixture extract → block-tree-chunker → store, plus
;;; demiurge/ingest:run-ingest (hash-idempotent re-run).

(defun %run-pipeline (path &key format)
  (multiple-value-bind (chunks store doc)
      (ingest-fixture path :format format :document-id (file-namestring path))
    (let ((ids-1 (chunk-ids chunks)))
      (multiple-value-bind (chunks-2 store-2)
          (ingest-fixture path :format format :store store
                          :document-id (file-namestring path))
        (declare (ignore store-2))
        (list :doc doc
              :n (length chunks)
              :ids ids-1
              :ids-2 (chunk-ids chunks-2)
              :block-ids (remove nil (chunk-block-ids chunks))
              :store-size (memory-store-count store))))))

(deftest s3-helper-extract-chunk-store-idempotent
  (let ((html (fixture-pathname "sample.html"))
        (txt (fixture-pathname "sample.txt")))
    (ok (probe-file html) "tiny HTML fixture")
    (ok (probe-file txt) "tiny text fixture")
    (dolist (pair (list (list html :html) (list txt :text)))
      (let* ((path (first pair))
             (fmt (second pair))
             (result (%run-pipeline path :format fmt)))
        (ok (plusp (getf result :n))
            (format nil "~a produced chunks" (file-namestring path)))
        (ok (equal (getf result :ids) (getf result :ids-2))
            (format nil "~a second run is hash-idempotent" (file-namestring path)))
        (ok (equal (length (getf result :ids))
                   (length (remove-duplicates (getf result :ids) :test #'equal)))
            "chunk ids are unique")
        (ok (plusp (length (getf result :block-ids)))
            "chunks carry block-id metadata")
        (ok (= (getf result :n) (getf result :store-size))
            "store size matches first-run chunk count (no dupes)")))))

(deftest s3-ingest-system
  (if (not (ingest-system-available-p))
      (skip "demiurge/ingest not loadable from OCI")
      (with-tmp-dir (tmp)
        (let ((store (rag:make-mock-vector-store))
              (embedder (make-scripted-llm)))
          (multiple-value-bind (r1 store source domain)
              (run-ingest-fixtures
               :dest tmp
               :store store
               :journal (task:make-in-memory-journal)
               :embedder embedder
               :task-id "parity-ingest-1")
            (ok (plusp (length (demiurge/ingest:enumerate-items source)))
                "fixture corpus enumerates items")
            (let* ((hashes-1 (sort (copy-list
                                    (demiurge/ingest:stored-content-hashes store))
                                   #'string<))
                   (ids-1 (mapcar #'rag:rag-chunk-id
                                  (demiurge/ingest:list-stored-chunks store))))
              (ok (getf r1 :hashes) "first run-ingest returned hashes")
              (ok (plusp (length hashes-1)) "store has content hashes")
              (ok (plusp (length ids-1)) "store has chunk ids")
              (ok (equal (length ids-1)
                         (length (remove-duplicates ids-1 :test #'equal)))
                  "first-run chunk ids are unique")
              (let* ((r2 (demiurge/ingest:run-ingest
                          domain source
                          :store store
                          :journal (task:make-in-memory-journal)
                          :task-id "parity-ingest-2"
                          :embedder embedder))
                     (hashes-2 (sort (copy-list
                                      (demiurge/ingest:stored-content-hashes store))
                                     #'string<))
                     (ids-2 (mapcar #'rag:rag-chunk-id
                                    (demiurge/ingest:list-stored-chunks store))))
                (ok (getf r2 :hashes) "second run-ingest returned hashes")
                (ok (equal hashes-1 hashes-2)
                    "re-run keeps the same content hashes")
                (ok (equal (length ids-2)
                           (length (remove-duplicates ids-2 :test #'equal)))
                    "re-run did not duplicate chunk ids")
                (ok (= (length ids-1) (length ids-2))
                    "store size is unchanged after hash-idempotent re-run"))))))))
