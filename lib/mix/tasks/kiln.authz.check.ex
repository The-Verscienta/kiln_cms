defmodule Mix.Tasks.Kiln.Authz.Check do
  @moduledoc """
  Fails when a request-facing module bypasses Ash policies without saying why.

  `authorize?: false` skips *every* policy on the resource — including the
  ones a later PR adds, and including any policy declared below a `bypass`
  (`docs/policy-matrix.md`, "Policy bypasses"). In a row-based multi-tenant
  system that makes each bypass a small piece of the authorization surface
  that no policy block documents. #1309 counted 563 of them; the ones that
  matter most are the ones on request paths, where the caller is a browser or
  an API client rather than a worker.

  This gate does not forbid the bypass — public delivery, pre-auth flows and
  system reads for display data all need it. It forbids an *unexplained* one:
  every `authorize?: false` under `lib/kiln_cms_web/` must sit next to a
  comment that names the bypass and says why it is safe (system read, tenant
  already scoped, action's own filter carries the grant, …). A reviewer then
  reads the reason instead of reconstructing it, and a fresh site cannot land
  by copy-paste alone.

  ## What counts as a justification

  A comment that mentions `authorize?` or `bypass`, placed on any of the 12
  lines above the call that carries the bypass, anywhere inside that call
  (a trailing comment, a comment between its options, or on its closing
  line). The window is measured from the call, not from the option: a long
  keyword list with `authorize?: false` at the bottom is still covered by the
  comment above its head.

  A comment serves **one** site. If another bypass call sits between the
  comment and the site — or the comment is inside another call — it belongs
  to that earlier site, and the later one needs its own. So a second
  `authorize?: false` pasted under a justified one is red until it says why
  it, too, is safe. (Two `authorize?: false` inside the *same* call share the
  call's comment.)

  The scan is AST-based, so the phrase inside a string, a `@moduledoc` or a
  comment is not a site — only the actual `authorize?: false` keyword is. A
  bypass spelled without the literal (`authorize?: flag`,
  `Keyword.put(opts, :authorize?, false)`) is not a site either; those need
  a reader, not this gate.

  ## Scope

  `lib/kiln_cms_web/` by default; pass paths (files or directories) to scan
  something else. Non-web code is not gated yet: the worker/system sites in
  `lib/kiln_cms/` are the "consider a system actor" half of #1309.

      mix kiln.authz.check
      mix kiln.authz.check lib/kiln_cms/billing.ex
  """
  @shortdoc "Fails on an unexplained `authorize?: false` in lib/kiln_cms_web/"

  use Mix.Task

  @default_paths ["lib/kiln_cms_web"]
  @window 12
  @justification ~r/authorize\?|bypass/i

  @impl Mix.Task
  def run(args) do
    paths = if args == [], do: @default_paths, else: args

    violations =
      paths
      |> Enum.flat_map(&source_files/1)
      |> Enum.sort()
      |> Enum.flat_map(fn path -> path |> File.read!() |> unjustified(path) end)

    if violations == [] do
      Mix.shell().info(
        "Authz: every `authorize?: false` under #{Enum.join(paths, ", ")} is justified."
      )
    else
      shell = Mix.shell()

      Enum.each(violations, fn {path, line} ->
        shell.error("#{path}:#{line}: `authorize?: false` without an adjacent justification")
      end)

      Mix.raise("""
      #{length(violations)} unexplained policy bypass(es).

      `authorize?: false` skips every policy on the resource. Either pass the
      request's actor and let the resource's policies decide, or add a comment
      within #{@window} lines above the call (or inside it) that names the
      bypass (mention `authorize?` or `bypass`) and says why it is safe: a
      system read for display data, a tenant already scoped by the router, a
      delivery action whose own filter carries the grant, ... One comment
      covers one call. See #1309.
      """)
    end
  end

  @doc """
  The `{path, line}` of every `authorize?: false` in `source` that has no
  adjacent justification comment. Exposed for tests: this is the part that
  would silently pass on a real bypass if it went wrong.
  """
  @spec unjustified(String.t(), Path.t()) :: [{Path.t(), pos_integer()}]
  def unjustified(source, path \\ "nofile") do
    case Code.string_to_quoted_with_comments(source,
           file: path,
           literal_encoder: &{:ok, {:__block__, &2, [&1]}},
           token_metadata: true
         ) do
      {:ok, ast, comments} ->
        justified = justified_lines(comments)
        sites = sites(ast)

        for site <- sites,
            not Enum.any?(justified, &serves?(&1, site, sites)),
            line <- site.lines,
            do: {path, line}

      {:error, {meta, message, token}} ->
        Mix.raise("#{path}:#{meta[:line]}: cannot parse: #{parse_error(message, token)}")
    end
  end

  # `Code.string_to_quoted` reports some errors as a `{prefix, suffix}` pair
  # around the offending token rather than a plain string.
  defp parse_error({prefix, suffix}, token), do: prefix <> token <> suffix
  defp parse_error(message, token) when is_binary(message), do: message <> token

  # Line numbers of every comment that reads as a justification.
  defp justified_lines(comments) do
    for %{line: line, text: text} <- comments,
        Regex.match?(@justification, text),
        do: line
  end

  # A comment on line `c` justifies `site` when it sits in the site's window
  # (`@window` lines above the call's head through its last line) and no
  # OTHER site claims it first: a bypass call that starts between the comment
  # and this one, or one whose span contains the comment, owns it.
  defp serves?(c, site, sites) do
    c in (site.start - @window)..site.stop and
      not Enum.any?(sites, fn other ->
        other != site and other.start < site.start and c <= other.stop
      end)
  end

  # Every bypass site: the call carrying one or more `authorize?: false`
  # options (`start` = the call's first line, `stop` = its closing line, or
  # the option's line when the call has no closing token), or the bare
  # option itself when it is not an argument of a call (`opts = [authorize?:
  # false]`). `lines` are the option lines, which is what gets reported.
  #
  # With the literal encoder every literal is wrapped in a `:__block__` node
  # carrying its line, so a keyword-list pair `authorize?: false` shows up as
  # `{{:__block__, meta, [:authorize?]}, {:__block__, _, [false]}}`.
  defp sites(ast) do
    {_, {calls, pairs}} =
      Macro.prewalk(ast, {[], []}, fn
        {{:__block__, meta, [:authorize?]}, {:__block__, _, [false]}} = node, {calls, pairs} ->
          {node, {calls, [Keyword.fetch!(meta, :line) | pairs]}}

        {_fun, meta, args} = node, {calls, pairs} when is_list(args) and is_list(meta) ->
          case {meta[:line], bypass_option_lines(args)} do
            {nil, _} -> {node, {calls, pairs}}
            {_, []} -> {node, {calls, pairs}}
            {line, lines} -> {node, {[{line, meta[:closing][:line], lines} | calls], pairs}}
          end

        node, acc ->
          {node, acc}
      end)

    covered = calls |> Enum.flat_map(fn {_, _, lines} -> lines end) |> MapSet.new()

    call_sites =
      for {start, closing, lines} <- calls do
        %{start: start, stop: closing || Enum.max(lines), lines: Enum.sort(lines)}
      end

    bare_sites =
      for line <- Enum.uniq(pairs), line not in covered do
        %{start: line, stop: line, lines: [line]}
      end

    Enum.sort_by(call_sites ++ bare_sites, & &1.start)
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
