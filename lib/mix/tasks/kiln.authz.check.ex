defmodule Mix.Tasks.Kiln.Authz.Check do
  @moduledoc """
  Fails when a request-facing module bypasses Ash policies without saying why.

  `authorize?: false` skips *every* policy on the resource — including the
  ones a later PR adds, and including any policy declared below a `bypass`
  (`docs/policy-matrix.md`, "The system actor"). In a row-based multi-tenant
  system that makes each bypass a small piece of the authorization surface
  that no policy block documents. #1309 counted 563 of them; the ones that
  matter most are the ones on request paths, where the caller is a browser or
  an API client rather than a worker.

  This gate does not forbid the bypass — public delivery, pre-auth flows and
  system reads for display data all need it. It forbids an *unexplained* one:
  every `authorize?: false` must carry a marker that says why it is safe
  (system read, tenant already scoped, action's own filter carries the
  grant, …). A reviewer then reads the reason instead of reconstructing it,
  and a fresh site cannot land by copy-paste alone.

  ## What counts as a justification: the marker (#1739)

  A comment of exactly this shape:

      # authorize?: false — <reason>

  The dash is an em dash (`—`) or `--`, with a space on each side, and the
  reason must hold at least three words of two or more letters (so
  `see above`, or `—` alone, is not one). The reason may run on over the comment lines below the marker.
  Nothing else counts: a comment that merely *mentions* a bypass — "the
  admin bypass above", a `multitenancy :bypass` read, `` `authorize?: false` ``
  in backticks mid-sentence — justifies nothing. Before #1739 any comment
  matching `authorize?` or `bypass` within 12 lines did, so unrelated prose
  silently covered real bypasses.

  Where the marker goes:

    * in the comment block **directly above** the call — no blank line or
      code between them — or above any line of the statement the call is
      part of, from its first line down to the call: above `x =` or a
      pipeline's head, a `with`'s `<-` clause, a `case` clause's pattern, the
      `fetch = fn loc ->` the call sits in, or a one-line `def f(x), do:`;
    * or **inside** the call: a trailing comment, one between its options,
      or one on its closing line.

  A marker above a `def ... do` does not reach into its body: put it on the
  statement that bypasses.

  A marker serves **one** site. Two bypass calls in one statement (a pipeline
  that reads and then loads) need two markers, and a second
  `authorize?: false` pasted under a justified one is red until it, too,
  says why it is safe. (Two `authorize?: false` inside the *same* call share
  the call's marker.)

  The scan is AST-based, so the phrase inside a string, a `@moduledoc` or a
  comment is not a site — only the actual `authorize?: false` keyword is. A
  bypass spelled without the literal (`authorize?: flag`,
  `Keyword.put(opts, :authorize?, false)`) is not a site either; those need
  a reader, not this gate.

  ## Scope: all of `lib/`, with a shrinking backlog

  Every file under `lib/` is gated. A file that predates the system-actor
  migration and still carries unexplained bypasses has an entry in `@backlog`
  recording exactly how many — 129 files, 313 sites when this landed (#1402).

  That list is a **ratchet, not an exemption**:

    * a file with no entry must be clean, so new code is gated from the day it
      lands;
    * a listed file may not gain a site — the count is a ceiling;
    * a listed file that *loses* one fails too, with the number to write. An
      allowance nobody maintains stops being a ratchet, and the message says
      what to change.

  Nothing may be added to the backlog. Emptying it finishes #1402, and #1659
  did: the backlog is now empty, so every file under `lib/` must be clean. The
  mechanism stays in place so that is enforced, not assumed.

  Pass paths (files or directories) to scan something narrower; the backlog
  still applies, and entries for files the scan did not cover are left alone.

      mix kiln.authz.check
      mix kiln.authz.check lib/kiln_cms/billing.ex
  """
  @shortdoc "Fails on an unexplained `authorize?: false` anywhere in lib/"

  use Mix.Task

  @default_paths ["lib"]

  # Unexplained `authorize?: false` sites that predate the system-actor
  # migration, per file. A ratchet: counts may only go DOWN, and no entry may
  # be added. See "Scope" above; the tracking issue is #1402.
  #
  # Empty since #1659's last batch: every site under `lib/` is now either run
  # as an actor or justified. Kept as a map, not deleted, so `problems/2` and
  # its tests keep their shape; with nothing in it, any unexplained site in any
  # file is a regression.
  @backlog %{}
  # `# authorize?: false — <reason>`, or `--` for the dash. The reason is
  # what a reviewer reads instead of reconstructing it, so it must say
  # something: at least `@min_reason_words` words.
  @marker ~r/^#\s*authorize\?: false\s+(?:—|--)\s+(\S.*)$/u
  @min_reason_words 3

  @impl Mix.Task
  def run(args) do
    paths = if args == [], do: @default_paths, else: args
    files = paths |> Enum.flat_map(&source_files/1) |> Enum.uniq() |> Enum.sort()

    sites = Map.new(files, fn path -> {path, path |> File.read!() |> unjustified(path)} end)
    counts = Map.new(sites, fn {path, lines} -> {path, length(lines)} end)

    case problems(counts) do
      [] ->
        Mix.shell().info(summary(paths, counts, @backlog))

      problems ->
        shell = Mix.shell()
        Enum.each(problems, &shell.error/1)
        report_new_sites(shell, sites, @backlog)
        Mix.raise(failure_message(length(problems)))
    end
  end

  @doc """
  The #1402 backlog: `%{path => allowed_unjustified_count}`.

  Exposed so the tests can check it stays honest — an entry naming a file that
  no longer exists can never be cleared by the ratchet, and would sit there
  looking like outstanding work that is already done.
  """
  @spec backlog() :: %{Path.t() => pos_integer()}
  def backlog, do: @backlog

  @doc """
  What is wrong with a `%{path => unjustified_count}` scan, as messages.

  Two kinds, and both fail the build:

    * a file with **more** unexplained bypasses than `backlog` allows — zero
      for anything not listed. This is the gate.
    * a backlog entry that is now too **generous**: the file was cleaned up and
      nobody lowered the number. An allowance nobody maintains is an exemption
      rather than a ratchet, so this fails too, with the number to write.

  Only entries for files the scan actually covered are judged, so scanning one
  file does not report every other file's entry as stale.

  Public because the tests drive it directly: a ratchet whose arithmetic is
  wrong in the permissive direction passes forever and nobody finds out.
  """
  @spec problems(%{Path.t() => non_neg_integer()}, %{Path.t() => pos_integer()}) :: [String.t()]
  def problems(counts, backlog \\ @backlog) do
    scanned = counts |> Map.keys() |> MapSet.new()

    regressions =
      for {path, count} <- Enum.sort(counts),
          allowed = Map.get(backlog, path, 0),
          count > allowed do
        "#{path}: #{count} unexplained `authorize?: false`, #{allowed} allowed" <>
          if allowed == 0, do: ".", else: " by the #1402 backlog."
      end

    stale =
      for {path, allowed} <- Enum.sort(backlog),
          MapSet.member?(scanned, path),
          count = Map.fetch!(counts, path),
          count < allowed do
        "#{path}: the #1402 backlog allows #{allowed} but the file has #{count} — " <>
          if count == 0,
            do: "drop the entry, which finishes this file.",
            else: "lower the number to #{count}."
      end

    regressions ++ stale
  end

  # The individual lines behind a regression, so a contributor sees WHERE
  # rather than only how many. Only for files over their allowance; a
  # backlogged file's existing sites are not news.
  defp report_new_sites(shell, sites, backlog) do
    for {path, lines} <- Enum.sort(sites),
        length(lines) > Map.get(backlog, path, 0),
        {^path, line} <- lines do
      shell.error(
        "#{path}:#{line}: `authorize?: false` without an `# authorize?: false — <reason>` marker"
      )
    end
  end

  defp summary(paths, counts, backlog) do
    remaining =
      counts |> Map.keys() |> Enum.map(&Map.get(backlog, &1, 0)) |> Enum.sum()

    scope = Enum.join(paths, ", ")

    if remaining == 0 do
      "Authz: every `authorize?: false` under #{scope} is justified."
    else
      files = Enum.count(counts, fn {path, _} -> Map.has_key?(backlog, path) end)

      "Authz: no new unexplained `authorize?: false` under #{scope} " <>
        "(#{remaining} still in the #1402 backlog, across #{files} files)."
    end
  end

  defp failure_message(count) do
    """
    #{count} file(s) off the authz ratchet.

    `authorize?: false` skips every policy on the resource. Either pass an
    actor — the request's, or `KilnCMS.SystemActor.new/1` for worker and job
    code, which the resource's policies then admit by name — or put a marker
    directly above the call (or inside it) saying why the bypass is safe:

        # authorize?: false — <reason, at least #{@min_reason_words} words>

    A tenant already scoped by the router, a delivery action whose own filter
    carries the grant, a pre-auth flow with no actor, ... A comment that merely
    mentions "bypass" does not count, and one marker covers one call.

    The `@backlog` in this task is a ratchet over what predates the
    system-actor migration: counts may only go down, and no entry may be added.
    See #1309 and #1402.
    """
  end

  @doc """
  The `{path, line}` of every `authorize?: false` in `source` that no marker
  justifies. Exposed for tests: this is the part that would silently pass on a
  real bypass if it went wrong.
  """
  @spec unjustified(String.t(), Path.t()) :: [{Path.t(), pos_integer()}]
  def unjustified(source, path \\ "nofile") do
    case Code.string_to_quoted_with_comments(source,
           file: path,
           literal_encoder: &{:ok, {:__block__, &2, [&1]}},
           token_metadata: true
         ) do
      {:ok, ast, comments} ->
        sites = sites(ast)
        served = serve(markers(comments), sites, comment_only_lines(source))

        for site <- sites,
            site not in served,
            line <- site.lines,
            do: {path, line}

      {:error, {meta, message, token}} ->
        Mix.raise("#{path}:#{meta[:line]}: cannot parse: #{parse_error(message, token)}")
    end
  end

  @doc """
  Whether a comment's text (including its `#`) is a justification marker:
  `# authorize?: false — <reason>` (or `--` for the dash), with a reason of at
  least #{@min_reason_words} words of two or more letters. Public so the grammar is pinned
  by the tests.
  """
  @spec marker?(String.t()) :: boolean()
  def marker?(text) do
    case Regex.run(@marker, text, capture: :all_but_first) do
      [reason] -> length(Regex.scan(~r/\p{L}{2,}/u, reason)) >= @min_reason_words
      nil -> false
    end
  end

  # `Code.string_to_quoted` reports some errors as a `{prefix, suffix}` pair
  # around the offending token rather than a plain string.
  defp parse_error({prefix, suffix}, token), do: prefix <> token <> suffix
  defp parse_error(message, token) when is_binary(message), do: message <> token

  # Line numbers of every marker comment.
  defp markers(comments) do
    for %{line: line, text: text} <- comments, marker?(text), do: line
  end

  # Lines holding nothing but a comment: the building blocks of the comment
  # block "directly above" a line. A trailing comment on a code line is not
  # one, and neither is a blank line — either ends the block.
  defp comment_only_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {text, _} -> String.starts_with?(String.trim_leading(text), "#") end)
    |> MapSet.new(fn {_, line} -> line end)
  end

  # The comment block ending on the line directly above `line`.
  defp block_above(line, comment_only) do
    (line - 1)
    |> Stream.iterate(&(&1 - 1))
    |> Enum.take_while(&(&1 >= 1 and MapSet.member?(comment_only, &1)))
  end

  # A marker on line `c` may justify `site` when it is inside the call's span
  # (a trailing comment, one between its options, one on its closing line),
  # or in a comment block directly above a line of the same statement, from
  # its first line (`x =`, a pipeline's head, a `case` clause's pattern) down
  # to the call's own first line. Each marker justifies ONE site: markers are handed out most
  # specific first (fewest eligible sites), each to the first eligible site
  # not yet justified. Returns the justified sites.
  defp serve(markers, sites, comment_only) do
    above =
      Map.new(sites, fn site ->
        lines = min(site.anchor, site.start)..site.start
        {site, lines |> Enum.flat_map(&block_above(&1, comment_only)) |> MapSet.new()}
      end)

    eligible =
      for c <- markers do
        {c,
         Enum.filter(sites, fn site ->
           c in site.start..site.stop or MapSet.member?(Map.fetch!(above, site), c)
         end)}
      end

    eligible
    |> Enum.sort_by(fn {c, candidates} -> {length(candidates), c} end)
    |> Enum.reduce(MapSet.new(), fn {_c, candidates}, served ->
      case Enum.find(candidates, &(not MapSet.member?(served, &1))) do
        nil -> served
        site -> MapSet.put(served, site)
      end
    end)
  end

  # Every bypass site: the call carrying one or more `authorize?: false`
  # options (`start` = the call's first line, `stop` = its closing line, or
  # the option's line when the call has no closing token), or the bare
  # option itself when it is not an argument of a call (`opts = [authorize?:
  # false]`). `lines` are the option lines, which is what gets reported.
  # `anchor` is the first line of the statement the site sits in.
  #
  # With the literal encoder every literal is wrapped in a `:__block__` node
  # carrying its line, so a keyword-list pair `authorize?: false` shows up as
  # `{{:__block__, meta, [:authorize?]}, {:__block__, _, [false]}}`.
  defp sites(ast) do
    {calls, pairs} = walk(ast, first_line(ast), {[], []})

    covered = calls |> Enum.flat_map(& &1.lines) |> MapSet.new()

    bare_sites =
      for {line, anchor} <- Enum.uniq(pairs), line not in covered do
        %{start: line, stop: line, lines: [line], anchor: anchor}
      end

    Enum.sort_by(calls ++ bare_sites, &{&1.start, &1.lines})
  end

  @body_keys [:do, :else, :after, :rescue, :catch]

  # `stmt` is the first line of the statement being walked. A new statement
  # starts at each expression of a multi-expression block, at a `do`/`else`
  # … block body, at each `->` clause of a `case`/`cond`/… (its pattern and
  # body together) and at each `<-` clause of a `with` or `for`; everything
  # else (arguments,
  # operands, pipeline stages) belongs to the statement it is part of.
  defp walk({{:__block__, meta, [:authorize?]}, {:__block__, _, [false]}}, stmt, {calls, pairs}) do
    {calls, [{Keyword.fetch!(meta, :line), stmt} | pairs]}
  end

  defp walk({:__block__, _, exprs}, _stmt, acc) when is_list(exprs) and length(exprs) > 1 do
    Enum.reduce(exprs, acc, &walk(&1, first_line(&1), &2))
  end

  defp walk({:<-, _, _} = clause, _stmt, acc), do: walk_node(clause, first_line(clause), acc)

  # An anonymous function is part of the expression it is passed to or bound
  # in (`fetch = fn loc -> … end`, `Enum.map(xs, fn x -> … end)`): its
  # clauses stay in that statement.
  defp walk({:fn, _, clauses}, stmt, acc) when is_list(clauses) do
    Enum.reduce(clauses, acc, fn
      {:->, _, [head, body]}, acc -> walk(body, stmt, walk(head, stmt, acc))
      other, acc -> walk(other, stmt, acc)
    end)
  end

  defp walk({:->, _, [head, body]} = clause, _stmt, acc) do
    stmt = first_line(clause)
    walk(body, stmt, walk(head, stmt, acc))
  end

  defp walk({_, meta, args} = node, stmt, acc) when is_list(args) and is_list(meta),
    do: walk_node(node, stmt, acc)

  defp walk({key, value}, stmt, acc) do
    if body_key?(key),
      do: walk(value, first_line(value), acc),
      else: walk(value, stmt, walk(key, stmt, acc))
  end

  defp walk(list, stmt, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, stmt, &2))
  defp walk(_leaf, _stmt, acc), do: acc

  # A call (or operator) node: record it as a site when it carries the option
  # directly, then walk its parts within the same statement.
  defp walk_node({fun, meta, args}, stmt, {calls, pairs}) do
    calls =
      case {meta[:line], bypass_option_lines(args)} do
        {nil, _} ->
          calls

        {_, []} ->
          calls

        {line, lines} ->
          stop = get_in(meta, [:closing, :line]) || Enum.max(lines)
          [%{start: line, stop: stop, lines: Enum.sort(lines), anchor: stmt || line} | calls]
      end

    walk(args, stmt, walk(fun, stmt, {calls, pairs}))
  end

  # A `do ... end` body (or `else ... end`, …) starts a statement of its own.
  # A keyword `do:` body does not: in `defp f(x), do: g(x, authorize?: false)`
  # the line directly above the call is the `defp`'s own, so the marker above
  # the one-liner is the one that belongs to it.
  defp body_key?({:__block__, meta, [key]}),
    do: key in @body_keys and meta[:format] != :keyword

  defp body_key?(key), do: key in @body_keys

  # The first source line of an expression: the smallest line any node in it
  # carries. A pipeline's `|>` node sits on the operator's line, not on its
  # head, so the node's own line is not enough.
  defp first_line(ast) do
    {_, min} =
      Macro.prewalk(ast, nil, fn
        {_, meta, _} = node, min when is_list(meta) ->
          case meta[:line] do
            line when is_integer(line) and (min == nil or line < min) -> {node, line}
            _ -> {node, min}
          end

        node, min ->
          {node, min}
      end)

    min
  end

  # The option lines of every `authorize?: false` that is a DIRECT option of
  # a call: an element of a keyword-list (or map) argument. Deeper matches
  # (inside a nested call, a `do` block, or a `fn`) belong to their own node.
  defp bypass_option_lines(args) do
    args
    |> Enum.flat_map(fn
      list when is_list(list) -> list
      {:%{}, _, list} when is_list(list) -> list
      _ -> []
    end)
    |> Enum.flat_map(fn
      {{:__block__, meta, [:authorize?]}, {:__block__, _, [false]}} ->
        [Keyword.fetch!(meta, :line)]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp source_files(path) do
    cond do
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.{ex,exs}"))
      File.exists?(path) -> [path]
      true -> Mix.raise("#{path}: no such file or directory")
    end
  end
end
