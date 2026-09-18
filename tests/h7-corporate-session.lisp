(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/h7-corporate-session
  (:use #:cl #:rove #:demiurge-parity)
  (:local-nicknames (#:conv #:conversation-protocol)
                    (#:jwt #:cl-stack-jwt)
                    (#:task #:task-protocol)))

(in-package #:demiurge-parity/tests/h7-corporate-session)

;;; H7 gate 5 — corporate-session (H3).
;;; Default/missing secret rejected at startup; expired/tampered tokens
;;; rejected; Secure policy explicit.

(defun %h7-session-api-present-p ()
  (and (fboundp 'demiurge:assert-strong-session-secret)
       (fboundp 'demiurge:encode-session-cookie)
       (fboundp 'demiurge:decode-session-cookie)
       (fboundp 'demiurge:session-cookie-header)
       (find-class 'demiurge:weak-session-secret nil)))

(defun %corporate-hs-key ()
  "secret-key-123456789012345678901234")

(defun %write-tmp-toml (text)
  (uiop:with-temporary-file (:pathname path :prefix "parity-h7-corp-"
                             :type "toml" :keep t)
    (with-open-file (out path :direction :output :if-exists :supersede)
      (write-string text out))
    path))

(defun %corporate-cfg ()
  (let ((path (%write-tmp-toml
               (format nil "
[corporate]
postgres.dsn = \"postgres://demiurge:demiurge@127.0.0.1:5432/demiurge\"
tenant.id = \"acme\"

[corporate.oidc]
issuer = \"https://idp.example\"
client-id = \"app\"

[corporate.session]
secret = ~S
kid = \"k1\"
issuer = \"demiurge\"
audience = \"demiurge-session\"
"
                       (%corporate-hs-key))))
        (demiurge:*demiurge-config* nil))
    (demiurge:load-demiurge-config :path path :prefix "DEMIURGE" :env nil)))

(defun %bare-corporate-keys (&key session-secret)
  (append
   (list :data-dir "/tmp/demiurge-h7-unused"
         :config (make-instance 'demiurge:demiurge-config)
         :journal (task:make-in-memory-journal)
         :session-store (conv:make-in-memory-conversation-store)
         :rag-store (rag-backend-memory:make-memory-vector-store)
         :chunker (rag-backend-text:make-recursive-character-chunker
                   :size 200 :overlap 20))
   (when session-secret (list :session-secret session-secret))))

(defun %memory-corporate (tmp &key config)
  (demiurge:make-corporate-profile
   :data-dir tmp
   :config (or config (demiurge:current-demiurge-config))
   :tenant "acme"
   :force-recording t
   :journal (task:make-in-memory-journal)
   :session-store (conv:make-in-memory-conversation-store)
   :rag-store (rag-backend-memory:make-memory-vector-store)
   :chunker (rag-backend-text:make-recursive-character-chunker
             :size 200 :overlap 20)
   :session-secret (%corporate-hs-key)))

(deftest h7-corporate-session-rejects-default-and-missing-secret
  (ok (%h7-session-api-present-p)
      "H3 session-secret APIs are on published demiurge")
  (ensure-ci-backends)
  (let ((demiurge:*session-secret-environ* nil)
        (demiurge:*demiurge-config* nil))
    (ok (signals (apply #'demiurge:make-corporate-profile
                        (%bare-corporate-keys))
                 'demiurge:weak-session-secret)
        "missing secret rejected at startup")
    (ok (signals (apply #'demiurge:make-corporate-profile
                        (%bare-corporate-keys
                         :session-secret "demiurge-corporate-dev"))
                 'demiurge:weak-session-secret)
        "default secret rejected at startup")
    (ok (signals (apply #'demiurge:make-corporate-profile
                        (%bare-corporate-keys :session-secret ""))
                 'demiurge:weak-session-secret)
        "empty secret rejected")
    (ok (signals (apply #'demiurge:make-corporate-profile
                        (%bare-corporate-keys :session-secret "short"))
                 'demiurge:weak-session-secret)
        "short secret rejected")
    (ok (signals (make-instance 'demiurge:corporate-profile)
                 'demiurge:weak-session-secret)
        "make-instance without a strong secret is rejected")))

(deftest h7-corporate-session-rejects-expired-and-tampered
  (ok (and (fboundp 'demiurge:encode-session-cookie)
           (fboundp 'demiurge:decode-session-cookie))
      "encode/decode-session-cookie are on published demiurge")
  (ensure-ci-backends)
  (with-tmp-dir (tmp)
    (let* ((profile (%memory-corporate tmp :config (%corporate-cfg)))
           (now (jwt:unix-time))
           (good (demiurge:encode-session-cookie profile "alice"
                                                 :tenant "acme"
                                                 :roles '("reader")
                                                 :now now)))
      (ok (equal "alice" (getf (demiurge:decode-session-cookie profile good)
                               :subject))
          "valid session decodes")
      (let ((expired (demiurge:encode-session-cookie profile "alice"
                                                     :tenant "acme"
                                                     :now (- now 120)
                                                     :exp (- now 10))))
        (ok (null (demiurge:decode-session-cookie profile expired))
            "expired exp rejected"))
      (let ((future-nbf (demiurge:encode-session-cookie profile "alice"
                                                        :tenant "acme"
                                                        :now now
                                                        :nbf (+ now 3600))))
        (ok (null (demiurge:decode-session-cookie profile future-nbf))
            "future nbf rejected"))
      (let ((bad-iss (demiurge:encode-session-cookie profile "alice"
                                                     :tenant "acme"
                                                     :iss "other-issuer")))
        (ok (null (demiurge:decode-session-cookie profile bad-iss))
            "iss mismatch rejected"))
      (let ((bad-aud (demiurge:encode-session-cookie profile "alice"
                                                     :tenant "acme"
                                                     :aud "other-aud")))
        (ok (null (demiurge:decode-session-cookie profile bad-aud))
            "aud mismatch rejected"))
      (let* ((tampered (copy-seq good)))
        (setf (char tampered (1- (length tampered)))
              (if (char= (char tampered (1- (length tampered))) #\A)
                  #\B #\A))
        (ok (null (demiurge:decode-session-cookie profile tampered))
            "tampered signature rejected")))))

(deftest h7-corporate-session-secure-policy-explicit
  (ok (fboundp 'demiurge:session-cookie-header)
      "session-cookie-header is on published demiurge")
  (ensure-ci-backends)
  (ok (search "Secure" (demiurge:session-cookie-header "tok" :secure t))
      "Secure is present when policy is t")
  (ok (not (search "Secure" (demiurge:session-cookie-header "tok" :secure nil)))
      "Secure is omitted when policy is nil")
  (with-tmp-dir (tmp)
    (let ((profile (%memory-corporate tmp :config (%corporate-cfg))))
      (ok (not (demiurge:corporate-profile-insecure-local-p profile))
          "corporate default is not insecure-local")
      (let ((hdr (demiurge:session-cookie-header
                  "tok"
                  :secure (not (demiurge:corporate-profile-insecure-local-p
                                profile)))))
        (ok (search "Secure" hdr)
            "default corporate cookie policy is Secure"))
      (setf (demiurge:corporate-profile-insecure-local-p profile) t)
      (ok (not (search "Secure"
                       (demiurge:session-cookie-header
                        "tok"
                        :secure (not (demiurge:corporate-profile-insecure-local-p
                                      profile)))))
          "insecure-local omits Secure"))))
