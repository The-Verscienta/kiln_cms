# Architecture decision records

A record here argues **one choice that outlives the release that shipped it**:
why the socket budget is keyed on the actor and not the address, why the
session cookie takes no dual-read window, why events are a shape content can
take rather than a resource of their own. Someone who later proposes the
obvious alternative should find the reason it was already rejected.

Most changes need no record. `CHANGELOG.md` carries a one-line summary of
every change, and [`docs/changelog/`](https://github.com/The-Verscienta/kiln_cms/tree/main/docs/changelog) carries the long-form entry
behind it, verbatim as it was written when the change merged. A record is for
the entry a reader would otherwise have to excavate a release from.

## Reading one

Each file is `NNNN-short-title.md` and opens with its status, the pull requests
and issues behind it, and a link back to the release it shipped in. The body is
the reasoning as its author wrote it.

Records are **not** revised when the code moves on. A superseded record keeps
its text and gains a status line naming the record that replaced it — the
argument that was made at the time is the thing being preserved.

## Adding one

Write the change up in `CHANGELOG.md` as normal. If the entry turns out to be
an argument rather than an announcement, add it to `@decisions` in
[`mix kiln.changelog`](../../lib/mix/tasks/kiln.changelog.ex) — version,
section, a distinctive phrase from the entry's opening, the next number, and a
title stating the decision — then run:

```bash
mix kiln.changelog --condense
```

The record is written from the entry, the changelog summary is re-pointed at
it, and `mix kiln.changelog --verify HEAD` proves nothing was dropped on the
way.
