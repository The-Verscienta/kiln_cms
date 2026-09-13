defmodule Mix.Tasks.Kiln.Changelog do
  @moduledoc """
  Keeps `CHANGELOG.md` skimmable, and moves the long form out to where it stays
  readable.

  `CHANGELOG.md` accretes one entry per pull request, and an entry written at
  merge time is written by the person who just did the work: it explains the
  problem, the alternatives and the mechanism. That is worth keeping — but it
  is not what the file is *for*. `mix kiln.update` shows this file to an
  operator who is about to move a production pin, and the question they have is
  "what breaks if I upgrade?" (#1325).

  So the file is split by audience:

    * `CHANGELOG.md` — one line per change, under
      **Upgrade notes / Breaking / Added / Changed / Fixed / Security /
      Removed**. Skimmable in a minute.
    * `docs/changelog/vX.Y.Z.md` — the long-form entries for that release,
      verbatim, one anchor per entry. Linked from every summary line that was
      shortened.
    * `docs/decisions/` — the handful of entries that are really architecture
      decision records rather than release notes.

  Nothing is deleted: `--verify` proves it, paragraph by paragraph, against any
  earlier revision of the file.

  ## Modes

      mix kiln.changelog                    # --check
      mix kiln.changelog --check            # lint the file; fails on a violation
      mix kiln.changelog --condense         # rewrite CHANGELOG.md + docs/changelog/ + docs/decisions/
      mix kiln.changelog --verify REF       # prove no paragraph of REF:CHANGELOG.md was lost

  ### `--check`

  The gate `mix precommit` and CI run. It fails when:

    * an **Unreleased** entry runs longer than three lines — the cap the file
      exists to hold. Run `--condense`, or write the summary yourself and put
      the reasoning in the pull request;
    * an entry carries no link at all (no issue/PR reference and no long-form
      link), so a reader has nowhere to go for the detail;
    * a release uses a section name outside the seven above;
    * a long-form link points at a file or anchor that does not exist.

  ### `--condense`

  Reads `CHANGELOG.md` and, for each entry still carrying its long form, writes
  that long form to `docs/changelog/` and a one-line summary back to
  `CHANGELOG.md`. The summary is the entry's own opening — its bold lead, or
  its first sentence — never a rewrite.

  An entry it already condensed is left alone, and its archive block is adopted
  rather than regenerated, so the whole run is a no-op the second time. That is
  what makes it a release step rather than a one-off migration: cutting a
  release moves the `## [Unreleased]` section to `## [X.Y.Z]`, and `--condense`
  renames `docs/changelog/unreleased.md` to match and re-points the links (see
  `docs/releasing.md`).

  Entries whose text carries no `#1234` reference get one from git: the pull
  request of the earliest commit that added one of the entry's lines verbatim or
  whose added text contains its opening words — so neither a later rewrap nor a
  later edit to the opening takes the credit. An entry git names no pull request
  for links its long form instead, so every summary has somewhere to go.
  Upgrade notes and breaking notes take only the references they carry, since
  the commit that adds them is the release cut.

  Anchors are unique within a release: two entries opening the same way get
  `typo-fixes` and `typo-fixes-1`, and a new entry never takes an anchor an
  existing archive block still uses.

  ### `--verify REF`

  Takes every paragraph of the **release entries** in `CHANGELOG.md` as of
  `REF`, and of the long forms already in `docs/changelog/` and
  `docs/decisions/` at `REF`, and asserts it still exists — in `CHANGELOG.md`, in `docs/changelog/`,
  or in `docs/decisions/`. Comparison is on collapsed whitespace with link
  targets removed, so re-wrapping and re-rooting a link are fine and a dropped
  sentence is not. This file's own front matter is excluded: it documents the
  format, and changing the format is what `--condense` does.

      mix kiln.changelog --verify v0.8.0
      mix kiln.changelog --verify HEAD
  """
  @shortdoc "Lint, condense, or verify CHANGELOG.md"

  use Mix.Task

  # An update must be describable even when the pinned core doesn't compile.
  @requirements []

  @changelog "CHANGELOG.md"
  @archive_dir "docs/changelog"
  @decisions_dir "docs/decisions"
  @repo_url "https://github.com/The-Verscienta/kiln_cms"

  @unreleased_max_lines 3

  # The order sections are emitted in. "Upgrade notes" and "Breaking" lead
  # because they are the two an operator moving a pin has to read; the rest
  # follow Keep a Changelog. `Upgrading` is the old spelling, still present in
  # released tags, and is normalized on the way in.
  @section_order [
    "Upgrade notes",
    "Breaking",
    "Added",
    "Changed",
    "Fixed",
    "Security",
    "Removed",
    "Deprecated"
  ]

  @legacy_sections %{"Upgrading" => "Upgrade notes"}

  # Sections written as prose an operator acts on, rather than as one bullet
  # per change.
  @note_sections ["Upgrade notes", "Breaking"]

  # What this task — and only this task — writes onto a summary it shortened.
  # An issue link is not enough: `--check` itself tells contributors to write
  # `- **Summary.** ([#1234](...))`, and that entry has no archive block. `\s+`,
  # not a space: every links line is wider than the file's 80 columns, so an
  # editor fill splits the label across lines.
  @long_form_link ~r{\[long\s+form\]\(\s*docs/(?:changelog|decisions)/}

  # The line of links `--condense` puts under a summary. It is not prose, so it
  # does not count toward the Unreleased cap.
  @links_line ~r/^\s*\(\[(?:#\d+|long form)\]\(/

  # Upgrade-note paragraphs that are a *break* rather than a step: an observable
  # contract changed, or an overlay/deployment has to change to keep working.
  # Matched as a substring of the note's bold lead. Curated deliberately — the
  # difference is editorial judgement, not something to infer from wording.
  @breaking [
    {"0.5.0", "`POST /api/auth/sign_in` can now answer `200` instead of `201`"},
    {"0.5.0", "Everyone is signed out once on deploy"},
    {"0.5.0", "Set `EMBED_ORIGINS` before deploying"},
    {"0.5.0", "Overlays that call `KilnCMSWeb.Tenant.current_org_id/1`"},
    {"0.5.0", "Check `DATABASE_SSL` before deploying"},
    {"0.5.0", "Check `PHX_SERVER` too"},
    {"0.8.0", "Editors cannot publish until you say so"}
  ]

  # Entries whose long form is an architecture decision record, not a release
  # note: they argue a choice that outlives the release that shipped it.
  # `{version, section, lead substring, adr number, adr title}`.
  @decisions [
    {"0.8.0", "Security", "Every policy bypass on a request path now says why it is safe", 1,
     "Policy bypasses on request paths must name their reason, and a gate enforces it"},
    {"0.8.0", "Security", "Frames on an established `/ws/collab` connection are budgeted", 2,
     "Socket budgets are keyed on the actor, not the address or the connection"},
    {"0.5.0", "Security", "History anchors verify as a chain, not just at the head", 3,
     "History anchors verify as a chain, and an unjudgeable anchor floors the chain"},
    {"0.5.0", "Security", "A LiveView join with no URL is refused", 4,
     "A LiveView join that matches no route is refused rather than mounted ungated"},
    {"0.5.0", "Security", "The session cookie is `__Host-`-prefixed in production", 5,
     "The production session cookie is `__Host-`-prefixed, with no dual-read window"},
    {"0.5.0", "Security", "A form's embed allowlist is now the form's", 6,
     "A form's embed allowlist belongs to the form, not to the deployment"},
    {"0.6.0", "Security", "The three prompt builders' data fence now carries a per-call nonce", 7,
     "The prompt data fence uses a per-call nonce, not a static delimiter"},
    {"0.5.0", "Security", "Webhook delivery now goes through `KilnCMS.SafeFetch`", 8,
     "Outbound fetches go through `KilnCMS.SafeFetch`, which pins the resolved address"},
    {"0.5.0", "Added", "Events: \"what's on, soonest first\"", 9,
     "Events are a shape content can take, not a resource of their own"},
    {"0.5.0", "Fixed", "Rich embed cards: server-side oEmbed metadata", 10,
     "Embed metadata is resolved server-side against a curated provider list"}
  ]

  @switches [check: :boolean, condense: :boolean, verify: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    cond do
      opts[:condense] -> condense()
      ref = opts[:verify] -> verify(ref)
      true -> check()
    end
  end

  # ---- parsing -----------------------------------------------------------

  @doc false
  # Splits the file into `{preamble, [release], footer}`. A release is
  # `%{heading, version, body}`, where `heading` is the `## ...` line without
  # its marker. The footer is the trailing link-reference block, which carries
  # no `## ` of its own and so rides along with the last release — it is split
  # back off here so a rewrite can put it back untouched.
  #
  # Public only so it can be tested against fixtures rather than the real file.
  def parse(text) do
    [head | rest] = String.split(text, ~r/^## /m)

    {preamble, releases} =
      Enum.reduce(rest, {head, []}, fn chunk, {preamble, releases} ->
        {heading, body} = split_heading(chunk)

        cond do
          release_heading?(heading) ->
            {preamble,
             [%{heading: heading, version: heading_version(heading), body: body} | releases]}

          # An `## ` heading that isn't a release — "How downstream projects
          # read this file" — is front matter, not an entry. Put it back
          # untouched rather than rewriting it as a release with no entries.
          releases == [] ->
            {preamble <> "## " <> chunk, releases}

          true ->
            [last | rest] = releases
            {preamble, [%{last | body: last.body <> "## " <> chunk} | rest]}
        end
      end)

    {releases, footer} = split_footer(Enum.reverse(releases))
    {preamble, releases, footer}
  end

  defp split_heading(chunk) do
    case String.split(chunk, "\n", parts: 2) do
      [heading] -> {heading, ""}
      [heading, body] -> {heading, body}
    end
  end

  defp release_heading?(heading) do
    String.match?(heading, ~r/^\[?(Unreleased|v?\d+\.\d+\.\d+)/i)
  end

  defp split_footer([]), do: {[], ""}

  defp split_footer(releases) do
    {init, [last]} = Enum.split(releases, -1)

    case String.split(last.body, ~r/^(?=\[Unreleased\]: )/m, parts: 2) do
      [body, footer] -> {init ++ [%{last | body: body}], footer}
      [_] -> {releases, ""}
    end
  end

  defp heading_version(heading) do
    case Regex.run(~r/\[?v?(\d+\.\d+\.\d+)\]?/, heading) do
      [_, version] -> version
      _ -> nil
    end
  end

  @doc false
  # `[{name, body}]` for a release body, in the order they appear. Text before
  # the first `### ` (a release preamble, as 0.1.0 has) comes back as
  # `{nil, text}`.
  def sections(body) do
    [lead | rest] = String.split(body, ~r/^### /m)

    lead_section = if String.trim(lead) == "", do: [], else: [{nil, lead}]

    lead_section ++
      Enum.map(rest, fn chunk ->
        [name, rest] =
          case String.split(chunk, "\n", parts: 2) do
            [name] -> [name, ""]
            pair -> pair
          end

        name = String.trim(name)
        {Map.get(@legacy_sections, name, name), rest}
      end)
  end

  @doc false
  # Top-level `- ` bullets, each with its indented continuation lines.
  def bullets(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({[], nil}, fn line, {done, current} ->
      cond do
        String.starts_with?(line, "- ") ->
          {push(done, current), [line]}

        current != nil and (line == "" or String.starts_with?(line, "  ")) ->
          {done, [line | current]}

        true ->
          {push(done, current), nil}
      end
    end)
    |> then(fn {done, current} -> Enum.reverse(push(done, current)) end)
    |> Enum.map(&(&1 |> Enum.reverse() |> Enum.join("\n") |> String.trim_trailing()))
  end

  defp push(done, nil), do: done
  defp push(done, current), do: [current | done]

  @doc false
  # `Upgrade notes` and `Breaking` bodies as notes: paragraphs, where a new note
  # starts at a bold lead or a top-level bullet. Returns those notes, each still
  # verbatim — indentation included, since it is what nests a list or a code
  # block under the note above it.
  def notes(body) do
    body
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(&(&1 |> String.replace(~r/\A\n+/, "") |> String.trim_trailing()))
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce([], &add_paragraph/2)
    |> Enum.reverse()
    |> Enum.map(&(&1 |> Enum.reverse() |> Enum.join("\n\n")))
  end

  # A bold lead opens a note.
  #
  # A bullet paragraph is a list of notes — one per top-level bullet — unless it
  # follows a note whose last paragraph introduces it with a colon ("two smaller
  # contract notes on the same endpoint:"), where it is that note's own list. A
  # summary this task already condensed is always its own note.
  #
  # Prose continues a prose note. After a bullet note, an indented paragraph or a
  # code fence continues that bullet — apart from any top-level bullet lines
  # inside it, which are the next notes — while prose at column zero is a new
  # note: a blank line and an unindented paragraph end a markdown list.
  defp add_paragraph("**" <> _ = para, notes), do: [[para] | notes]

  defp add_paragraph("- " <> _ = para, notes) do
    if notes == [] or bullet_note?(hd(notes)) or condensed?(para) or
         not introduces_list?(hd(notes)) do
      push_notes(split_bullets(para), notes)
    else
      [[para | hd(notes)] | tl(notes)]
    end
  end

  defp add_paragraph(para, []), do: [[para]]

  defp add_paragraph(para, [note | rest] = notes) do
    cond do
      not bullet_note?(note) ->
        [[para | note] | rest]

      String.match?(para, ~r/\A\s/) or String.starts_with?(para, "```") ->
        [continuation | bullets] = split_bullets(para)
        push_notes(bullets, [[continuation | note] | rest])

      true ->
        [[para] | notes]
    end
  end

  defp push_notes(units, notes), do: Enum.reduce(units, notes, &[[&1] | &2])

  # Top-level bullets with every line kept. Unlike `bullets/1`, a line that is
  # neither `- ` nor indented stays with the bullet above it instead of being
  # dropped: these sections are written by hand, and a lost line is a step an
  # operator was meant to take.
  defp split_bullets(para), do: String.split(para, ~r/\n(?=- )/)

  defp bullet_note?(paragraphs), do: String.starts_with?(List.last(paragraphs), "- ")

  defp introduces_list?([last | _]),
    do: last |> String.trim_trailing() |> String.ends_with?(":")

  # ---- summarising -------------------------------------------------------

  @doc false
  # An entry's one-line summary: its bold lead if it has one, else its first
  # sentence. Kept as written — this is a shortening, not a rewrite, so the
  # summary is always the author's own words.
  def summarize(entry) do
    flat = flatten(entry)

    case Regex.run(~r/^\*\*(?:.+?)\*\*/s, flat) do
      # A bold lead that is a whole sentence is the summary the author already
      # wrote. One that trails off mid-sentence is not, so take the sentence.
      [bold] -> if String.match?(bold, ~r/[.!?:]\*\*$/), do: bold, else: first_sentence(flat)
      nil -> first_sentence(flat)
    end
    |> String.trim()
    # The reference is re-attached as a link below; leaving the author's bare
    # `(#1234)` in place would print it twice.
    |> String.replace(~r/\s*\((?:#\d+[,;]?\s*)+\)\s*\.?$/, "")
    |> String.trim()
    |> ensure_period()
  end

  # Terminate the summary, unless the author already did — including inside the
  # bold lead, where `**A thing happened.**` is finished and
  # `**A thing happened**` (whose full stop lived in the reference that was just
  # stripped) is not.
  defp ensure_period(text) do
    if String.match?(text, ~r/[.!?:)\]][*_`]*$/), do: text, else: text <> "."
  end

  defp first_sentence(text) do
    case Regex.run(~r/^(.*?[.!?])(?:\s|$)/s, text) do
      [_, sentence] -> sentence
      nil -> text
    end
  end

  @doc false
  # An entry as one flowing line: bullet marker gone, wrapping undone.
  def flatten(entry) do
    entry
    |> String.trim()
    |> String.replace(~r/^- /, "")
    |> String.split("\n")
    |> Enum.map_join(" ", &String.trim/1)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc false
  # Link targets and code spans are stripped first: a summary already carrying
  # `[long form](docs/changelog/v0.6.0.md#404-capture-...)` would otherwise be
  # read as referencing issue #404, and a long form quoting `#5-what-shipped` or
  # `#000` as issue #5 or #0.
  def references(entry) do
    entry
    |> String.replace(~r/\]\([^)]*\)/, "]")
    |> String.replace(~r/`[^`]*`/, "")
    |> then(&Regex.scan(~r/(?<![\w&])#(\d+)\b/, &1))
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
  end

  @doc false
  # GitHub's heading-anchor slug, for the anchors `--condense` writes into the
  # archive and the links it writes into CHANGELOG.md.
  def slug(text) do
    text
    |> String.replace(~r/[`*_\[\]()]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s-]/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/u, "-")
    |> truncate_at_word(80)
    |> String.trim("-")
  end

  # A slug is only an anchor, but a half-word one reads as a typo in a link the
  # reader is being asked to trust, so cut at the last hyphen inside the limit.
  defp truncate_at_word(text, limit) when byte_size(text) <= limit, do: text

  defp truncate_at_word(text, limit) do
    cut = String.slice(text, 0, limit)

    case String.split(cut, "-") do
      [single] -> single
      parts -> parts |> Enum.drop(-1) |> Enum.join("-")
    end
  end

  # ---- condense ----------------------------------------------------------

  defp condense do
    text = File.read!(@changelog)
    {preamble, releases, footer} = parse(text)
    prs = pull_request_index()

    File.mkdir_p!(@archive_dir)
    File.mkdir_p!(@decisions_dir)

    {rendered, archives, adrs} =
      Enum.reduce(releases, {[], [], []}, fn release, {rs, as, ds} ->
        {rendered, archive, release_adrs} = condense_release(release, prs)
        {[rendered | rs], [archive | as], release_adrs ++ ds}
      end)

    Enum.each(archives, fn {path, body} -> File.write!(path, body) end)
    Enum.each(adrs, fn {path, body} -> File.write!(path, body) end)

    body =
      rendered
      |> Enum.reverse()
      |> Enum.map_join("", &("## " <> String.trim_trailing(&1) <> "\n\n"))

    File.write!(@changelog, preamble <> body <> footer)

    Mix.shell().info([
      :green,
      "Condensed ",
      :reset,
      "#{length(releases)} release(s): ",
      "#{length(archives)} archive file(s), #{length(adrs)} decision record(s)."
    ])
  end

  # Unreleased is condensed exactly like a release, into
  # `docs/changelog/unreleased.md`. Writing the summary by hand and leaving the
  # reasoning only in the pull request would work, but it makes the three-line
  # cap a thing a contributor has to obey rather than a thing this task does
  # for them — and it puts the one entry an operator reads *before* the release
  # exists behind a round trip to GitHub. Cutting a release renames the file
  # (see `docs/releasing.md`).
  defp condense_release(release, prs) do
    archive_path = Path.join(@archive_dir, archive_name(release))
    release = adopt_renamed_archive(release, archive_path)
    kept = archived_blocks(archive_path)

    sections =
      release.body
      |> sections()
      |> merge_duplicate_sections()
      |> split_breaking(release.version)
      |> Enum.sort_by(fn {name, _} -> section_rank(name) end)

    ctx = {prs, kept, assign_anchors(sections, kept)}

    {summaries, archived, adrs} =
      sections
      |> Enum.reduce({[], [], []}, fn {name, section}, {ss, as, ds} ->
        {summary, archive, section_adrs} =
          condense_section(release, name, section, ctx, archive_path)

        {[{name, summary} | ss], [{name, archive} | as], section_adrs ++ ds}
      end)

    summaries = Enum.reverse(summaries)
    archived = Enum.reverse(archived)

    rendered =
      release.heading <>
        "\n\n" <>
        archive_pointer(release, archive_path) <> "\n" <> render_sections(summaries)

    {String.replace(rendered, ~r/\n{3,}/, "\n\n"),
     {archive_path, render_archive(release, archived)}, adrs}
  end

  defp archive_name(%{version: nil}), do: "unreleased.md"
  defp archive_name(%{version: version}), do: "v#{version}.md"

  defp label(%{version: nil}), do: "Unreleased"
  defp label(%{version: version}), do: version

  defp archive_pointer(release, path) do
    """
    Long form: [#{path}](#{path}) —
    the #{label(release)} entries as they were written when each change merged.
    Every summary line below that was shortened links to its own entry there.
    """
  end

  # A release preamble. Any pointer a previous run wrote is dropped — the caller
  # writes a fresh one, and two of them is what made `--condense` not a no-op.
  defp condense_section(_release, nil, section, _ctx, _archive) do
    text =
      section
      |> String.split(~r/\n\s*\n/)
      |> Enum.reject(&String.starts_with?(String.trim(&1), "Long form: [#{@archive_dir}/"))
      |> Enum.join("\n\n")
      |> String.trim()

    {text, text, []}
  end

  # `Upgrade notes` and `Breaking` are prose an operator acts on — paragraphs
  # with a bold lead, not bullets — and they are written in the release-cut
  # commit rather than in the pull request that caused them, so unlike an entry
  # they take only the references their own text carries. The git fallback here
  # would name the release commit, which tells nobody anything.
  defp condense_section(_release, name, section, {_prs, kept, anchors}, archive_path)
       when name in @note_sections do
    {summaries, archived} =
      section
      |> notes()
      |> Enum.with_index()
      |> Enum.map(fn {note, i} ->
        note_result(note, name, {kept, Map.get(anchors, {name, i})}, archive_path)
      end)
      |> Enum.unzip()

    {Enum.join(summaries, "\n\n"), Enum.join(archived, "\n\n"), []}
  end

  defp condense_section(release, name, section, {prs, kept, anchors}, archive_path) do
    {summaries, archived, adrs} =
      section
      |> bullets()
      |> Enum.with_index()
      |> Enum.map(fn {entry, i} ->
        entry_result(entry, release, name, {prs, kept, Map.get(anchors, {name, i})}, archive_path)
      end)
      |> Enum.reduce({[], [], []}, fn {s, a, d}, {ss, as, ds} ->
        {[s | ss], [a | as], (d && [d | ds]) || ds}
      end)

    {Enum.reverse(summaries) |> Enum.join("\n\n"), Enum.reverse(archived) |> Enum.join("\n\n"),
     adrs}
  end

  defp note_result(note, name, {kept, anchor}, archive_path) do
    if condensed?(note) do
      {note |> String.trim() |> repoint_long_form(archive_path), keep_block(kept, note, name)}
    else
      condense_note(note, anchor, kept, archive_path)
    end
  end

  defp condense_note(note, anchor, kept, archive_path) do
    refs = references(note)
    detail = if long_form?(note, refs, Map.get(kept, anchor)), do: "#{archive_path}##{anchor}"
    {entry_line(summarize(note), refs, detail), archived_block(kept, anchor, note)}
  end

  # Already condensed: keep the summary as written — pointed at this release's
  # archive, and credited to a pull request if it had none — and re-adopt the
  # archive block it names. Not yet: condense it.
  defp entry_result(entry, release, name, {prs, kept, anchor}, archive_path) do
    if condensed?(entry) do
      block = keep_block(kept, entry, name)
      summary = entry |> String.trim() |> repoint_long_form(archive_path) |> attribute(block, prs)
      {summary, block, nil}
    else
      condense_entry(release, name, entry, {prs, anchor, kept}, archive_path)
    end
  end

  defp condense_entry(release, name, entry, {prs, anchor, kept}, archive_path) do
    lead = summarize(entry)
    refs = entry_references(entry, prs)

    case decision_for(release.version, name, entry) do
      nil ->
        detail =
          if long_form?(entry, refs, Map.get(kept, anchor)), do: "#{archive_path}##{anchor}"

        {entry_line(lead, refs, detail), archived_block(kept, anchor, entry), nil}

      {number, title} ->
        path = decision_path(number, title)

        {entry_line(lead, refs, path),
         anchor_tag(anchor) <>
           "\n\n" <>
           wrap_bullet(
             "#{lead} The reasoning behind it is recorded as a decision in " <>
               "[#{path}](#{relative_to_archive(path)})."
           ), {path, render_decision(number, title, release, name, entry, refs)}}
    end
  end

  # A condensed entry with no pull request — condensed before its PR had a
  # number — is looked up again on every run, so the merge that later shipped it
  # is credited rather than never linked. Its long form is tried first, since
  # that is what its author committed; the summary only when no commit wrote the
  # long form (an entry condensed before its first commit). A decision record's
  # stub is generated text, so it has no summary fallback.
  defp attribute(summary, block, prs) do
    with [] <- references(summary),
         {pr, _text, _added} when is_binary(pr) <-
           history_commit(block_text(block), prs) ||
             (entry_anchor(summary) && history_commit(summary, prs)) do
      Regex.replace(
        ~r/\(\[long(\s+)form\]\(/,
        summary,
        "([##{pr}](#{@repo_url}/issues/#{pr}) · [long\\1form](",
        global: false
      )
    else
      _ -> summary
    end
  end

  # An entry is archived as its author wrote it. One that was not shortened has
  # no long-form marker, so every run re-derives it — from CHANGELOG.md's
  # rendering after the first. Keep the block already in the archive whenever
  # it holds this entry: rebuilding it from the rendering would change the
  # archive's bytes on every run and swap the author's `(#1313)` for a link,
  # which is exactly the wording `--verify` looks for.
  defp archived_block(kept, anchor, entry) do
    block = Map.get(kept, anchor)

    if block && matches_kept?(block, entry),
      do: block,
      else: anchor_tag(anchor) <> "\n\n" <> String.trim(entry)
  end

  # A kept block holds an entry when it says the same thing — compared with the
  # entry's links rerooted the way the archive writes them, and with its
  # references too when the block has any, so correcting one rebuilds the block —
  # or when the entry is a shortening of it: a condensed summary whose long-form
  # link was relabeled or deleted by hand, which must never replace its long form.
  defp matches_kept?(block, entry), do: same_kept?(block, entry) or extends_kept?(block, entry)

  defp same_kept?(block, entry) do
    text = block_text(block)
    rerooted = reroot_links(entry)

    bare(flatten(text)) == bare(flatten(rerooted)) and
      references(text) in [[], references(rerooted)]
  end

  defp extends_kept?(nil, _entry), do: false

  defp extends_kept?(block, entry) do
    body = bare(flatten(block_text(block)))
    prose = bare(flatten(reroot_links(entry)))
    String.length(body) > String.length(prose) and String.starts_with?(body, prose)
  end

  defp block_text(block), do: block |> String.split("\n", parts: 2) |> List.last()

  # Whether the summary actually leaves anything out. One that doesn't gets no
  # "long form" link — the link would point at a copy of itself — and, since it
  # then carries no marker, is simply re-derived to the same text next run.
  defp shortened?(entry), do: bare(flatten(entry)) != bare(summarize(entry))

  # Whether a summary links its long form: when something was left out of it;
  # when it has no pull request to link instead — `--check` fails a summary with
  # nowhere to go, and git names no pull request for an entry committed without
  # one; or when the archive already holds a longer version of it, which a
  # summary that lost its link must point back at. That link also marks the
  # entry as condensed.
  defp long_form?(entry, refs, block) do
    shortened?(entry) or refs == [] or extends_kept?(block, entry)
  end

  # Prose only: the links line this task writes and an author's bare `(#1234)`
  # removed. Any other parenthetical of links — an advisory, a guide — is the
  # author's and stays prose.
  defp bare(text) do
    text
    |> String.replace(~r/\s*\(\s*(?:\[(?:#\d+|long\s+form)\]\([^)]*\)\s*[,·]?\s*)+\)/u, "")
    |> String.replace(~r/\s*\((?:#\d+[,;]?\s*)+\)/, "")
    |> String.trim()
    |> String.trim_trailing(".")
  end

  # One anchor per archive block, unique within the release and stable across
  # runs. A condensed entry keeps the anchor its link names. An entry re-derived
  # every run — not shortened, so it carries no marker — keeps the anchor of the
  # archive block that holds it, claimed before any new entry is given one, so a
  # later entry with the same opening can never take it. Only what is left gets
  # a new slug, suffixed `-1`, `-2` past every anchor in use. Keyed by
  # `{section, position}` rather than by text: two identical entries are still
  # two blocks.
  defp assign_anchors(sections, kept) do
    {condensed, fresh} =
      sections
      |> Enum.flat_map(fn {name, body} -> keyed_units(name, body) end)
      |> Enum.split_with(fn {_key, unit} -> condensed?(unit) end)

    taken =
      condensed
      |> Enum.map(fn {_key, unit} -> kept_anchor(kept, unit) end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    {anchors, taken, unmatched} = Enum.reduce(fresh, {%{}, taken, []}, &claim_kept(&1, &2, kept))

    unmatched
    |> Enum.reverse()
    |> Enum.reduce({anchors, taken}, fn {key, unit}, {anchors, taken} ->
      anchor = unique_anchor(slug(summarize(unit)), taken)
      {Map.put(anchors, key, anchor), MapSet.put(taken, anchor)}
    end)
    |> elem(0)
  end

  defp keyed_units(name, body) do
    name |> units(body) |> Enum.with_index() |> Enum.map(fn {unit, i} -> {{name, i}, unit} end)
  end

  defp claim_kept({key, unit}, {anchors, taken, unmatched}, kept) do
    case kept_match(kept, taken, unit) do
      nil -> {anchors, taken, [{key, unit} | unmatched]}
      anchor -> {Map.put(anchors, key, anchor), MapSet.put(taken, anchor), unmatched}
    end
  end

  defp kept_match(kept, taken, unit) do
    base = slug(summarize(unit))
    suffixed = ~r/\A#{Regex.escape(base)}-\d+\z/

    kept
    |> Map.keys()
    |> Enum.filter(&(&1 == base or String.match?(&1, suffixed)))
    |> Enum.sort_by(&{String.length(&1), &1})
    |> Enum.find(&(not MapSet.member?(taken, &1) and matches_kept?(Map.fetch!(kept, &1), unit)))
  end

  defp unique_anchor(base, taken) do
    0
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(fn
      0 -> base
      n -> "#{base}-#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp units(nil, _body), do: []
  defp units(name, body) when name in @note_sections, do: notes(body)
  defp units(_name, body), do: bullets(body)

  # An entry a previous run already condensed. Its long form is in the archive,
  # not in `CHANGELOG.md`, so re-condensing it would summarise a summary and —
  # worse, since the archive is rewritten from what this function is handed —
  # overwrite the long form with it.
  defp condensed?(entry), do: String.match?(entry, @long_form_link)

  # The archive block a condensed entry stands for, keyed by the anchor in its
  # own "long form" link.
  defp keep_block(kept, entry, section) do
    block =
      case entry_anchor(entry) do
        nil -> with {_anchor, block} <- decision_stub(kept, entry), do: block
        anchor -> Map.get(kept, anchor)
      end

    block || Mix.raise(orphaned_message(entry, section))
  end

  # The archive anchor a condensed entry will keep, so a new entry avoids it.
  defp kept_anchor(kept, entry) do
    entry_anchor(entry) || with({anchor, _block} <- decision_stub(kept, entry), do: anchor)
  end

  # A summary pointing at a decision record has no archive anchor of its own in
  # its link; its archive block is the stub that links the same record — by that
  # exact link, since other long forms may well mention the record's path.
  defp decision_stub(kept, entry) do
    case Regex.run(~r{\[long\s+form\]\(\s*(#{@decisions_dir}/[^)\s]+)\)}, entry) do
      [_, path] ->
        link = "[#{path}](#{relative_to_archive(path)})"
        Enum.find(kept, fn {_anchor, block} -> String.contains?(block, link) end)

      nil ->
        nil
    end
  end

  defp orphaned_message(entry, section) do
    """
    This entry under "#{section}" is already condensed, but its long form is
    not in #{@archive_dir}:

        #{String.slice(flatten(entry), 0, 70)}...

    Rewriting the archive from the summary would replace the long form with it,
    so this stops instead. Either restore the archive file (it is in git), or
    paste the full entry back into CHANGELOG.md and re-run.
    """
  end

  # The archive anchor a condensed entry's own "long form" link names — not the
  # first archive link anywhere in it, since a summary may link another entry's
  # long form in its prose — or nil for one that links a decision record.
  defp entry_anchor(entry) do
    case Regex.run(~r/\[long\s+form\]\(\s*#{@archive_dir}\/[^)#\s]+#([^)\s]+)\)/, entry) do
      [_, anchor] -> anchor
      nil -> nil
    end
  end

  # The anchor is looked up in this release's archive whichever file the link
  # names, so point the link at that file too: renaming `unreleased.md` by hand
  # at a release cut would otherwise leave every summary linking the old name.
  defp repoint_long_form(entry, archive_path) do
    Regex.replace(
      ~r/(\[long\s+form\]\(\s*)#{@archive_dir}\/[^)#\s]+#/,
      entry,
      "\\1#{archive_path}#"
    )
  end

  # `%{anchor => block}` for an archive already on disk. A block runs from its
  # anchor tag to the next anchor tag or `## ` section heading.
  defp archived_blocks(path) do
    case File.read(path) do
      {:ok, text} -> parse_archive(path, text)
      {:error, _} -> %{}
    end
  end

  # Two blocks under one id — two branches condensing entries with the same
  # opening, merged — would collapse to one here and the next write would drop
  # the other long form, so that stops instead.
  defp parse_archive(path, text) do
    case duplicate_anchor_ids(text) do
      [] -> :ok
      dups -> Mix.raise(duplicate_anchor_message(path, dups))
    end

    ~r/<a id="([^"]+)"><\/a>/
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.chunk_every(2, 1)
    |> Enum.flat_map(fn
      [<<"<a id=\"", _::binary>> = tag, body] ->
        # Rebuilt in the shape generation writes, so re-reading a block and
        # writing it straight back out is byte-identical.
        [{anchor_id(tag), tag <> "\n\n" <> block_body(body)}]

      _ ->
        []
    end)
    |> Map.new()
  end

  defp duplicate_anchor_ids(text) do
    ~r/<a id="([^"]+)"><\/a>/
    |> Regex.scan(text)
    |> Enum.map(&List.last/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} -> id end)
    |> Enum.sort()
  end

  defp duplicate_anchor_message(path, ids) do
    """
    #{path} has more than one block under the same anchor: #{Enum.join(ids, ", ")}.

    Usually two branches condensed entries that open the same way. Rename one
    block's `<a id>` and the `[long form]` link in CHANGELOG.md that points at
    it, then re-run: reading the archive as it is would keep one block and drop
    the other.
    """
  end

  defp anchor_id(tag), do: Regex.run(~r/id="([^"]+)"/, tag) |> Enum.at(1)

  defp block_body(body) do
    body
    |> String.split("\n")
    |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
    |> Enum.join("\n")
    |> String.trim()
  end

  # Cutting a release moves `## [Unreleased]` to `## [X.Y.Z]`, and its entries
  # still point at `docs/changelog/unreleased.md`. Rename the archive to match
  # the release and re-point the links, so the release step is `--condense`
  # rather than a hand-run `sed`.
  defp adopt_renamed_archive(release, archive_path) do
    with false <- File.exists?(archive_path),
         [_, stale] <- Regex.run(~r{Long form: \[(#{@archive_dir}/[^\]]+)\]}, release.body),
         true <- File.exists?(stale) do
      File.rename!(stale, archive_path)

      Mix.shell().info([
        :yellow,
        "Renamed ",
        :reset,
        "#{stale} -> #{archive_path} (it holds this release's long form)."
      ])

      %{release | body: String.replace(release.body, stale, archive_path)}
    else
      _ -> release
    end
  end

  defp anchor_tag(anchor), do: ~s(<a id="#{anchor}"></a>)

  defp relative_to_archive(path), do: "../../" <> path

  # Matched against the *start* of the entry, not anywhere in it: entries in the
  # same section cross-reference each other, so a needle taken from one entry's
  # lead also appears in the body of the entry above it.
  defp decision_for(version, section, entry) do
    lead = entry |> flatten() |> String.replace("**", "")

    Enum.find_value(@decisions, fn {v, s, needle, number, title} ->
      if v == version and s == section and String.starts_with?(lead, needle) do
        {number, title}
      end
    end)
  end

  defp decision_path(number, title) do
    Path.join(
      @decisions_dir,
      "#{String.pad_leading(to_string(number), 4, "0")}-#{slug(title)}.md"
    )
  end

  # ---- rendering ---------------------------------------------------------

  # `Breaking` is carved out of `Upgrade notes` before anything is condensed, so
  # the summary and the archive agree on which section each note is in — and so
  # a second `--condense`, which finds the two sections already separate, is a
  # no-op rather than a reshuffle.
  #
  # Which notes are breaking is editorial judgement (`@breaking`), not something
  # to infer from wording, so a release cut writes its own `### Breaking` and
  # this only has to handle the entries that predate the section.
  defp split_breaking(sections, version) do
    {upgrade, rest} = Enum.split_with(sections, fn {name, _} -> name == "Upgrade notes" end)

    case upgrade do
      [] ->
        sections

      [{_, body}] ->
        {breaking, notes} = body |> notes() |> Enum.split_with(&breaking?(version, &1))

        [{"Upgrade notes", Enum.join(notes, "\n\n")}, {"Breaking", Enum.join(breaking, "\n\n")}]
        |> Enum.reject(fn {_, b} -> String.trim(b) == "" end)
        |> Kernel.++(rest)
    end
  end

  # 0.7.0 carries `### Security` and `### Changed` twice each — the file grew an
  # entry at a time and nobody merged them. Two headings with one name also make
  # the anchors ambiguous, so fold them into one, first appearance winning the
  # position.
  defp merge_duplicate_sections(sections) do
    sections
    |> Enum.reduce([], &merge_section/2)
    |> Enum.reverse()
  end

  defp merge_section({name, body}, seen) do
    case Enum.find_index(seen, fn {already, _} -> already == name end) do
      nil -> [{name, body} | seen]
      index -> List.update_at(seen, index, &append_body(&1, body))
    end
  end

  defp append_body({name, prior}, body) do
    {name, String.trim_trailing(prior) <> "\n\n" <> String.trim(body)}
  end

  defp breaking?(version, summary) do
    flat = flatten(summary)
    Enum.any?(@breaking, fn {v, needle} -> v == version and String.contains?(flat, needle) end)
  end

  defp render_sections(sections) do
    sections
    |> Enum.reject(fn {_name, body} -> String.trim(body) == "" end)
    |> Enum.sort_by(fn {name, _} -> section_rank(name) end)
    |> Enum.map_join("\n", fn
      {nil, body} -> String.trim(body) <> "\n"
      {name, body} -> "### #{name}\n\n" <> String.trim(body) <> "\n"
    end)
  end

  # A release preamble (`nil`) always leads; an unknown section keeps its place
  # at the end rather than being dropped, and `--check` reports it.
  defp section_rank(nil), do: -1

  defp section_rank(name) do
    case Enum.find_index(@section_order, &(&1 == name)) do
      nil -> length(@section_order)
      index -> index
    end
  end

  defp render_archive(release, sections) do
    body =
      sections
      |> Enum.reject(fn {_name, body} -> String.trim(body) == "" end)
      |> Enum.map_join("\n", fn
        {nil, body} -> String.trim(body) <> "\n"
        {name, body} -> "## #{name}\n\n" <> String.trim(body) <> "\n"
      end)

    """
    # KilnCMS #{label(release)} — full release notes

    The long-form entries behind
    [CHANGELOG.md → #{label(release)}](../../CHANGELOG.md##{slug(release.heading)}),
    as they were written when each change merged. `CHANGELOG.md` carries the
    one-line summary of each; this file carries the reasoning.

    #{reroot_links(body)}
    """
  end

  # An entry moved out of `CHANGELOG.md` keeps its words but not its depth:
  # `](docs/events.md)` resolved from the repo root, and these files sit one
  # level inside `docs/`. Rewriting the target is the only edit made to an
  # entry's text, and `--verify` compares link *text*, not targets, so it still
  # proves the prose survived.
  defp reroot_links(body) do
    body
    |> String.replace(~r/\]\(docs\//, "](../")
    |> String.replace(~r/\]\(CHANGELOG\.md/, "](../../CHANGELOG.md")
  end

  defp render_decision(number, title, release, section, entry, refs) do
    """
    # #{String.pad_leading(to_string(number), 4, "0")}. #{title}

    - **Status** — accepted, shipped in
      [#{release.version}](../changelog/v#{release.version}.md) (#{section}).
    - **References** — #{if refs == [], do: "none recorded", else: Enum.map_join(refs, ", ", &"[##{&1}](#{@repo_url}/issues/#{&1})")}.
    - **Changelog** — [#{release.version} → #{section}](../../CHANGELOG.md##{slug(release.heading)}).

    ## Decision

    #{entry |> dedent_entry() |> reroot_links() |> String.trim()}
    """
  end

  # An archived bullet becomes prose in an ADR: drop the `- ` and the two-space
  # continuation indent, leaving the author's words and their own nested lists.
  defp dedent_entry(entry) do
    entry
    |> String.replace(~r/^- /, "")
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "  " <> rest -> rest
      line -> line
    end)
  end

  # ---- references --------------------------------------------------------

  defp entry_references(entry, prs) do
    case references(entry) do
      [] -> from_history(entry, prs)
      refs -> refs
    end
  end

  @doc false
  # An entry with no `#1234` of its own still has one: the pull request of the
  # earliest commit that wrote it. A commit "wrote" the entry if it added one of
  # its lines verbatim, or if its added text contains the entry's opening words.
  #
  # Either alone misattributes. Verbatim lines miss an entry whose lines were
  # all rewrapped — by a run of this task, committed under its own pull request,
  # which then takes the credit. Opening words miss an entry whose opening was
  # edited later — a release cut tightening the wording takes the credit.
  # Taking the earliest commit that satisfies either gets both right.
  #
  # Public only so it can be tested against a fake `git log` rather than a repo.
  def from_history(entry, index) do
    case history_commit(entry, index) do
      {pr, _text, _added} when is_binary(pr) -> [pr]
      _ -> []
    end
  end

  # The earliest commit that wrote `entry`, whether or not it names a pull
  # request. The opening words need 40 characters, like a verbatim line: a short
  # phrase is found inside unrelated entries.
  defp history_commit(entry, index) do
    split = String.split(entry, "\n")
    needle = split |> index_text() |> String.slice(0, 80)
    lines = split |> Enum.map(&String.trim/1) |> Enum.filter(&(String.length(&1) >= 40))

    Enum.find(index, fn {_pr, text, added} ->
      (String.length(needle) >= 40 and String.contains?(text, needle)) or
        Enum.any?(lines, &MapSet.member?(added, &1))
    end)
  end

  # The one normalisation both sides of the opening-words match use: each line
  # trimmed with its bullet marker dropped, joined, whitespace collapsed. An
  # entry flattened any other way never matches the commit that wrote it once
  # it holds a nested list.
  defp index_text(lines) do
    lines
    |> Enum.map_join(" ", &(&1 |> String.trim() |> String.replace(~r/^- /, "")))
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # One entry: the summary wrapped as a bullet, then its links on a line of
  # their own. The links are never wrapped — a URL has no spaces to break at,
  # so wrapping them only ever splits the label away from its target.
  defp entry_line(summary, refs, detail) do
    case reference_links(refs, detail) do
      "" -> wrap_bullet(summary)
      links -> wrap_bullet(summary) <> "\n  " <> links
    end
  end

  defp reference_links([], nil), do: ""
  defp reference_links([], detail), do: "([long form](#{detail}))"

  defp reference_links(refs, detail) do
    links = Enum.map_join(refs, ", ", &"[##{&1}](#{@repo_url}/issues/#{&1})")
    if detail, do: "(#{links} · [long form](#{detail}))", else: "(#{links})"
  end

  # `[{pr | nil, added_text, added_lines}]`, oldest commit first, for every
  # commit that touched CHANGELOG.md. `added_text` is the added lines with
  # bullets and indentation stripped and whitespace collapsed, so a rewrapped
  # paragraph still matches the words it was wrapped from; `added_lines` is the
  # same lines, trimmed, for the verbatim match.
  defp pull_request_index do
    case System.cmd(
           "git",
           ~w[log --reverse --format=@@@%s -p --no-color -U0 --] ++ [@changelog],
           stderr_to_stdout: true
         ) do
      {out, 0} -> build_index(out)
      {_out, _} -> []
    end
  end

  @doc false
  # Public only so `from_history/2` can be tested against a fake `git log`.
  def build_index(out) do
    out
    |> String.split(~r/^@@@/m, trim: true)
    |> Enum.map(fn commit ->
      [subject | diff] = String.split(commit, "\n")

      added =
        Enum.flat_map(diff, fn
          "+++" <> _rest -> []
          "+" <> line -> [String.trim(line)]
          _line -> []
        end)

      {subject_pr(subject), index_text(added), MapSet.new(added)}
    end)
  end

  defp subject_pr(subject) do
    case Regex.run(~r/\(#(\d+)\)\s*$/, subject) do
      [_, number] -> number
      _ -> nil
    end
  end

  # Re-wrap a summary at 80 columns as a markdown bullet, matching the file.
  defp wrap_bullet(text) do
    text
    |> String.split(" ")
    |> Enum.reduce([[]], fn word, [line | rest] ->
      current = Enum.join(Enum.reverse(line), " ")

      if line != [] and String.length(current) + String.length(word) + 3 > 80 do
        [[word], line | rest]
      else
        [[word | line] | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&Enum.join(Enum.reverse(&1), " "))
    |> Enum.with_index()
    |> Enum.map_join("\n", fn
      {line, 0} -> "- " <> line
      {line, _} -> "  " <> line
    end)
  end

  # ---- check -------------------------------------------------------------

  defp check do
    text = File.read!(@changelog)
    {_preamble, releases, _footer} = parse(text)

    problems =
      Enum.flat_map(releases, fn release ->
        release.body
        |> sections()
        |> Enum.flat_map(&check_section(release, &1))
      end) ++ check_links(text) ++ check_duplicate_anchors()

    report(problems)
  end

  defp check_section(_release, {nil, _body}), do: []

  defp check_section(release, {name, body}) do
    unknown =
      if name in @section_order do
        []
      else
        [
          "#{describe(release)}: unknown section \"### #{name}\" — use one of #{Enum.join(@section_order, ", ")}."
        ]
      end

    entries = units(name, body)

    unknown ++ Enum.flat_map(entries, &check_entry(release, name, &1))
  end

  defp check_entry(release, name, entry) do
    # The links line is navigation, not reading: counting it would fail an entry
    # `--condense` itself produced from a three-line opening sentence.
    lines =
      entry
      |> String.trim()
      |> String.split("\n")
      |> Enum.reject(&String.match?(&1, @links_line))
      |> length()

    too_long =
      if release.version == nil and lines > @unreleased_max_lines do
        [
          """
          #{describe(release)} / #{name}: an entry runs #{lines} lines, over the #{@unreleased_max_lines}-line cap.

              #{String.slice(flatten(entry), 0, 70)}...

          #{too_long_advice(entry)}
          """
        ]
      else
        []
      end

    unlinked =
      if references(entry) == [] and not String.contains?(entry, "](") do
        [
          "#{describe(release)} / #{name}: an entry has no reference and no link — " <>
            "a reader has nowhere to go for the detail:\n\n    #{String.slice(flatten(entry), 0, 70)}..."
        ]
      else
        []
      end

    too_long ++ unlinked
  end

  # Every `docs/changelog/...#anchor` and `docs/decisions/...` link in the file
  # must resolve, or the long form this file points at is gone.
  defp check_links(text) do
    ~r/\]\((docs\/(?:changelog|decisions)\/[^)\s]+)\)/
    |> Regex.scan(text)
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn link ->
      [path | anchor] = String.split(link, "#", parts: 2)

      cond do
        not File.exists?(path) ->
          ["CHANGELOG.md links to #{path}, which does not exist."]

        anchor != [] and not String.contains?(File.read!(path), ~s(id="#{hd(anchor)}")) ->
          ["CHANGELOG.md links to #{link}, but #{path} has no such anchor."]

        true ->
          []
      end
    end)
  end

  # An archive with two blocks under one id cannot be read back without losing
  # one of them, and a link to that id opens whichever comes first.
  defp check_duplicate_anchors do
    "#{@archive_dir}/*.md"
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case duplicate_anchor_ids(File.read!(path)) do
        [] -> []
        ids -> ["#{path} has more than one block under #{Enum.join(ids, ", ")}."]
      end
    end)
  end

  # `--condense` keeps the author's opening sentence as written, so once an entry
  # is condensed only a shorter opening can bring it under the cap.
  defp too_long_advice(entry) do
    if condensed?(entry) do
      "Its opening sentence alone is over the cap, and `--condense` never rewrites\n" <>
        "it. Shorten the bold lead — the rest is already in the long form."
    else
      "Run `mix kiln.changelog --condense` to move the reasoning to docs/changelog/,\n" <>
        "or write the summary yourself and link the pull request:\n" <>
        "`- **Summary.** ([#1234](...))`."
    end
  end

  defp describe(%{version: nil}), do: "Unreleased"
  defp describe(%{version: version}), do: version

  defp report([]) do
    Mix.shell().info([:green, "CHANGELOG.md is within budget.", :reset])
  end

  defp report(problems) do
    Mix.shell().error(Enum.join(problems, "\n\n"))

    Mix.raise(
      "#{length(problems)} CHANGELOG.md problem(s). See `mix help kiln.changelog` for the rules."
    )
  end

  # ---- verify ------------------------------------------------------------

  defp verify(ref) do
    before = git_show!(ref, @changelog)

    archived_before =
      ref
      |> archive_paths()
      |> Enum.map_join("\n\n", &(ref |> git_show!(&1) |> archive_prose()))

    haystack =
      [
        @changelog
        | Path.wildcard("#{@archive_dir}/*.md") ++ Path.wildcard("#{@decisions_dir}/*.md")
      ]
      |> Enum.map_join("\n\n", &File.read!/1)
      |> normalize()

    missing =
      (paragraphs(release_prose(before)) ++ paragraphs(archived_before))
      |> Enum.uniq()
      |> Enum.reject(&String.contains?(haystack, normalize(&1)))

    if missing == [] do
      Mix.shell().info([
        :green,
        "No loss: ",
        :reset,
        "every paragraph of #{ref}'s #{@changelog} and its long forms is still reachable."
      ])
    else
      Enum.each(missing, &Mix.shell().error("MISSING: " <> String.slice(normalize(&1), 0, 160)))
      Mix.raise("#{length(missing)} paragraph(s) of #{ref}'s changelog have no destination.")
    end
  end

  defp git_show!(ref, path) do
    case System.cmd("git", ["show", "#{ref}:#{path}"], stderr_to_stdout: true) do
      {out, 0} -> out
      {out, _} -> Mix.raise("Could not read #{ref}:#{path}:\n#{out}")
    end
  end

  # The long forms `REF` had already moved out of CHANGELOG.md. Checking only
  # CHANGELOG.md at a condensed `REF` proves nothing about them: it holds just
  # the summaries, so a long form lost from the archive still read as no loss.
  defp archive_paths(ref) do
    case System.cmd(
           "git",
           ["ls-tree", "-r", "--name-only", ref, "--", @archive_dir, @decisions_dir],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.filter(&archived_long_form?/1)

      {_out, _} ->
        []
    end
  end

  defp archived_long_form?(path) do
    String.ends_with?(path, ".md") and
      (String.starts_with?(path, @archive_dir <> "/") or
         Regex.match?(~r/\A#{@decisions_dir}\/\d{4}-/, path))
  end

  # An archive's prose is its entries. Its intro and anchor tags are generated,
  # and change when a release is cut and the file renamed.
  defp archive_prose(text) do
    text
    |> String.split(~r/\n\s*\n/)
    |> Enum.reject(fn para ->
      para = String.trim(para)

      String.starts_with?(para, "<a id=") or
        String.starts_with?(para, "The long-form entries behind")
    end)
    |> Enum.join("\n\n")
  end

  # The release entries, and only those. This file's own front matter — how to
  # read it, how to write an entry — is documentation about the format, and
  # changing the format is precisely what this task does; holding it to a
  # no-loss rule would forbid ever describing the new shape.
  defp release_prose(text) do
    {_preamble, releases, _footer} = parse(text)
    Enum.map_join(releases, "\n\n", & &1.body)
  end

  # Prose paragraphs only. Headings, anchors and the link-reference footer are
  # structure, not content: they are rewritten by design and prove nothing.
  defp paragraphs(text) do
    text
    # Blank lines, and also the start of a bullet: entries in this file are not
    # reliably separated by a blank line, so a blank-line split alone yields
    # chunks that straddle two entries and can never match a destination that
    # (correctly) keeps them apart.
    |> String.split(~r/\n\s*\n|\n(?=- )/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn para ->
      para == "" or String.starts_with?(para, "#") or
        String.match?(para, ~r/^\[[^\]]+\]: http/) or
        String.length(normalize(para)) < 25
    end)
  end

  defp normalize(text) do
    text
    |> String.replace(~r/^\s*[-*]\s+/m, "")
    # Link targets are re-rooted when an entry moves into `docs/` (see
    # `reroot_links/1`); the link *text* is prose and is still compared.
    |> String.replace(~r/\]\([^)\s]*\)/, "]")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
