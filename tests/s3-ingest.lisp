(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s3-ingest
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:rag #:rag-protocol)))

(in-package #:demiurge-parity/tests/s3-ingest)

;;; S3 ingest — fixture extract → block-tree-chunker → store.
;;; Helpers are always implemented. Skip the B3 ingest-system call until
;;; demiurge/ingest is loadable; the helper pipeline still runs.

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
              :store-size (memory-store-count store)))))))

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
      (skip "ingest system isn't loadable yet (B3 in flight)")
      (ok (ingest-system-available-p)
          "demiurge/ingest loaded — B3 can flip helpers onto its GFs")))
