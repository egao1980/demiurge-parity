;;;; S2 boot demo — narrated personal-profile factory (mock tier).
;;;;   sbcl --load demos/s2-boot-demo.lisp
;;;;   or:  ./demos/run-demo.sh s2-boot

(load (merge-pathnames "prelude.lisp"
                       (or *load-truename* *compile-file-truename*)))
(in-package #:demiurge-parity)

(demo-narrate "S2 boot — personal profile factory in a clean temp dir")
(demo-look-at "profile-kind, bound journal/session/chunker/rag/llm stores, SQLite paths under data-dir")

(with-tmp-dir (tmp)
  (demo-narrate "Calling BOOT-PERSONAL-PROFILE with data-dir ~A" tmp)
  (let* ((profile (boot-personal-profile :data-dir tmp))
         (paths (profile-sqlite-paths profile)))
    (demo-kv "personal-profile-p" (demiurge:personal-profile-p profile))
    (demo-kv "profile-kind" (demiurge:profile-kind profile))
    (demo-kv "journal bound" (and (demiurge:profile-journal profile) t))
    (demo-kv "session-store bound" (and (demiurge:profile-session-store profile) t))
    (demo-kv "chunker bound" (and (demiurge:profile-chunker profile) t))
    (demo-kv "rag-store bound" (and (demiurge:profile-rag-store profile) t))
    (demo-kv "llm-catalog bound" (and (demiurge:profile-llm-catalog profile) t))
    (demo-kv "data-dir exists" (and (probe-file (uiop:ensure-directory-pathname tmp)) t))
    (demo-narrate "Expected SQLite files under the temp data-dir")
    (demo-look-at "journal.sqlite / sessions.sqlite may be absent when the backend is in-memory")
    (dolist (key '(:journal :sessions :rag))
      (let ((path (getf paths key)))
        (demo-kv (format nil "~A path" key) (namestring path))
        (demo-kv (format nil "~A exists" key) (and (probe-file path) t))))
    (demo-narrate "S2 done. Reviewer: :PERSONAL kind and stores bound from a clean temp dir.")))

(uiop:quit 0)
