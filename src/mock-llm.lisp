(in-package #:demiurge-parity)

(defun make-scripted-llm (&key (prefix "echo: ") handler)
  "Scripted mock LLM (CI default tier)."
  (if handler
      (llm:make-mock-llm-backend :handler handler :prefix prefix)
      (llm:make-mock-llm-backend :prefix prefix)))

(defun make-revision-llm (skill-text)
  "Mock that returns a KS-REVISION with SKILL-TEXT (S6 promote path)."
  (llm:make-mock-llm-backend
   :handler (lambda (backend turns &key &allow-other-keys)
              (declare (ignore backend turns))
              (llm:make-llm-response
               :parts (list (llm:make-llm-text-part :text "ok"))
               :output (demiurge/improve:make-ks-revision
                        :skill-text skill-text)))))

(defun citation-block-ids (citations)
  "Collect :BLOCK-ID values from citation plists or alists."
  (mapcar (lambda (c)
            (cond
              ((and (consp c) (keywordp (first c)))
               (getf c :block-id))
              ((consp c)
               (or (cdr (assoc :block-id c))
                   (cdr (assoc "block-id" c :test #'equal))))
              (t nil)))
          citations))

(defun %last-user-text (turns)
  (loop for turn in (reverse (llm:coerce-turns turns))
        when (eq (llm:llm-turn-role turn) :user)
          do (return (or (llm:turn-text turn) ""))))

(defun make-citing-llm (chunks &key (prefix "echo: "))
  "Mock that echoes the prompt and attaches block-id citations from CHUNKS."
  (let ((ids (remove nil (chunk-block-ids chunks))))
    (llm:make-mock-llm-backend
     :handler (lambda (backend turns &key &allow-other-keys)
                (declare (ignore backend))
                (let* ((prompt (%last-user-text turns))
                       (text (concatenate 'string prefix (or prompt "")))
                       (citations (mapcar (lambda (id)
                                            (list :block-id id))
                                          ids)))
                  (llm:make-llm-response
                   :parts (list (llm:make-llm-text-part :text text))
                   :output (list :text text :citations citations)))))))
