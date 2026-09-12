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

  Entries whose text carries no `#1234` reference get one from git: the commit
  that first added those lines to `CHANGELOG.md` is, by this repo's workflow,
  the pull-request merge that shipped the change. Upgrade notes and breaking
  notes do not, since the commit that adds them is the release cut.

  ### `--verify REF`

  Takes every paragraph of the **release entries** in `CHANGELOG.md` as of
  `REF` and asserts it still exists — in `CHANGELOG.md`, in `docs/changelog/`,
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
  # An `Upgrade notes` section is prose, not bullets: paragraphs, where a new
  # note starts at a paragraph opening with a bold lead. Returns those notes,
  # each still verbatim.
  def notes(body) do
    body
    |> String.split(~r/\n\n+/)
    |> Enum.reduce([], fn para, acc ->
      cond do
        String.trim(para) == "" -> acc
        new_note?(para) -> [[para] | acc]
        acc == [] -> [[para]]
        true -> [[para | hd(acc)] | tl(acc)]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&(&1 |> Enum.reverse() |> Enum.join("\n\n")))
  end

  # A bold lead opens a note. So does a bullet this task already condensed —
  # otherwise a second `--condense` reads a whole condensed section as one note,
  # keeps the first one's archive block and drops the rest.
  #
  # A plain bullet does *not*: an upgrade note may carry its own list ("two
  # smaller contract notes on the same endpoint:"), and those items belong to
  # the note above them.
  defp new_note?(paragraph) do
    trimmed = String.trim_leading(paragraph)

    String.starts_with?(trimmed, "**") or
      (String.starts_with?(trimmed, "- ") and condensed?(paragraph))
  end

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
    |> String.replace(~r/^- /, "")
    |> String.split("\n")
    |> Enum.map_join(" ", &String.trim/1)
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc false
  # Link targets are stripped first: a summary already carrying
  # `[long form](docs/changelog/v0.6.0.md#404-capture-...)` would otherwise be
  # read as referencing issue #404.
  def references(entry) do
    entry
    |> String.replace(~r/\]\([^)]*\)/, "]")
    |> then(&Regex.scan(~r/#(\d+)/, &1))
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

    {summaries, archived, adrs} =
      release.body
      |> sections()
      |> merge_duplicate_sections()
      |> split_breaking(release.version)
      |> Enum.sort_by(fn {name, _} -> section_rank(name) end)
      |> Enum.reduce({[], [], []}, fn {name, section}, {ss, as, ds} ->
        {summary, archive, section_adrs} =
          condense_section(release, name, section, {prs, kept}, archive_path)

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
  defp condense_section(_release, name, section, {_prs, kept}, archive_path)
       when name in ["Upgrade notes", "Breaking"] do
    {summaries, archived} =
      section
      |> notes()
      |> Enum.map(&note_result(&1, name, kept, archive_path))
      |> Enum.unzip()

    {Enum.join(summaries, "\n\n"), Enum.join(archived, "\n\n"), []}
  end

  defp condense_section(release, name, section, {prs, kept}, archive_path) do
    {summaries, archived, adrs} =
      section
      |> bullets()
      |> Enum.map(&entry_result(&1, release, name, {prs, kept}, archive_path))
      |> Enum.reduce({[], [], []}, fn {s, a, d}, {ss, as, ds} ->
        {[s | ss], [a | as], (d && [d | ds]) || ds}
      end)

    {Enum.reverse(summaries) |> Enum.join("\n\n"), Enum.reverse(archived) |> Enum.join("\n\n"),
     adrs}
  end

  defp note_result(note, name, kept, archive_path) do
    if condensed?(note),
      do: {String.trim(note), keep_block(kept, note, name)},
      else: condense_note(note, archive_path)
  end

  defp condense_note(note, archive_path) do
    anchor = slug(summarize(note))
    detail = if shortened?(note), do: "#{archive_path}##{anchor}", else: nil

    {entry_line(summarize(note), references(note), detail),
     anchor_tag(anchor) <> "\n\n" <> String.trim(note)}
  end

  # Already condensed: keep the summary as written and re-adopt the archive
  # block it names. Not yet: condense it.
  defp entry_result(entry, release, name, {prs, kept}, archive_path) do
    if condensed?(entry),
      do: {String.trim(entry), keep_block(kept, entry, name), nil},
      else: condense_entry(release, name, entry, prs, archive_path)
  end

  defp condense_entry(release, name, entry, prs, archive_path) do
    lead = summarize(entry)
    anchor = slug(lead)
    refs = entry_references(entry, prs)

    case decision_for(release.version, name, entry) do
      nil ->
        detail = if shortened?(entry), do: "#{archive_path}##{anchor}", else: nil
        {entry_line(lead, refs, detail), anchor_tag(anchor) <> "\n\n" <> String.trim(entry), nil}

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

  # An entry that is already a single line has nothing moved out of it, so it
  # gets no "long form" link — the link would point at a copy of itself.
  defp shortened?(entry) do
    length(String.split(String.trim(entry), "\n")) > 1
  end

  # An entry a previous run already condensed. Its long form is in the archive,
  # not in `CHANGELOG.md`, so re-condensing it would summarise a summary and —
  # worse, since the archive is rewritten from what this function is handed —
  # overwrite the long form with it.
  defp condensed?(entry) do
    String.match?(
      entry,
      ~r{\]\((?:#{Regex.escape(@repo_url)}/issues/\d+|#{@archive_dir}/|#{@decisions_dir}/)}
    )
  end

  # The archive block a condensed entry stands for, keyed by the anchor in its
  # own "long form" link.
  defp keep_block(kept, entry, section) do
    case Map.fetch(kept, entry_anchor(entry)) do
      {:ok, block} -> block
      :error -> Mix.raise(orphaned_message(entry, section))
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

  # A condensed entry names its own archive anchor. One that links only to a
  # decision record has no archive anchor of its own to find, so fall back to
  # re-deriving it the way it was derived in the first place.
  defp entry_anchor(entry) do
    case Regex.run(~r/\]\(#{@archive_dir}\/[^)#\s]+#([^)\s]+)\)/, entry) do
      [_, anchor] -> anchor
      nil -> slug(summarize(entry))
    end
  end

  # `%{anchor => block}` for an archive already on disk. A block runs from its
  # anchor tag to the next anchor tag or `## ` section heading.
  defp archived_blocks(path) do
    case File.read(path) do
      {:ok, text} ->
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

      {:error, _} ->
        %{}
    end
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

  # An entry with no `#1234` of its own still has one: the commit that first
  # added its lines to CHANGELOG.md is the pull request that shipped it. Look
  # up its longest line, which is the least likely to collide with another
  # entry's wrapping.
  defp from_history(entry, prs) do
    entry
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.find_value([], fn line ->
      case Map.get(prs, line) do
        nil -> nil
        pr -> [pr]
      end
    end)
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

  # `text -> "1234"` for every line ever added to CHANGELOG.md by a commit whose
  # subject ends in `(#1234)`. First writer wins: a line re-touched by a later
  # consolidation still belongs to the PR that introduced it.
  defp pull_request_index do
    case System.cmd(
           "git",
           ~w[log --reverse --format=@@@%s -p --no-color -U0 --] ++ [@changelog],
           stderr_to_stdout: true
         ) do
      {out, 0} -> build_index(out)
      {_out, _} -> %{}
    end
  end

  defp build_index(out) do
    out
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, &index_line/2)
    |> elem(0)
  end

  defp index_line("@@@" <> subject, {index, _pr}), do: {index, subject_pr(subject)}

  defp index_line("+++" <> _rest, acc), do: acc

  defp index_line("+" <> added, {index, pr}) when pr != nil do
    case String.trim(added) do
      "" -> {index, pr}
      text -> {Map.put_new(index, text, pr), pr}
    end
  end

  defp index_line(_line, acc), do: acc

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
      end) ++ check_links(text)

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

    entries = if name == "Upgrade notes", do: notes(body), else: bullets(body)

    unknown ++ Enum.flat_map(entries, &check_entry(release, name, &1))
  end

  defp check_entry(release, name, entry) do
    lines = entry |> String.trim() |> String.split("\n") |> length()

    too_long =
      if release.version == nil and lines > @unreleased_max_lines do
        [
          """
          #{describe(release)} / #{name}: an entry runs #{lines} lines, over the #{@unreleased_max_lines}-line cap.

              #{String.slice(flatten(entry), 0, 70)}...

          Unreleased entries are read by an operator deciding whether to upgrade.
          Keep the summary to #{@unreleased_max_lines} lines and put the reasoning in the pull
          request, then link it: `- **Summary.** ([#1234](...))`.
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
    before =
      case System.cmd("git", ["show", "#{ref}:#{@changelog}"], stderr_to_stdout: true) do
        {out, 0} -> out
        {out, _} -> Mix.raise("Could not read #{ref}:#{@changelog}:\n#{out}")
      end

    haystack =
      [
        @changelog
        | Path.wildcard("#{@archive_dir}/*.md") ++ Path.wildcard("#{@decisions_dir}/*.md")
      ]
      |> Enum.map_join("\n\n", &File.read!/1)
      |> normalize()

    missing =
      before
      |> release_prose()
      |> paragraphs()
      |> Enum.reject(&String.contains?(haystack, normalize(&1)))

    if missing == [] do
      Mix.shell().info([
        :green,
        "No loss: ",
        :reset,
        "every paragraph of #{ref}:#{@changelog} is still reachable."
      ])
    else
      Enum.each(missing, &Mix.shell().error("MISSING: " <> String.slice(normalize(&1), 0, 160)))
      Mix.raise("#{length(missing)} paragraph(s) of #{ref}:#{@changelog} have no destination.")
    end
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
