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
  the moduledoc, type the flag, and get "unknown option" or silence. 94 flags
  across 18 of the 28 tasks, at the time of writing.

  The reverse (declared → documented) is deliberately not asserted. It is a
  different and much weaker claim: an undocumented switch still works, whereas
  an undocumented-but-documented one is a lie an operator acts on.

  (An earlier version of this file justified the omission by saying
  `kiln.beta.round` "declares ten and documents one". That was not a fact about
  the task — it documents all ten, in a bullet list the extraction could not
  see. A measurement taken through a broken instrument is worth recording as a
  hazard: the reverse direction may well be worth asserting, and should be
  decided from output that can be trusted.)
  """
  use ExUnit.Case, async: true

  @tasks Path.wildcard("lib/mix/tasks/*.ex")

  # A floor, not an exact count: this test is worthless if the extraction
  # silently stops finding flags, and "0 documented flags, all of them valid"
  # is a green suite. A failure here means the extraction broke, not that a task
  # did.
  #
  # Set close to the real number (94 across 18 of the 28 tasks) rather than
  # comfortably below it, because a slack floor is barely a floor: the first
  # version of this file scanned 74 and the floor of 60 sat happily through
  # three separate extraction bugs that between them hid a fifth of the flags —
  # including every `## Options` bullet list in the repo. Losing any single
  # task's flags should trip this. Raise it when tasks genuinely gain flags.
  @minimum_flags 88

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

    # The case this whole gate exists for, and the one it originally missed. The
    # fixture documents ONLY the underscored spelling: an earlier version also
    # had a bare `--all` in it, which is undeclared for ordinary reasons, and
    # the assertion was satisfied by that — so the test named for #931 passed on
    # a different flag while `--all_orgs` sailed through.
    test "an underscored spelling is caught, which is #931 itself" do
      assert [{"all_orgs", _}] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                     mix fixture --all_orgs
                 """
                 @switches [all_orgs: :boolean]
               end
               ''')
    end

    test "the hyphenated spelling of the same switch is accepted" do
      # The other half — without this, "reject everything with an underscore"
      # would pass the test above and break every correctly-documented task.
      assert [] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                     mix fixture --all-orgs
                 """
                 @switches [all_orgs: :boolean]
               end
               ''')
    end

    test "a `## Options` bullet list is scanned, not just usage blocks" do
      # Heredocs dedent to the closing delimiter, so a bullet written at four
      # spaces arrives at two. An indent threshold that excludes prose also
      # excluded these — seven tasks' Options lists, silently.
      assert [{"bogus", _}] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                 ## Options

                   * `--yes` — confirm.
                   * `--bogus` — undeclared.
                 """
                 @switches [yes: :boolean]
               end
               ''')
    end

    test "an interpolated moduledoc is read, not skipped" do
      # `#{...}` makes the AST node a `{:<<>>, _, parts}` rather than a binary,
      # so a `is_binary/1`-only clause returned "" and the file contributed no
      # flags at all — two real generator tasks were in that hole.
      assert [{"bogus", _}] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @example "x"
                 @moduledoc """
                 Example: #{@example}

                     mix fixture --bogus
                 """
                 @switches [yes: :boolean]
               end
               ''')
    end

    test "Igniter's `schema:` counts as a declaration" do
      # The two generator tasks declare options in `%Igniter.Mix.Task.Info{}`
      # rather than `@switches`. Reading their moduledoc without reading this
      # would report every one of their flags as undeclared.
      assert [] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                     mix fixture --excerpt
                 """
                 def info(_argv, _parent) do
                   %Igniter.Mix.Task.Info{schema: [excerpt: :boolean], aliases: [e: :excerpt]}
                 end
               end
               ''')
    end

    test "an `@aliases` short letter is not a valid long spelling" do
      # `@aliases [o: :out]` means `-o`, never `--o`. Folding its keys into the
      # declared set would accept a moduledoc that wrote `--o`.
      assert [{"o", _}] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                     mix fixture --o
                 """
                 @switches [out: :string]
                 @aliases [o: :out]
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

    for flag <- flags_in(moduledoc(ast), task_name(ast)),
        not declared?(flag, switches),
        do: {flag, switches}
  end

  # The comparison runs in FLAG space, never in key space, and that direction is
  # the whole point. Normalizing the documented flag's `-` to `_` — the obvious
  # way to write this, and how it was written first — maps `--all_orgs` onto
  # `:all_orgs`, finds it declared, and reports no problem. But `OptionParser`
  # translates one way only: `--all-orgs` becomes `:all_orgs`, while `--all_orgs`
  # is an unknown switch. Comparing in key space therefore accepts precisely the
  # spelling that #931 was, which left this gate green on a verbatim
  # reintroduction of the bug it exists to catch.
  #
  # So: a switch `:all_orgs` has exactly one valid spelling, `--all-orgs`, and a
  # documented flag containing `_` can never be valid.
  defp declared?(flag, switches) do
    spellings = MapSet.new(switches, &spelling/1)

    # `OptionParser` synthesizes `--no-x` for any `x: :boolean`, so a documented
    # `--no-redirects` is legal against `redirects:` with no `no_redirects:`
    # anywhere. Matched by name only — the AST walk keeps keys, not types, so a
    # `--no-` prefix on a non-boolean is a different (rarer) mistake than this
    # gate is looking for.
    MapSet.member?(spellings, flag) or
      (String.starts_with?(flag, "no-") and
         MapSet.member?(spellings, String.replace_prefix(flag, "no-", "")))
  end

  defp spelling(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp documented_flags(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()
    flags_in(moduledoc(ast), task_name(ast))
  end

  defp declared_switches(path),
    do: path |> File.read!() |> Code.string_to_quoted!() |> switch_keys()

  # Where tasks actually document flags, measured across all 28 rather than
  # guessed: a `## Options` bullet whose subject is the flag, a line in an
  # options block that starts with the flag, and a `mix …` usage example.
  #
  # NOT "any indented line", which is how this was written first. A heredoc is
  # dedented to its closing delimiter, so a bullet written at four spaces in the
  # source arrives at two — under any indent threshold that also excludes prose.
  # That silently dropped 7 tasks' Options lists (`kiln.beta.round` documents
  # ten flags and one was scanned), and a `--bogus-flag` added to any of them
  # left the gate green.
  #
  # Prose is still excluded, which is the point of matching shapes rather than
  # scanning everything: `kiln.update`'s moduledoc walks the reader through
  # `git fetch --prune` and `--porcelain`, which are git's flags, not its own.
  # A bullet whose subject is a flag, or an options-block line starting with one.
  @flag_line ~r/^\s*(?:[*-]\s+`?--|--)/
  @flag ~r/--([a-z][a-z0-9_-]*)/

  defp flags_in(doc, task) do
    # A usage example counts only when it invokes THIS task. Moduledocs point at
    # sibling tasks — `kiln.promote_data` opens by telling you to run
    # `mix kiln.gen.content --from recipe` — and charging one task with another's
    # flags is a false positive that would train people to edit the gate.
    #
    # `nil` (no recognizable task module) matches no usage line rather than all
    # of them: an empty name interpolates to `mix\s+\b`, which matches every
    # `mix …` line there is, and that is how `--from` above was first reported.
    usage = task && ~r/^\s*mix\s+#{Regex.escape(task)}\b/

    doc
    |> String.split("\n")
    |> Enum.filter(&(Regex.match?(@flag_line, &1) or (usage && Regex.match?(usage, &1))))
    |> Enum.flat_map(&Regex.scan(@flag, &1))
    |> Enum.map(fn [_, flag] -> flag end)
    |> Enum.uniq()
  end

  # `Mix.Tasks.Kiln.Export.Static` → `kiln.export.static`, so the usage rule
  # above works on a fixture string as well as on a real file.
  defp task_name(ast) do
    {_ast, mod} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, nil -> {node, parts}
        node, acc -> {node, acc}
      end)

    case mod do
      [:Mix, :Tasks | rest] when rest != [] ->
        [:Mix, :Tasks | rest] |> Module.concat() |> Mix.Task.task_name()

      _ ->
        nil
    end
  end

  # An interpolated heredoc quotes to `{:<<>>, _, parts}`, not a binary — so a
  # `when is_binary(text)` clause alone silently returns "" and the file
  # contributes no flags at all. Two real tasks are in that hole
  # (`kiln.gen.content`, `kiln.gen.plugin`, both opening with `#{@example}`),
  # and a `--bogus-flag` in either left the gate green. The literal segments are
  # what carry the documentation; the interpolated ones are dropped, which is
  # correct — a flag assembled at compile time is not one a reader can copy.
  defp moduledoc(ast) do
    {_ast, doc} =
      Macro.prewalk(ast, nil, fn
        {:@, _, [{:moduledoc, _, [text]}]} = node, nil when is_binary(text) ->
          {node, text}

        {:@, _, [{:moduledoc, _, [{:<<>>, _, parts}]}]} = node, nil ->
          {node, parts |> Enum.filter(&is_binary/1) |> Enum.join()}

        node, acc ->
          {node, acc}
      end)

    doc || ""
  end

  # Three declaration forms, because the repo uses three:
  #
  #   * a `@switches` module attribute (most tasks)
  #   * a `strict:`/`switches:` list passed straight to `OptionParser` (a few)
  #   * `schema:` inside `%Igniter.Mix.Task.Info{}` (the two generators)
  #
  # `@aliases` is deliberately NOT a source of names. Its keys are the short
  # letters (`o:`, `f:`) and its values are switches already declared above —
  # so folding the keys in adds `--o` and `--f` as "valid" spellings, which can
  # only ever hide a mistake.
  defp switch_keys(ast) do
    {_ast, keys} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:switches, _, [list]}]} = node, acc when is_list(list) ->
          {node, acc ++ keys_of(list)}

        {{:., _, [{:__aliases__, _, [:OptionParser]}, _fun]}, _, args} = node, acc ->
          {node, acc ++ Enum.flat_map(args, &option_list_keys/1)}

        # `%Igniter.Mix.Task.Info{schema: [...]}` — a struct literal, so the
        # keyword list arrives as the struct's field list.
        {:%, _, [_struct, {:%{}, _, fields}]} = node, acc when is_list(fields) ->
          {node, acc ++ option_list_keys(fields)}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(keys)
  end

  defp option_list_keys(opts) when is_list(opts) do
    Enum.flat_map(opts, fn
      {key, list} when key in [:strict, :switches, :schema] and is_list(list) -> keys_of(list)
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
