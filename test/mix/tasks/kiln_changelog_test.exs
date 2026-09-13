defmodule Mix.Tasks.Kiln.ChangelogTest do
  @moduledoc """
  The parts of `mix kiln.changelog` that decide what a reader can still reach.

  `--condense` deletes prose from `CHANGELOG.md`. Everything it deletes has to
  land somewhere linked, and the pieces that decide whether it does are the
  ones covered here: which `## ` headings count as releases (a misread heading
  rewrites front matter as an entry), what a summary keeps of the entry it
  stands for, which entry a decision record claims, and the anchor that ties a
  summary to its long form.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kiln.Changelog

  describe "parse/1" do
    test "an `## ` heading that names no version is front matter, not a release" do
      {preamble, releases, _footer} =
        Changelog.parse("""
        # Changelog

        ## How downstream projects read this file

        Prose about the format.

        ## [0.2.0] - 2026-01-01

        ### Added

        - A thing.
        """)

      assert preamble =~ "How downstream projects read this file"
      assert preamble =~ "Prose about the format."
      assert [%{version: "0.2.0"}] = releases
    end

    test "Unreleased is a release with no version" do
      {_preamble, [unreleased, released], _footer} =
        Changelog.parse("""
        # Changelog

        ## [Unreleased]

        ### Fixed

        - A thing.

        ## [0.2.0]

        ### Added

        - Another.
        """)

      assert unreleased.version == nil
      assert released.version == "0.2.0"
    end

    # The link-reference block carries no `## ` of its own, so it rides along
    # with the oldest release. Rewriting that release would eat it.
    test "splits the trailing link-reference block off the last release" do
      {_preamble, [release], footer} =
        Changelog.parse("""
        # Changelog

        ## [0.1.0]

        First release.

        [Unreleased]: https://example.com/compare/v0.1.0...HEAD
        [0.1.0]: https://example.com/releases/v0.1.0
        """)

      refute release.body =~ "https://example.com"
      assert footer =~ "[0.1.0]: https://example.com/releases/v0.1.0"
    end
  end

  describe "sections/1" do
    test "reads the legacy `Upgrading` spelling as `Upgrade notes`" do
      assert [{"Upgrade notes", _}] = Changelog.sections("### Upgrading\n\nDo a thing.\n")
    end

    test "text before the first h3 is the release preamble" do
      assert [{nil, preamble}, {"Added", _}] =
               Changelog.sections("Baseline release.\n\n### Added\n\n- A thing.\n")

      assert preamble =~ "Baseline release."
    end
  end

  describe "bullets/1" do
    # Entries in this file are not reliably separated by a blank line, and an
    # entry's continuation is indented rather than marked.
    test "keeps an entry's indented continuation, and splits adjacent entries" do
      assert [first, second] =
               Changelog.bullets("""
               - **One.** It wraps
                 onto a second line.

                 And has a second paragraph.
               - **Two.** Immediately after, with no blank line.
               """)

      assert first =~ "second paragraph"
      refute first =~ "Two."
      assert second =~ "Immediately after"
    end
  end

  describe "summarize/1" do
    test "a bold lead that is a whole sentence is the summary" do
      assert Changelog.summarize("- **A thing happened.** Then paragraphs of why.") ==
               "**A thing happened.**"
    end

    test "a bold lead that trails off mid-sentence is completed to the sentence" do
      assert Changelog.summarize("- **A thing**, which happened. Then why.") ==
               "**A thing**, which happened."
    end

    test "an entry with no bold lead falls back to its first sentence" do
      assert Changelog.summarize("- A thing happened. Then why.") == "A thing happened."
    end

    # The reference is re-attached as a link, so leaving the author's bare one
    # in place prints it twice.
    test "drops the author's trailing bare reference" do
      assert Changelog.summarize("- **A thing happened** (#12, #34). Then why.") ==
               "**A thing happened**."
    end

    test "unwraps the entry's own line breaks" do
      assert Changelog.summarize("- **A thing\n  happened.** Then why.") ==
               "**A thing happened.**"
    end
  end

  describe "references/1" do
    test "collects each distinct reference in order" do
      assert Changelog.references("- A thing (#12), see also #34 and #12.") == ["12", "34"]
    end

    # A summary already carrying `[long form](…v0.6.0.md#404-capture-…)` would
    # otherwise gain a reference to issue #404 on every re-run.
    test "does not read digits out of a link target" do
      entry = """
      - **404 capture no longer evicts real misses.**
        ([#920](https://example.com/issues/920) · [long form](docs/changelog/v0.6.0.md#404-capture))
      """

      assert Changelog.references(entry) == ["920"]
    end
  end

  describe "from_history/2" do
    # `git log --reverse --format=@@@%s -p -U0 -- CHANGELOG.md`, oldest first.
    defp git_log(commits) do
      Enum.map_join(commits, "\n", fn {subject, added} ->
        "@@@#{subject}\n\n--- a/CHANGELOG.md\n+++ b/CHANGELOG.md\n@@ -1 +1 @@\n" <>
          Enum.map_join(added, "\n", &("+" <> &1))
      end)
    end

    @entry """
    - **The main gate runs five parallel jobs instead of one serial job.** The
      compile, every lint and the suite under coverage used to run in sequence.
    """

    test "credits the pull request that first wrote the entry" do
      index =
        git_log([
          {"Split the CI gate (#1397)",
           [
             "- **The main gate runs five parallel jobs instead of one serial job.** The",
             "  compile, every lint and the suite under coverage used to run in sequence."
           ]}
        ])
        |> Changelog.build_index()

      assert Changelog.from_history(@entry, index) == ["1397"]
    end

    # A run of `--condense` rewraps lines and commits them under its own pull
    # request. The entry's opening words are already in an earlier commit.
    test "a later rewrap does not take the credit" do
      index =
        git_log([
          {"Split the CI gate (#1397)",
           [
             "- **The main gate runs five parallel jobs instead of one serial job.** The",
             "  compile, every lint and the suite under coverage used to run in sequence."
           ]},
          {"Condense the changelog (#1469)",
           [
             "- **The main gate runs five parallel jobs instead of one serial",
             "  job.** The compile, every lint and the suite under coverage used to run in",
             "  sequence."
           ]}
        ])
        |> Changelog.build_index()

      rewrapped = """
      - **The main gate runs five parallel jobs instead of one serial
        job.** The compile, every lint and the suite under coverage used to run in
        sequence.
      """

      assert Changelog.from_history(rewrapped, index) == ["1397"]
    end

    # A release cut that edits an entry's opening adds the new opening under the
    # release's pull request. A line it did not touch is still the original's.
    test "a later edit to the opening does not take the credit" do
      index =
        git_log([
          {"Split the CI gate (#1397)",
           [
             "- **CI runs five jobs.** The",
             "  compile, every lint and the suite under coverage used to run in sequence."
           ]},
          {"chore: release v0.8.0 (#1444)",
           ["- **The main gate runs five parallel jobs instead of one serial job.** The"]}
        ])
        |> Changelog.build_index()

      assert Changelog.from_history(@entry, index) == ["1397"]
    end

    test "an entry first written by a commit naming no pull request has none" do
      index =
        git_log([
          {"Split the CI gate", [String.trim_trailing(@entry)]},
          {"Condense the changelog (#1469)", ["- **The main gate runs five parallel jobs"]}
        ])
        |> Changelog.build_index()

      assert Changelog.from_history(@entry, index) == []
    end
  end

  describe "slug/1" do
    test "matches GitHub's heading anchor" do
      assert Changelog.slug("**`/api/json/type-definitions`** — headless discovery") ==
               "apijsontype-definitions-headless-discovery"
    end

    # A half-word anchor reads as a typo in a link the reader is being asked to
    # follow for the part that was cut.
    test "cuts a long slug at a word boundary" do
      slug = Changelog.slug(String.duplicate("alpha bravo ", 20))

      assert String.length(slug) <= 80
      refute String.ends_with?(slug, "-")
      assert String.ends_with?(slug, "bravo") or String.ends_with?(slug, "alpha")
    end
  end

  describe "flatten/1" do
    test "an entry becomes one line" do
      assert Changelog.flatten("- **A thing.**\n  It wraps\n  three times.") ==
               "**A thing.** It wraps three times."
    end
  end

  describe "notes/1" do
    # An upgrade-notes section is prose, not bullets: a new note starts at a
    # paragraph with a bold lead, and unbolded paragraphs belong to the note
    # above them.
    test "splits on bold-lead paragraphs and keeps their continuations" do
      assert [first, second] =
               Changelog.notes("""
               **Take a backup.** Six migrations run on boot.

               They are all additive.

               **Run the backfill.** Once, after deploying.
               """)

      assert first =~ "all additive"
      refute first =~ "Run the backfill"
      assert second =~ "Once, after deploying."
    end

    test "a section with no bold lead at all is one note" do
      assert [only] = Changelog.notes("Do this.\n\nThen that.\n")
      assert only =~ "Do this."
      assert only =~ "Then that."
    end

    # A note may carry its own list ("two smaller contract notes on the same
    # endpoint:"), and those items belong to the note above them — not to a
    # note of their own.
    test "a plain bullet belongs to the note above it" do
      assert [only] =
               Changelog.notes("""
               **Check the endpoint.** Two smaller contract notes:

               - Errors carry a stable `code`.
               - Send `code` as a string.
               """)

      assert only =~ "Errors carry a stable"
      assert only =~ "Send `code` as a string."
    end

    # A second `--condense` re-reads a section it already condensed. Reading it
    # as one note would keep the first note's archive block and drop the rest.
    test "a bullet this task already condensed opens a note of its own" do
      assert [first, second] =
               Changelog.notes("""
               - **Take a backup.**
                 ([long form](docs/changelog/v0.8.0.md#take-a-backup))

               - **Run the backfill.**
                 ([long form](docs/changelog/v0.8.0.md#run-the-backfill))
               """)

      assert first =~ "Take a backup"
      refute first =~ "Run the backfill"
      assert second =~ "Run the backfill"
    end
  end
end
