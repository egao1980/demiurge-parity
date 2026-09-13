(in-package #:demiurge-parity)

;;; S3 helpers: fixture extract → chunk → store, plus RUN-INGEST on fixtures/.

(defun %read-source (source)
  (etypecase source
    (pathname (uiop:read-file-string source))
    (string source)))

(defun %text-document (text &key (filename "sample.txt"))
  (let ((doc (dx:make-extracted-document
              :metadata (dx:make-document-metadata
                         :filename filename
                         :mimetype "text/plain"
                         :content-hash (dx:portable-digest text))
              :blocks (list (dx:make-text-block :text text)))))
    (dx:ensure-ids doc)
    doc))

(defun extract-fixture (source &key format)
  "Extract SOURCE (pathname or string) → EXTRACTED-DOCUMENT.
   :TEXT builds a single text-block; :HTML uses doc-extract-protocol."
  (let* ((fmt (or format
                  (when (pathnamep source)
                    (let ((ext (string-downcase
                                (or (pathname-type source) ""))))
                      (cond
                        ((member ext '("txt" "text") :test #'string=) :text)
                        ((member ext '("html" "htm") :test #'string=) :html)
                        (t nil))))))
         (payload (%read-source source)))
    (if (eq fmt :text)
        (%text-document payload
                        :filename (if (pathnamep source)
                                      (file-namestring source)
                                      "sample.txt"))
        (dx:extract-document nil payload :format (or fmt :html)))))

(defun chunk-extracted (doc &key (document-id "fixture") chunker)
  (let ((chunker (or chunker (rag-backend-text:make-block-tree-chunker))))
    (if (typep doc 'dx:extracted-document)
        (rag-backend-text:chunk-extracted-document
         chunker doc :document-id document-id)
        (rag:chunk chunker
                   (rag:make-rag-document
                    :id document-id
                    :text ""
                    :metadata (list :extracted-document doc))))))

(defun chunk-ids (chunks)
  (mapcar #'rag:rag-chunk-id chunks))

(defun chunk-block-ids (chunks)
  (mapcar (lambda (c) (getf (rag:rag-chunk-metadata c) :block-id))
          chunks))

(defun store-chunks (store chunks &key embedder)
  "Embed via mock (or EMBEDDER) then UPSERT. Returns STORE."
  (let* ((backend (or embedder (make-scripted-llm)))
         (texts (mapcar #'rag:rag-chunk-text chunks))
         (result (llm:embed backend texts))
         (embs (llm:llm-embed-result-embeddings result)))
    (loop for ch in chunks
          for emb in embs
          do (setf (rag:rag-chunk-embedding ch)
                   (llm:llm-embedding-vector emb)))
    (rag:upsert store chunks)
    store))

(defun memory-store-count (store)
  (hash-table-count (slot-value store 'rag-backend-memory::chunks)))

(defun ingest-fixture (source &key format store document-id embedder)
  "extract → block-tree-chunker → store. Returns (values chunks store doc)."
  (let* ((doc (extract-fixture source :format format))
         (chunks (chunk-extracted doc :document-id (or document-id "fixture")))
         (store (or store (rag-backend-memory:make-memory-vector-store))))
    (store-chunks store chunks :embedder embedder)
    (values chunks store doc)))

(defun copy-fixture-corpus (dest)
  "Copy `fixtures/` into DEST. Returns the destination directory."
  (let* ((dest (ensure-directories-exist
                (uiop:ensure-directory-pathname dest)))
         (root (asdf:system-relative-pathname "demiurge-parity" "fixtures/")))
    (dolist (name '("sample.txt" "sample.html"))
      (uiop:copy-file (merge-pathnames name root)
                      (merge-pathnames name dest)))
    dest))

(defun make-fixture-file-source (root)
  "FILE-SOURCE over a copied fixture corpus.
   Pattern SAMPLE.* (not bare *) so pathlib DIRECTORY matches typed names."
  (check-type root (or pathname string))
  (demiurge/ingest:make-file-source
   :root root
   :pattern "sample.*"
   :recursive t))

(defun run-ingest-fixtures (&key store journal embedder task-id domain dest)
  "RUN-INGEST on a fixture corpus. Returns (values result store source domain)."
  (let* ((dest (or dest
                   (ensure-directories-exist
                    (uiop:ensure-directory-pathname
                     (merge-pathnames (format nil "demiurge-parity-corpus-~a/"
                                              (random 1000000))
                                      (uiop:temporary-directory))))))
         (root (copy-fixture-corpus dest))
         (source (make-fixture-file-source root))
         (domain (or domain
                     (demiurge:make-expert-domain :name "parity-ingest")))
         (store (or store (rag:make-mock-vector-store)))
         (journal (or journal (task:make-in-memory-journal)))
         (embedder (or embedder (make-scripted-llm)))
         (result (demiurge/ingest:run-ingest
                  domain source
                  :store store
                  :journal journal
                  :task-id (or task-id "parity-ingest")
                  :embedder embedder)))
    (values result store source domain)))
