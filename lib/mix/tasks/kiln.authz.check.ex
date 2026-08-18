defmodule Mix.Tasks.Kiln.Authz.Check do
  @moduledoc """
  Fails when a request-facing module bypasses Ash policies without saying why.

  `authorize?: false` skips *every* policy on the resource — including the
  ones a later PR adds, and including any policy declared below a `bypass`
  (see the "Ash bypass skips every policy below" note in the memory index).
  In a row-based multi-tenant system that makes each bypass a small piece of
  the authorization surface that no policy block documents. #1309 counted 563
  of them; the ones that matter most are the ones on request paths, where the
  caller is a browser or an API client rather than a worker.

  This gate does not forbid the bypass — public delivery, pre-auth flows and
  system reads for display data all need it. It forbids an *unexplained* one:
  every `authorize?: false` under `lib/kiln_cms_web/` must sit next to a
  comment that names the bypass and says why it is safe (system read, tenant
  already scoped, action's own filter carries the grant, …). A reviewer then
  reads the reason instead of reconstructing it, and a fresh site cannot land
  by copy-paste alone.

  ## What counts as a justification

  A comment that mentions `authoriz…` (authorize, authorized, authorization)
  or `bypass`, either trailing on the same line as the bypass or on any of
  the 12 lines above it. The distance is generous enough for a multi-line
  keyword list (`authorize?: false` several lines below the call it belongs
  to) and tight enough that a paragraph about something else, further up,
  does not count.

  The scan is AST-based, so the phrase inside a string, a `@moduledoc` or a
  comment is not a site — only the actual `authorize?: false` keyword is.

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
  @justification ~r/authori[sz]|bypass/i

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
      within #{@window} lines above the bypass (or trailing on its line) that
      names it (mention `authorize` or `bypass`) and says why it is safe:
      a system read for display data, a tenant already scoped by the router,
      a delivery action whose own filter carries the grant, ... See #1309.
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

        ast
        |> bypass_lines()
        |> Enum.reject(fn line -> Enum.any?(justified, &(&1 in (line - @window)..line)) end)
        |> Enum.map(&{path, &1})

      {:error, {meta, message, token}} ->
        Mix.raise("#{path}:#{meta[:line]}: cannot parse: #{message}#{token}")
    end
  end

  # Line numbers of every comment that reads as a justification. A trailing
  # comment shares its line with the code it annotates, which is why the
  # window is inclusive of the bypass line itself.
  defp justified_lines(comments) do
    for %{line: line, text: text} <- comments,
        Regex.match?(@justification, text),
        do: line
  end

  # With the literal encoder every literal is wrapped in a `:__block__` node
  # carrying its line, so a keyword-list pair `authorize?: false` shows up as
  # `{{:__block__, meta, [:authorize?]}, {:__block__, _, [false]}}`.
  defp bypass_lines(ast) do
    {_, lines} =
      Macro.prewalk(ast, [], fn
        {{:__block__, meta, [:authorize?]}, {:__block__, _, [false]}} = node, acc ->
          {node, [Keyword.fetch!(meta, :line) | acc]}

        node, acc ->
          {node, acc}
      end)

    lines |> Enum.uniq() |> Enum.sort()
  end

  defp source_files(path) do
    cond do
      File.dir?(path) -> Path.wildcard(Path.join(path, "**/*.{ex,exs}"))
      File.exists?(path) -> [path]
      true -> Mix.raise("#{path}: no such file or directory")
    end
  end
end
