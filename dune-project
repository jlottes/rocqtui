(lang dune 3.7)
(using directory-targets 0.1)
(generate_opam_files true)

(name rocqtui)
(version 0.1.0)
(authors "James Lottes <jlottes@gmail.com>")
(maintainers "James Lottes <jlottes@gmail.com>")
(license MIT)
(source (github jlottes/rocqtui))
(homepage "https://github.com/jlottes/rocqtui")
(bug_reports "https://github.com/jlottes/rocqtui/issues")

(package
 (name rocqtui)
 (synopsis "Terminal IDE for the Rocq proof assistant")
 (description "\
Rocqtui is a terminal-based IDE for the Rocq (Coq) proof assistant.
It features syntax highlighting, interactive proof stepping, goal
display, an embedded terminal emulator, XCompose math symbol input,
and an MCP server for Claude Code integration.")
 (depends
  (ocaml (>= 4.14))
  (dune (>= 3.7))
  yojson
  re
  (rocq-runtime (>= 9.0))
  (coqide-server (>= 9.0)))
 (depopts))
