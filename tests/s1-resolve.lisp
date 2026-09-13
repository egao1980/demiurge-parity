(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s1-resolve
  (:use #:cl #:rove #:demiurge-parity))

(in-package #:demiurge-parity/tests/s1-resolve)

;;; S1 resolve — checkout-only; demiurge + demiurge/improve from GHCR.

(deftest s1-demiurge-systems-resolve
  (ok (asdf:load-system "demiurge" :verbose nil)
      "demiurge loads from published OCI deps")
  (ok (asdf:load-system "demiurge/improve" :verbose nil)
      "demiurge/improve loads from published OCI deps")
  (ok (asdf:find-system "demiurge" nil)
      "demiurge system is registered")
  (ok (asdf:find-system "demiurge/improve" nil)
      "demiurge/improve system is registered")
  (ok (asdf:component-loaded-p "demiurge")
      "demiurge is loaded")
  (ok (asdf:component-loaded-p "demiurge/improve")
      "demiurge/improve is loaded")
  (ok (find-package '#:demiurge)
      "demiurge package exists")
  (ok (find-package '#:demiurge/improve)
      "demiurge/improve package exists")
  (ok (fboundp 'demiurge:make-personal-profile)
      "make-personal-profile is present")
  (ok (fboundp 'demiurge/improve:run-improvement-cycle)
      "run-improvement-cycle is present"))

(deftest s1-stage-unavailable-restarts
  (ok (signals (error 'stage-unavailable :stage :s8 :reason "stub")
               'stage-unavailable))
  (ok (eq :skipped
          (or (handler-bind ((stage-unavailable
                              (lambda (c) (invoke-skip c))))
                (with-parity-restarts
                  (error 'stage-unavailable :stage :s8 :reason "stub")))
              :skipped))
      "SKIP restart declines the stage")
  (ok (equal 42
             (handler-bind ((stage-unavailable
                             (lambda (c) (invoke-use-value 42 c))))
               (with-parity-restarts
                 (error 'stage-unavailable :stage :s8 :reason "stub"))))
      "USE-VALUE restart supplies a stand-in"))
