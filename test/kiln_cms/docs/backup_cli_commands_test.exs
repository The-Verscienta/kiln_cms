defmodule KilnCMS.Docs.BackupCliCommandsTest do
  @moduledoc """
  Every command `docs/backup-cli.md` shows in a code block parses (#2234):
  each `bin/backup …` and `mix kiln.backup.<command> …` line is a command
  `KilnCMS.Backups.CLI.parse/1` accepts, so the guide never shows a flag the
  CLI refuses or one that was renamed.

  It calls only `parse/1`, which reads and writes nothing: no command is run.
  """
  use ExUnit.Case, async: true

  alias KilnCMS.Backups.CLI

  @doc_path Path.expand("../../../docs/backup-cli.md", __DIR__)
  @external_resource @doc_path

  # The body of every fenced block, whatever its language, indented under a
  # list item or not.
  defp code_blocks do
    ~r/^[ \t]*```[a-z]*\n(.*?)^[ \t]*```/ms
    |> Regex.scan(File.read!(@doc_path), capture: :all_but_first)
    |> Enum.map(fn [body] -> body end)
  end

  # `{line, argv}` for each documented invocation. The argv runs from the
  # command to the end of the line, a trailing `# comment` dropped; no
  # documented command quotes an argument, so splitting on spaces is the
  # shell's split.
  defp invocations do
    for block <- code_blocks(),
        line <- String.split(block, "\n", trim: true),
        argv = argv(line),
        argv != nil,
        do: {line, argv}
  end

  defp argv(line) do
    line = line |> String.split(" #", parts: 2) |> hd() |> String.trim()

    cond do
      match = Regex.run(~r/(?:^|\s)bin\/backup\s+(.*)$/, line, capture: :all_but_first) ->
        split(hd(match))

      match = Regex.run(~r/^mix kiln\.backup\.([a-z]+)(.*)$/, line, capture: :all_but_first) ->
        [command, rest] = match
        [command | split(rest)]

      true ->
        nil
    end
  end

  defp split(text), do: String.split(text, ~r/\s+/, trim: true)

  test "the guide shows commands in code blocks" do
    commands = invocations() |> Enum.map(fn {_line, [command | _]} -> command end)

    for command <- ~w(list run verify prune rescan) do
      assert command in commands, "no code block in the guide runs #{command}"
    end
  end

  test "every documented command parses" do
    for {line, argv} <- invocations() do
      assert {:ok, _command, _args} = CLI.parse(argv),
             "#{inspect(line)} doesn't parse as #{inspect(argv)}: #{inspect(CLI.parse(argv))}"
    end
  end

  test "the guide's command table names every command's flags as the CLI declares them" do
    doc = File.read!(@doc_path)

    for command <- [:list, :run, :verify, :prune, :rescan],
        {flag, _type} <- CLI.switches(command),
        flag != :help do
      flag = "--" <> String.replace(Atom.to_string(flag), "_", "-")

      assert doc =~ ~r/`bin\/backup #{command}[^`]*#{Regex.escape(flag)}/,
             "the guide's row for `bin/backup #{command}` doesn't name #{flag}"
    end
  end
end
