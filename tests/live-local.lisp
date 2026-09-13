(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/live-local
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:llm #:llm-protocol)))

(in-package #:demiurge-parity/tests/live-local)

;;; live-local tier — DEMIURGE_PARITY_LLM= LM Studio / llama-cpp endpoint.

(deftest live-local-llm
  (let ((url (live-local-endpoint)))
    (if (null url)
        (skip "DEMIURGE_PARITY_LLM unset (live-local tier)")
        (let ((pkg (ignore-errors
                     (asdf:load-system "llm-protocol-openai" :verbose nil)
                     (find-package '#:llm-protocol-openai))))
          (if (null pkg)
              (skip "llm-protocol-openai not loadable")
              (let* ((fn (find-symbol "MAKE-OPENAI-COMPAT-BACKEND" pkg))
                     (backend (and fn (fboundp fn)
                                   (funcall fn
                                            :base-url url
                                            :default-model
                                            (or (uiop:getenv "DEMIURGE_PARITY_LLM_MODEL")
                                                "local"))))
                     (text (and backend
                                (llm:llm-response-text
                                 (llm:generate backend "ping" :settings
                                               (llm:make-llm-settings
                                                :max-tokens 8))))))
                (ok (and text (plusp (length text)))
                    "live-local generate returned text")))))))
