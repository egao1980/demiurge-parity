(in-package #:demiurge-parity)

(define-condition parity-error (error)
  ((message :initarg :message :reader parity-error-message :initform nil)
   (cause :initarg :cause :reader parity-error-cause :initform nil))
  (:report (lambda (c s)
             (format s "demiurge-parity error~@[: ~A~]~@[: ~A~]"
                     (parity-error-message c)
                     (parity-error-cause c)))))

(define-condition stage-unavailable (parity-error)
  ((stage :initarg :stage :reader stage-unavailable-stage :initform nil)
   (reason :initarg :reason :reader stage-unavailable-reason :initform nil))
  (:report (lambda (c s)
             (format s "stage ~S unavailable~@[: ~A~]~@[: ~A~]"
                     (stage-unavailable-stage c)
                     (stage-unavailable-reason c)
                     (parity-error-message c)))))

(defun call-with-parity-restarts (thunk)
  "Establish RETRY / USE-VALUE / SKIP around THUNK."
  (tagbody
   :retry
     (return-from call-with-parity-restarts
       (restart-case (funcall thunk)
         (retry ()
           :report "Retry the parity operation"
           (go :retry))
         (use-value (value)
           :report "Use a supplied value instead"
           :interactive (lambda ()
                          (format *query-io* "Value to use: ")
                          (force-output *query-io*)
                          (list (read *query-io*)))
           value)
         (skip ()
           :report "Skip this parity stage"
           nil)))))

(defmacro with-parity-restarts (&body body)
  `(call-with-parity-restarts (lambda () ,@body)))

(defun invoke-retry (&optional condition)
  (let ((r (find-restart 'retry condition)))
    (when r (invoke-restart r))))

(defun invoke-use-value (value &optional condition)
  (let ((r (find-restart 'use-value condition)))
    (when r (invoke-restart r value))))

(defun invoke-skip (&optional condition)
  (let ((r (find-restart 'skip condition)))
    (when r (invoke-restart r))))
