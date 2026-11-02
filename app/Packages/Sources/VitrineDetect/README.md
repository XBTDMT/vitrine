# VitrineDetect

roadmap: S-11, S-20

Obscura's detector engine (ObscuraDetect, Obscura B-3), ported for Vitrine on 2026-10-31 by G-22: the 84-detector
catalogue, the confusable fold, validators, allow rules, block scope, bounded regex work and the Scanner, with
every detector's text fixtures and tests. It is the same author's code, so the port carries no licence question.

Vitrine uses it on exact text (`Scanner.Input` for typed text, never the OCR `.recognized` mode): the Claude
connector's `scan_secrets` (X-9, S-11) and the secret banner on text previews (T-4, S-20).

What changed in the port: the module name; Obscura's logger is `DetectLog.swift` (counts and ids only, as before);
the OCR-only image fixture test is not carried (Vitrine reads text, not screenshots). The specification the code
cites as DETECTORS.md lives in Obscura's repository, `knowledge/spec/DETECTORS.md`. A fix to a detector here is
also owed to Obscura, and the reverse.
