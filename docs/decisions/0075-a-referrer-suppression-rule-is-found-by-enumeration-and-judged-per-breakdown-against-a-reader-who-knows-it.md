# 0075. A referrer suppression rule is found by enumeration and judged per breakdown against a reader who knows it

- **Status** — accepted (2026-11-19).
- **References** — [#3018](https://github.com/The-Verscienta/kiln_cms/issues/3018)
  (this record); [#2981](https://github.com/The-Verscienta/kiln_cms/issues/2981)
  (the all-hidden rule, found by the search described here), building on
  [#1073](https://github.com/The-Verscienta/kiln_cms/issues/1073) and
  [#2752](https://github.com/The-Verscienta/kiln_cms/issues/2752) (the partial
  rules and the exact reader). Two breakdowns of overlapping traffic read
  together are the subject of
  [#2989](https://github.com/The-Verscienta/kiln_cms/issues/2989), which is
  **still open**: this record does not argue it and does not assume its
  outcome.
- **Changelog** — the 1.11.0 entry
  [A referrer breakdown hidden whole no longer lets a reader who knows the rule recover its counts](../changelog/v1.11.0.md#referrer-breakdown-all-hidden).

## The problem

`KilnCMS.Analytics.suppress_referrer_group/1` decides what one breakdown of
referrer categories may show for one content item over one span: exact
counts, `"< n"` for a naturally low category, `"hidden"` for a complement.
Beside it, the dashboard and the export print the item's exact view total, and
the categories sum to it.

The first rules were reasoned out, and they shipped recoverable: #1073 and
#2752 each found, by brute force, breakdowns where a suppressed count was the
only value consistent with what was published. #2981 found the same for the
all-hidden form, which no reasoning had considered at all: at a threshold of
5, five 1s was the only 5-view breakdown published as five `"hidden"` values,
so the label and the total named every source.

The fix, hiding a few more small breakdowns whole, was not derived from a
principle. It was found by searching, and the search is what made it
trustworthy. That is a property of how this function is built, and a later
change to it or to its inputs needs to know it.

## The decision

**A suppression rule for referrers is found by enumeration, not derived, and
is accepted only against the reader model and criterion below.**

**The reader model.** The reader knows the algorithm, and the exact view
total printed beside the breakdown. For a published display, the reader's
candidates are every breakdown with that total for which
`suppress_referrer_group/1`, re-run on the candidate, publishes the *same*
display. The test file calls this the exact model. It restates none of the
algorithm's rules (the partner's bounds, its tie-break, the all-hidden
condition), because re-running the function carries all of them. An earlier
search let a `"hidden"` cell range over the whole residual, a weaker reader
that agreed with `ambiguous?/3` when both were wrong (#2752).

**The criterion, per breakdown and per category.** Judged for each category
of a breakdown, over that breakdown's candidates:

- in an **all-hidden** publication, every category takes at least two values
  across the candidates;
- in a **partial** publication, no suppressed category is pinned to a nonzero
  value, and the publication has at least two candidates. A `"hidden"` partner
  pinned to `0` is allowed, since it says what a published `0` would.

The unit is one breakdown: one item over one span, which is also the grain of
one export row. The criterion makes no claim about two publications held
together. That is #2989's, and it is open.

**The obligation.** Any change to `referrer_sources/0` (the `one_of`
constraint on `ReferrerDay`'s `source`), to `low_count_threshold/0`'s default,
or to a branch of `suppress_referrer_group/1` re-runs the search for the new
shape of the function, over a range as wide as the one the rule was found
over, and not only over the test suite's range.

## What the search covered

The search that produced the #2981 rule ran thresholds 2 to 20 and view
totals up to 50, over five categories, and again over four and six. It found
no all-hidden publication leaving a category a single value, and no partial
publication leaving a suppressed category a single nonzero value. With three
categories the rule does not hold: `2, 2, 2` at a threshold of 3 is pinned. A
shorter category list is therefore not safe by default, and a longer one is
not known to be.

The wide search was run by hand while the rule was written and **is not in the
repository.** That is the honest state of the re-run obligation today: the
obligation exists, and the part of it that reaches beyond the suite is
reproducible only by re-deriving the search from this description.

What the repository does run, in
`test/kiln_cms/analytics/referrer_suppression_test.exs`:

- the all-hidden sweep (`"no small total leaves a suppressed category
  pinned"`): thresholds 2, 3, 5 and 10, every total from 0 to the threshold
  plus four, every breakdown of that total over the categories
  `referrer_sources/0` returns, grouped by what the algorithm publishes, with
  the criterion above checked on each group. It follows the category list, so a
  change to it re-runs this part automatically;
- the exact-model brute force for partial publications, over small
  breakdowns across several thresholds, and a two-way check that `ambiguous?/3`
  says "ambiguous" exactly when the reader is left with two or more
  candidates.

The bound of threshold plus four caps the test's cost. It is not where the
tightest classes sit: at a threshold of 10 they sit below it. Totals above
the bound, thresholds above 10 and category counts other than the current one
are covered by the hand search only. Nothing in the suite reads a different
number of categories than `referrer_sources/0` gives, so the four-and-six
check, and a re-check of the three-category failure, have no test.

## Rejected

- **Deriving a closed-form rule.** The partial and all-hidden rules are cuts
  through a space of small integer compositions. Each earlier derivation
  shipped a recoverable case, and the cases were found only by running the
  algorithm on every candidate. A proof would restate the algorithm and share
  its blind spots.
- **A weaker reader that restates the rules.** A search that models the
  reader's knowledge separately from the algorithm agrees with the algorithm's
  own mistakes. Re-running the function on each candidate is the reader's
  whole knowledge.
- **Judging the breakdown as a whole rather than per category.** "At least two
  candidates" is not enough for an all-hidden publication: candidates can
  differ in one category and leave another fixed. Each category has to take two
  values.
- **Treating the test suite's range as the guarantee.** It bounds cost, not
  safety. Totals above the bound rest on the wider search.

## Consequences

- A change to the category list, the threshold default or a suppression branch
  is not reviewed on a green suite alone. The reviewer asks for the wide
  search to be re-run, and today that means writing it again.
- The wide search should be made reproducible from the repository, as a tagged
  excluded-by-default test or a mix task, so the obligation can be met by
  running a command. That is not done here.
- #2989 may change what a breakdown is. When it is decided, the per-breakdown
  criterion here is the guarantee it builds on, and the reader model will need
  extending to a reader holding more than one publication. This record then
  gains a successor; it is not edited.
