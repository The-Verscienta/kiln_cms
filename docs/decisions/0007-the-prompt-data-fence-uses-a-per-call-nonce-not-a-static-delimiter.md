# 0007. The prompt data fence uses a per-call nonce, not a static delimiter

- **Status** — accepted, shipped in
  [0.6.0](../changelog/v0.6.0.md) (Security).
- **References** — [#1065](https://github.com/The-Verscienta/kiln_cms/issues/1065), [#945](https://github.com/The-Verscienta/kiln_cms/issues/945).
- **Changelog** — [0.6.0 → Security](../../CHANGELOG.md#060---2026-08-12).

## Decision

**The three prompt builders' data fence now carries a per-call nonce
instead of a static, publicly-known delimiter** (#1065). #945 twice had to
widen `KilnCMS.LLM.Fence`'s shape matcher — a padding class missing a whole
Unicode category, then a rule-character class missing box-drawing glyphs —
because the set of glyph runs a model reads as "the data ended" has no
closed definition, so no character class ever finishes that job.

`Fence.nonce/0` generates an unguessable token once per `build/1` call;
`KilnCMS.Ask.Prompt`, `KilnCMS.Assist.Prompt` and `KilnCMS.Seo.Prompt` each
thread it through every region in that prompt as
`-----BEGIN <nonce>-----` / `-----END <nonce>-----`. The data cannot
contain the closing token because the attacker cannot guess it, so closing
the fence stops being a matching problem and becomes a guessing one.
`Fence.region/3` is the only way to build a fenced block now — a call site
can no longer forget to escape a value or forget to use the marker the
system prompt actually named, which is the shape that once let
`document.title` sit outside `Seo.Prompt`'s fence for the whole life of
that module (#945).

The shape matcher (`Fence.defence/1`) stays as a second layer — cheap, it
still reads a legitimate horizontal rule as prose rather than a
false-positive close, and it now also neutralizes an attacker's *guess* at
a BEGIN/END-shaped marker line, so a forged token with the wrong nonce
reads as a rule rather than a plausible (if mismatched) close.

Not a complete answer: a nonce closes the shape problem, not the framing
one. A model can still be talked out of the "this is data" instruction by
prose inside the region itself, and in all three builders the untrusted
text is the last thing before the model's turn — the position an attacker
most wants. The real defences are unchanged: the generators get no tools,
and every response is constrained by its own normalizer (`KilnCMS.Ask`,
`KilnCMS.Assist.Suggestion`, `KilnCMS.Seo.Draft`).
