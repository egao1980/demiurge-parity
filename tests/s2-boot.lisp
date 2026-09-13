(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package '#:demiurge-parity)
    (asdf:load-system "demiurge-parity")))

(defpackage #:demiurge-parity/tests/s2-boot
  (:use #:cl #:rove #:demiurge-parity))

(in-package #:demiurge-parity/tests/s2-boot)

;;; S2 boot — personal profile factory in a clean temp dir.

(deftest s2-personal-profile-temp-dir
  (ensure-ci-backends)
  (with-tmp-dir (tmp)
    (let* ((profile (boot-personal-profile :data-dir tmp))
           (paths (profile-sqlite-paths profile)))
      (ok (demiurge:personal-profile-p profile)
          "factory returns a personal-profile")
      (ok (eq :personal (demiurge:profile-kind profile)))
      (ok (demiurge:profile-journal profile)
          "SQLite (or in-memory fallback) journal")
      (ok (demiurge:profile-session-store profile)
          "session store")
      (ok (demiurge:profile-chunker profile)
          "file-corpus chunker")
      (ok (demiurge:profile-rag-store profile)
          "file-corpus rag store")
      (ok (demiurge:profile-llm-catalog profile)
          "LLM catalog")
      (ok (probe-file (uiop:ensure-directory-pathname tmp))
          "data-dir exists")
      (when (find-package '#:sql-backend-sqlite3)
        (ok (or (probe-file (getf paths :journal))
                (demiurge:profile-journal profile))
            "journal opened under the temp dir")
        (ok (or (probe-file (getf paths :sessions))
                (demiurge:profile-session-store profile))
            "session store opened under the temp dir")))))
