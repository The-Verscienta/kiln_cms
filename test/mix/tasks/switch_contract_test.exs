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
  the moduledoc, type the flag, and get "unknown option" or silence. 183
  distinct flags across 45 of the 58 tasks, at the time of writing (94 across
  18 of 28 when this gate read moduledocs only).

  A flag is charged to the task that runs it, not the file it is written in
  (#2733). `kiln.gen.plugin`'s notice told users to run
  `mix kiln.gen.content <Type> --domain …`, a switch `kiln.gen.content` has
  never had, and this gate could not see it twice over: it read moduledocs
  only, never the notices tasks print, and it skipped any `mix` command that
  ran a different task. It now reads every string literal in every task, and
  checks each `mix <task> --flag` against `<task>`'s switches.

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
  # Set close to the real number rather than comfortably below it, because a
  # slack floor is barely a floor: the first version of this file scanned 74
  # and the floor of 60 sat happily through three separate extraction bugs that
  # between them hid a fifth of the flags — including every `## Options` bullet
  # list in the repo. Losing any single task's flags should trip this. Raise it
  # when tasks genuinely gain flags.
  #
  # The real number was 94 while only moduledocs were read; reading every
  # string literal and every task's commands (#2733) made it 187 `{task, flag}`
  # pairs, counted once per file that documents them.
  @minimum_flags 180

  describe "every documented flag parses" do
    test "every flag a task's text documents is a declared switch of the task it runs" do
      known = known_switches()

      problems =
        for path <- @tasks,
            {task, flag, switches} <- undeclared(path, known) do
          "#{path}: documents `mix #{task} --#{flag}`, and #{task} does not declare it " <>
            "(declared: #{inspect(switches)})"
        end

      assert problems == [],
             """
             A documented flag does not parse. `OptionParser` normalizes `-` to
             `_` and never the reverse, so a switch declared `foo_bar:` is typed
             `--foo-bar`; a flag the text shows but the task omits is an
             unknown option at runtime (#931, #1088, #2733).

             #{Enum.join(problems, "\n")}
             """
    end

    test "the sweep actually reads a meaningful number of flags" do
      # Guards the guard. Every mechanism here — locating the moduledoc, finding
      # the command lines, walking the AST for `@switches` — can fail open and
      # turn the assertion above into a tautology.
      known = known_switches()
      counted = Enum.sum(for path <- @tasks, do: length(documented_flags(path, known)))

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
      assert [{"fixture", "drain-media", [:dry_run]}] =
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
      assert [{"fixture", "all_orgs", _}] =
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
      assert [{"fixture", "bogus", _}] =
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
      assert [{"fixture", "bogus", _}] =
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
      assert [{"fixture", "o", _}] =
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

    test "other commands' flags quoted in prose are ignored" do
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

    test "a sibling task's flag in a notice is checked against the sibling (#2733)" do
      # The shape of #2733: a notice string, not the moduledoc, naming another
      # task mid-line. The flag is the sibling's to declare, not this task's.
      assert [{"kiln.sibling", "domain", [:from]}] =
               undeclared_in(
                 ~S'''
                 defmodule Mix.Tasks.Fixture do
                   @moduledoc "Generates things."
                   @switches [domain: :string]

                   defp notice(camel) do
                     """
                     Next:
                       * Content types: mix kiln.sibling <Type> --domain #{camel}.Catalog,
                         then register it.
                     """
                   end
                 end
                 ''',
                 %{"kiln.sibling" => [:from]}
               )
    end

    test "a command between backticks in prose is checked, up to the closing one" do
      known = %{"kiln.sibling" => [:from]}

      assert [{"kiln.sibling", "nope", _}] =
               undeclared_in(
                 ~S'''
                 defmodule Mix.Tasks.Fixture do
                   @moduledoc """
                   Run `mix kiln.sibling --from recipe`.
                   Or `mix kiln.sibling --nope`, after git's `--elsewhere` is set.
                   """
                 end
                 ''',
                 known
               )
    end

    test "a command ends at a shell comment" do
      # `--bogus` is in the comment after the command, and is not its flag.
      assert [] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                     mix fixture --yes   # then pass --bogus to something else
                 """
                 @switches [yes: :boolean]
               end
               ''')
    end

    test "a task the repo does not have is not this gate's business" do
      assert [] =
               undeclared_in(~S'''
               defmodule Mix.Tasks.Fixture do
                 @moduledoc """
                 Then run `mix ash.codegen --check` and `mix test --only slow`.
                 """
               end
               ''')
    end

    # The gate against the real file, with #2733's line put back in each of the
    # two places it stood. A fixture proves the regex can match that shape;
    # this proves the scan reaches the notice and the moduledoc of the actual
    # task, which is what was missing.
    test "reinstating #2733's --domain line in kiln.gen.plugin fails the gate" do
      path = "lib/mix/tasks/kiln.gen.plugin.ex"
      source = File.read!(path)
      known = known_switches()

      assert undeclared_in(source, known) == []

      for {current, old} <- [
            {"* Content types: mix kiln.gen.content can't write them into a plugin's",
             "* Content types: mix kiln.gen.content <Type> --domain \#{camel}.Catalog,"},
            {"Content types come next, and no generator writes them into a plugin's",
             "Content types come next: `mix kiln.gen.content <Type> --domain <Plugin>.Catalog`"}
          ] do
        mutated = String.replace(source, current, old)
        assert mutated != source, "the anchor #{inspect(current)} is gone from #{path}"

        assert [{"kiln.gen.content", "domain", _}] = undeclared_in(mutated, known)
      end
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

  # Every task's declared switches, by task name, so a flag one task's text
  # documents for ANOTHER task can be checked against that task (#2733).
  defp known_switches do
    Map.new(@tasks, fn path ->
      ast = path |> File.read!() |> Code.string_to_quoted!()
      {task_name(ast), switch_keys(ast)}
    end)
  end

  defp undeclared(path, known), do: path |> File.read!() |> undeclared_in(known)

  # `{task, flag, task's switches}` for each flag this source documents that
  # its task does not declare. `known` maps other task names to their switches;
  # a reference to a task outside it (`mix ash.codegen --check`, `mix test`)
  # is not this gate's business and is skipped.
  defp undeclared_in(source, known \\ %{}) do
    ast = Code.string_to_quoted!(source)
    own = task_name(ast)
    switches = Map.put(known, own, switch_keys(ast))

    for {task, flag} <- documented_in(ast, own),
        Map.has_key?(switches, task),
        not declared?(flag, switches[task]),
        do: {task, flag, switches[task]}
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

  # The `{task, flag}` pairs one file documents for the repo's tasks, which is
  # what the floor counts.
  defp documented_flags(path, known) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    for {task, _flag} = pair <- documented_in(ast, task_name(ast)),
        Map.has_key?(known, task),
        do: pair
  end

  defp declared_switches(path),
    do: path |> File.read!() |> Code.string_to_quoted!() |> switch_keys()

  # Where tasks actually document flags, measured across the repo rather than
  # guessed: a `## Options` bullet whose subject is the flag, a line in an
  # options block that starts with the flag, and a `mix …` command line.
  #
  # The first two belong to the task whose moduledoc they are in. A command
  # line belongs to the task it runs, wherever it is written: in a moduledoc,
  # after a backtick in prose, or in a notice the task prints. Moduledocs and
  # notices point at sibling tasks — `kiln.promote_data` opens by telling you to
  # run `mix kiln.gen.content --from recipe`, and `kiln.gen.plugin`'s notice
  # once told you to run `mix kiln.gen.content <Type> --domain …`, a switch
  # `kiln.gen.content` has never had (#2733). Charging the sibling's flag to
  # the task that mentions it was a false positive; skipping it, as this did
  # until #2733, was a false negative.
  defp documented_in(ast, own) do
    bullets = for flag <- bullet_flags(moduledoc(ast)), do: {own, flag}
    commands = for text <- string_literals(ast), pair <- command_flags(text), do: pair
    Enum.uniq(bullets ++ commands)
  end

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

  defp bullet_flags(doc) do
    doc
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(@flag_line, &1))
    |> Enum.flat_map(&Regex.scan(@flag, &1))
    |> Enum.map(fn [_, flag] -> flag end)
  end

  # `mix <task> <args>`, anywhere on a line. The args run until whatever ends
  # a command in text: a closing backtick, the end of the line, a shell `#`
  # comment (`mix kiln.x --a   # then pass --b to y` documents only `--a`), a
  # `|`, `;` or `&&`, or the next `mix`.
  @command ~r/\bmix\s+([a-z]\w*(?:\.\w+)*)((?:(?!\bmix\s)[^`#\n|;&])*)/

  defp command_flags(text) do
    for [_, task, args] <- Regex.scan(@command, text),
        [_, flag] <- Regex.scan(@flag, args),
        do: {task, flag}
  end

  # Every string literal in the source: moduledocs, `@doc`s, module attributes
  # and the notices and messages a task prints. An interpolated string is its
  # literal segments with a placeholder where each `#{…}` was, which keeps the
  # segments either side of it apart: `--domain #{camel}.Catalog` reads as
  # `--domain … .Catalog`. The interpolated expressions are walked too, since a
  # notice can hold strings inside them (`#{if block, do: "…"}`).
  @interpolation " … "

  defp string_literals(ast) do
    {_ast, texts} =
      Macro.prewalk(ast, [], fn
        text, acc when is_binary(text) ->
          {text, [text | acc]}

        {:<<>>, _, parts}, acc ->
          text = Enum.map_join(parts, &if(is_binary(&1), do: &1, else: @interpolation))
          exprs = Enum.reject(parts, &is_binary/1)
          {{:__block__, [], exprs}, [text | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(texts)
  end

  # `Mix.Tasks.Kiln.Export.Static` → `kiln.export.static`: the name a command
  # line uses, so a fixture string's flags are charged as a real file's are.
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
