(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/h7-eval-integrity
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:eval #:eval-protocol)
                    (#:task #:task-protocol)))

(in-package #:demiurge-parity/tests/h7-eval-integrity)

;;; H7 gate 4 — eval-integrity (H2 + eval-protocol).
;;; Production feedback cannot reach holdout; confidence threshold enforced.

(defun %h7-eval-api-present-p ()
  (and (fboundp 'eval:eval-dataset-role)
       (fboundp 'eval:eval-case-role)
       (fboundp 'eval:assert-no-holdout-overlap)
       (fboundp 'eval:paired-trial-gate-passes-p)
       (find-class 'eval:holdout-admission-error nil)
       (find-class 'eval:holdout-overlap-error nil)))

(deftest h7-eval-integrity-feedback-cannot-enter-holdout
  (ok (%h7-eval-api-present-p)
      "eval-protocol train/dev/holdout APIs are published")
  (ok (fboundp 'demiurge/serve:record-feedback)
      "record-feedback is on published demiurge/serve")
  (ensure-ci-backends)
  (let* ((holdout (eval:make-eval-dataset
                   :name "hold" :role :holdout
                   :cases (list (eval:make-eval-case :input "gold" :expected "gold"
                                                     :role :holdout))))
         (domain (demiurge:make-echo-expert
                  :backend (make-scripted-llm)
                  :name "h7-fb-hold"))
         (hold-n (length (eval:eval-dataset-cases holdout))))
    (setf (demiurge:expert-eval-suites domain) (list holdout))
    (ok (signals (eval:add-case holdout
                                (eval:make-eval-case :input "fb" :expected "fb")
                                :source :human-feedback)
                 'eval:holdout-admission-error)
        "direct add-case of production feedback to holdout is rejected")
    (let* ((new (demiurge/serve:record-feedback
                 domain
                 :answer "echo: hi"
                 :correction "better"
                 :feedback-id "h7-fb-1"
                 :ks-id "echo"))
           (train (find :train (demiurge:expert-eval-suites domain)
                        :key #'eval:eval-dataset-role))
           (hold (find :holdout (demiurge:expert-eval-suites domain)
                       :key #'eval:eval-dataset-role)))
      (ok (eq :train (eval:eval-dataset-role new))
          "feedback lands on a train-role suite")
      (ok (eq :train (eval:eval-dataset-role train)))
      (ok (= hold-n (length (eval:eval-dataset-cases hold)))
          "holdout case count is unchanged")
      (let ((case (car (last (eval:eval-dataset-cases train)))))
        (ok (eq :train (eval:eval-case-role case)))
        (ok (eq :human-feedback (eval:eval-case-source case)))))))

(deftest h7-eval-integrity-confidence-threshold
  (ok (fboundp 'eval:paired-trial-gate-passes-p)
      "paired-trial confidence gate is on eval-protocol")
  (let* ((cases (list (eval:make-eval-case :input "hi" :expected "echo: hi")))
         (domain (promote-demo-domain :name "h7-conf" :cases cases))
         (result (demiurge/improve:run-improvement-cycle
                  domain
                  :target (first (demiurge:expert-ks-set domain))
                  :llm (make-revision-llm "echo: ")
                  :journal (task:make-in-memory-journal)
                  :cycle-id "h7-conf"
                  :trials 1
                  :min-sample 1
                  :confidence-threshold 95/100
                  :activity-floor 0)))
    (ok (eq :demote (getf result :verdict))
        "confidence threshold 95/100 rejects a single-trial win")
    (ok (getf result :rollback-p)
        "failed confidence gate records rollback")
    (ok (eq :shadow (getf result :promotion-stage)))
    (ok (= 1 (getf result :candidate-score))
        "candidate still scores 1; the gate, not the score, blocked promote")))

(deftest h7-eval-integrity-search-holdout-disjoint
  (ok (fboundp 'eval:assert-no-holdout-overlap)
      "assert-no-holdout-overlap is on eval-protocol")
  (let* ((train (eval:make-eval-dataset
                 :name "train" :role :train
                 :cases (list (eval:make-eval-case :input "h" :expected "echo: h"
                                                   :role :train))))
         (holdout (eval:make-eval-dataset
                   :name "hold" :role :holdout
                   :cases (list (eval:make-eval-case :input "h" :expected "echo: h"
                                                     :role :holdout))))
         (domain (demiurge:make-expert-domain
                  :name "h7-overlap"
                  :ks-set (list (make-script-ks
                                 'echo
                                 (lambda (in) (format nil "old: ~a" in))))
                  :eval-suites (list train holdout)
                  :profile :personal)))
    (ok (signals (eval:assert-no-holdout-overlap train holdout)
                 'eval:holdout-overlap-error)
        "overlapping train/holdout keys are rejected")
    (ok (signals (demiurge/improve:run-improvement-cycle
                  domain
                  :target (first (demiurge:expert-ks-set domain))
                  :llm (make-revision-llm "echo: ")
                  :journal (task:make-in-memory-journal)
                  :cycle-id "h7-overlap"
                  :activity-floor 0)
                 'eval:holdout-overlap-error)
        "improve cycle refuses overlapping search and holdout")))
