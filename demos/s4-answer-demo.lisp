;;;; S4 answer demo — narrated echo / cl-dev expert + citing mock LLM.
;;;;   sbcl --load demos/s4-answer-demo.lisp
;;;;   or:  ./demos/run-demo.sh s4-answer

(load (merge-pathnames "prelude.lisp"
                       (or *load-truename* *compile-file-truename*)))
(in-package #:demiurge-parity)

(defun %citations-of (value)
  (cond
    ((and (consp value) (keywordp (first value)))
     (or (getf value :citations) (getf value :citation)))
    ((consp value)
     (cdr (or (assoc :citations value) (assoc :citation value))))
    (t nil)))

(demo-narrate "S4 answer — expert run with a scripted mock LLM")
(demo-look-at "board section writes (:result), and citation :block-id metadata from the fixture")

(demo-narrate "Ingesting fixtures/sample.html (extract → block-tree-chunker → memory store)")
(multiple-value-bind (chunks store doc)
    (ingest-fixture (fixture-pathname "sample.html")
                    :format :html
                    :document-id "sample.html")
  (demo-kv "extracted-document-p" (typep doc 'dx:extracted-document))
  (demo-kv "chunk count" (length chunks))
  (demo-kv "store bound" (and store t))
  (demo-kv "chunk block-ids" (remove nil (chunk-block-ids chunks)))
  (demo-narrate "Building MAKE-CITING-LLM from those block ids, then RUN-EXPERT")
  (let* ((backend (make-citing-llm chunks))
         (cl-dev-p (fboundp 'demiurge:make-cl-dev-expert))
         (domain (if cl-dev-p
                     (demiurge:make-cl-dev-expert
                      :backend backend
                      :name "demo-cl-dev")
                     (demiurge:make-echo-expert
                      :backend backend
                      :name "demo-echo-cite")))
         (board (demiurge:run-expert domain
                                     :trigger '(:prompt "cite the fixture")))
         (result (bb:read-section board :result :default nil))
         (sections (bb:list-sections board))
         (output (ignore-errors
                   (llm:llm-response-output
                    (llm:generate backend "cite the fixture"))))
         (citations (or (%citations-of result) (%citations-of output))))
    (demo-kv "expert" (if cl-dev-p "cl-dev" "echo"))
    (demo-narrate "Board section writes after RUN-EXPERT")
    (demo-look-at "keys on the board plus the :RESULT value")
    (demo-kv "section keys" sections)
    (dolist (key sections)
      (demo-kv key (bb:read-section board key :default nil)))
    (demo-narrate "Citations (block-id metadata)")
    (if citations
        (progn
          (demo-kv "raw citations" citations)
          (demo-kv "citation block-ids" (citation-block-ids citations)))
        (demo-kv "citations" :none-on-this-expert))
    (demo-narrate "S4 done. Reviewer: :RESULT written; citations carry :BLOCK-ID when present.")))

(uiop:quit 0)
