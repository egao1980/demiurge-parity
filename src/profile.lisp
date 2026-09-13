(in-package #:demiurge-parity)

(defun boot-personal-profile (&key data-dir config)
  "Personal profile factory in DATA-DIR (SQLite journal/sessions + file corpus)."
  (ensure-ci-backends)
  (demiurge:make-personal-profile :data-dir data-dir :config config))

(defun profile-sqlite-paths (profile)
  "Expected SQLite files under PROFILE's data-dir."
  (let ((root (uiop:ensure-directory-pathname
               (demiurge:profile-data-dir profile))))
    (list :journal (merge-pathnames "journal.sqlite" root)
          :sessions (merge-pathnames "sessions.sqlite" root)
          :rag (merge-pathnames "rag.sqlite" root))))
