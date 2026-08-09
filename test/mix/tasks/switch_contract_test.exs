defmodule Mix.Tasks.SwitchContractTest do
  @moduledoc """
  Every `--flag` a `mix kiln.*` task documents must actually parse (#1088).

  ## Why this is a gate and not a grep

  #931 was `mix kiln.export.static` declaring `org_id:`/`all_orgs:` and
  documenting them with underscores. `OptionParser` only understands hyphenated
  switch names — it normalizes `-` to `_`, never the reverse — so `--all_orgs`
  was an *unknown* switch, silently discarded by `parse/2`, and a fleet export
  quietly exported one site and reported success.

  Its fix note said "worth grepping the other tasks for the same pattern". The
  grep found **two more live instances**:

    * `kiln.import.wordpress` documented `--drain-media` and read
      `opts[:drain_media]`, but never declared the switch
    * `kiln.import.content` documented `--type NAME`, read `opts[:type]`, and
      never declared it — so the "required for a CSV import" error below the
      read was unreachable

  Three instances in three tasks is a missing gate, not a coincidence. Per-task
  tests could not have caught them: only 7 of #{length(Path.wildcard("lib/mix/tasks/*.ex"))}
  tasks have a test file at all, and the two that pin this class are the two
  that had already been looked at.

  ## What is checked, and what is not

  Documented → declared, which is the direction that breaks operators: they read
  the moduledoc, type the flag, and get "unknown option" or silence.

  The reverse (declared → documented) is deliberately not asserted. It is a
  different and much weaker claim — several tasks declare internal or
  rarely-useful switches on purpose (`kiln.beta.round` declares ten and
  documents one) — so it would be a wall of noise around a real signal.
  """
  use ExUnit.Case, async: true

  @tasks Path.wildcard("lib/mix/tasks/*.ex")

  # A floor, not an exact count: this test is worthless if the extraction
  # silently stops finding flags, and "0 documented flags, all of them valid"
  # is a green suite. Raise it when the real number moves well past it; a
  # failure here means the extraction broke, not that a task did.
  @minimum_flags 60

  describe "every documented flag parses" do
    test "the moduledoc's flags are all declared switches" do
      problems =
        for path <- @tasks,
            {flag, switches} <- undeclared(path) do
          "#{path}: moduledoc documents --#{flag}, which is not in @switches " <>
            "(declared: #{inspect(switches)})"
        end

      assert problems == [],
             """
             A documented flag does not parse. `OptionParser` normalizes `-` to
             `_` and never the reverse, so a switch declared `foo_bar:` is typed
             `--foo-bar`; a flag the moduledoc shows but @switches omits is an
             unknown option at runtime (#931, #1088).

             #{Enum.join(problems, "\n")}
             """
    end

    test "the sweep actually reads a meaningful number of flags" do
      # Guards the guard. Every mechanism here — locating the moduledoc, finding
      # the indented usage blocks, walking the AST for `@switches` — can fail
      # open and turn the assertion above into a tautology.
      counted = Enum.sum(for path <- @tasks, do: length(documented_flags(path)))

      assert counted >= @minimum_flags,
             "only #{counted} documented flags found across #{length(@tasks)} tasks; " <>
               "the extraction in this file has probably stopped working"
    end

    test "at least one task declares switches at all" do
      assert Enum.any?(@tasks, &(declared_switches(&1) != []))
    end
  end

  # The extraction is regex-and-AST over source, so it has its own failure modes.
  # These pin them against fixtures rather than against the repo, which changes.
  describe "the checker itself" do
    test "it catches a documented flag that is not declared" do
      assert [{"drain-media", [:dry_run]}] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                 Usage:

                     mix fixture --dry-run --drain-media
                 """
                 @switches [dry_run: :boolean]
               end
               ''')
    end

    test "an underscored spelling is caught, which is #931 itself" do
      assert [{"all", _}] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                     mix fixture --all_orgs --all
                 """
                 @switches [all_orgs: :boolean]
               end
               ''')
    end

    test "`--no-x` is legal against a boolean `x`, because OptionParser synthesizes it" do
      assert [] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                     mix fixture --no-redirects
                 """
                 @switches [redirects: :boolean]
               end
               ''')
    end

    test "flags quoted in prose are ignored, only indented usage blocks count" do
      # `kiln.update`'s moduledoc discusses git's own flags in prose. Scanning
      # the whole moduledoc reported every one of them as undeclared.
      assert [] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                 It runs `git fetch --prune` and inspects `--porcelain` output.
                 """
                 @switches [check: :boolean]
               end
               ''')
    end

    test "switches declared inline on OptionParser.parse! count too" do
      # Several tasks skip the `@switches` attribute and pass the list directly.
      assert [] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                     mix fixture --into DIR
                 """
                 def run(argv), do: OptionParser.parse!(argv, strict: [into: :string])
               end
               ''')
    end
  end

  # ── extraction ──────────────────────────────────────────────────────────────

  defp undeclared(path), do: path |> File.read!() |> undeclared_in()

  defp undeclared_in(source) do
    ast = Code.string_to_quoted!(source)
    switches = switch_keys(ast)

    for flag <- flags_in(moduledoc(ast)), not declared?(flag, switches), do: {flag, switches}
  end

  defp declared?(flag, switches) do
    key = flag |> String.replace("-", "_") |> String.to_atom()

    # `OptionParser` synthesizes `--no-x` for any `x: :boolean`, so a documented
    # `--no-redirects` is legal against `redirects:` with no `no_redirects:`
    # anywhere. Checked by name only — the AST walk keeps keys, not types, and a
    # `--no-` prefix on a non-boolean is a different (rarer) mistake.
    negated = flag |> String.replace_prefix("no-", "") |> String.replace("-", "_")

    key in switches or (String.starts_with?(flag, "no-") and String.to_atom(negated) in switches)
  end

  defp documented_flags(path),
    do: path |> File.read!() |> Code.string_to_quoted!() |> moduledoc() |> flags_in()

  defp declared_switches(path),
    do: path |> File.read!() |> Code.string_to_quoted!() |> switch_keys()

  # Only indented blocks — the usage/options listings. A moduledoc's prose
  # legitimately mentions other tools' flags (`kiln.update` walks through
  # `git fetch --prune`), and scanning it whole reported all of them.
  defp flags_in(doc) do
    doc
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(~r/^ {4,}\S/, &1))
    |> Enum.flat_map(&Regex.scan(~r/--([a-z][a-z0-9_-]*)/, &1))
    |> Enum.map(fn [_, flag] -> flag end)
    |> Enum.uniq()
  end

  defp moduledoc(ast) do
    {_ast, doc} =
      Macro.prewalk(ast, nil, fn
        {:@, _, [{:moduledoc, _, [text]}]} = node, nil when is_binary(text) -> {node, text}
        node, acc -> {node, acc}
      end)

    doc || ""
  end

  # `@switches`/`@aliases` attributes, plus any `strict:`/`switches:`/`aliases:`
  # list handed straight to an `OptionParser` call.
  defp switch_keys(ast) do
    {_ast, keys} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{name, _, [list]}]} = node, acc
        when name in [:switches, :aliases] and is_list(list) ->
          {node, acc ++ keys_of(list)}

        {{:., _, [{:__aliases__, _, [:OptionParser]}, _fun]}, _, args} = node, acc ->
          {node, acc ++ Enum.flat_map(args, &option_list_keys/1)}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(keys)
  end

  defp option_list_keys(opts) when is_list(opts) do
    Enum.flat_map(opts, fn
      {key, list} when key in [:strict, :switches, :aliases] and is_list(list) -> keys_of(list)
      _ -> []
    end)
  end

  defp option_list_keys(_), do: []

  defp keys_of(list) do
    Enum.flat_map(list, fn
      {key, _type} when is_atom(key) -> [key]
      _ -> []
    end)
  end
end
