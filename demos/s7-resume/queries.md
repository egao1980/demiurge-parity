# S7 durability — 2-step journal, child SBCL kill, parent replay.
# Expected: before-count=1, after-count=2, fresh-1=0, fresh-2=1, effects=1/1.
# step-1 comes from the journal (not re-executed); step-2 runs on resume.
#
# This file has no query lines. `command = "resume"` in demo.toml is enough.
