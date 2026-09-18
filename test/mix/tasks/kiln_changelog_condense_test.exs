defmodule Mix.Tasks.Kiln.ChangelogCondenseTest do
  @moduledoc """
  `mix kiln.changelog --condense` and `--check` run end to end against a
  scratch `CHANGELOG.md`.

  These are the release-cut paths `docs/releasing.md` sends people down, and
  each case is a defect found by running them: an entry in the shape `--check`
  recommends crashed `--condense`, a `### Breaking` list collapsed to its first
  item, two entries sharing a lead lost one long form on the second run, and a
  condensed entry could fail the cap `--condense` exists to meet.

  Not async: the task reads and writes relative paths, so each test changes the
  VM's working directory.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Kiln.Changelog
  alias Mix.Tasks.Kiln.Update

  @moduletag :tmp_dir

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp write_changelog!(dir, body) do
    File.write!(Path.join(dir, "CHANGELOG.md"), "# Changelog\n\n" <> body)
  end

  defp condense!(dir), do: File.cd!(dir, fn -> Changelog.run(["--condense"]) end)
  defp check!(dir), do: File.cd!(dir, fn -> Changelog.run(["--check"]) end)
  defp verify!(dir, ref), do: File.cd!(dir, fn -> Changelog.run(["--verify", ref]) end)
  defp read!(dir, path), do: File.read!(Path.join(dir, path))

  defp commit!(dir, subject) do
    for args <- [~w[add -A], ~w[-c user.name=t -c user.email=t@t commit -qm] ++ [subject]] do
      {_out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    end
  end

  defp write_archive!(dir, body) do
    File.mkdir_p!(Path.join(dir, "docs/changelog"))

    File.write!(
      Path.join(dir, "docs/changelog/v0.9.0.md"),
      "# KilnCMS 0.9.0 — full release notes\n\n" <> body
    )
  end

  # Everything --condense writes, so "a second run changes nothing" is one `==`.
  # Globbed relative to `dir`, since the tmp_dir path is built from the test
  # name and can contain glob syntax.
  defp snapshot(dir) do
    File.cd!(dir, fn ->
      ["CHANGELOG.md" | Path.wildcard("docs/**/*.md")]
      |> Map.new(&{&1, File.read!(&1)})
    end)
  end

  defp summary_lines(changelog, needle) do
    changelog
    |> String.split("\n\n")
    |> Enum.find(&String.contains?(&1, needle))
    |> String.split("\n")
    |> Enum.reject(&String.match?(&1, ~r/^\s*\(\[(?:#\d+|long form)\]\(/))
  end

  test "an entry written the way --check recommends condenses, twice", %{tmp_dir: dir} do
    write_changelog!(dir, """
    ## [Unreleased]

    ### Fixed

    - **Short fix.** ([#12](https://github.com/The-Verscienta/kiln_cms/issues/12))

    - **Long form with a link.** See
      [#40](https://github.com/The-Verscienta/kiln_cms/issues/40) for the history.
    """)

    condense!(dir)
    first = snapshot(dir)
    condense!(dir)

    assert snapshot(dir) == first
    assert read!(dir, "CHANGELOG.md") =~ "- **Short fix.**"
    assert read!(dir, "docs/changelog/unreleased.md") =~ "for the history."
    check!(dir)
  end

  test "a Breaking list keeps one summary per item", %{tmp_dir: dir} do
    write_changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Breaking

    - `POST /api/a` answers 200 where it answered 201.
    - `POST /api/b` now requires a `code` field.
    """)

    condense!(dir)
    changelog = read!(dir, "CHANGELOG.md")

    refute changelog =~ "- - "
    # What an operator moving the pin is shown, which is the point of the section.
    [{_, [{"Breaking", printed}]}] =
      Update.upgrade_notes(changelog, Version.parse!("0.8.0"), Version.parse!("0.9.0"))

    assert printed =~ "`POST /api/a` answers 200"
    assert printed =~ "`POST /api/b` now requires"
  end

  test "a list inside a bold-lead note stays with that note", %{tmp_dir: dir} do
    write_changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Upgrade notes

    **Check the endpoint.** Two smaller contract notes:

    - Errors carry a stable `code`.
    - Send `code` as a string.
    """)

    condense!(dir)
    changelog = read!(dir, "CHANGELOG.md")

    assert changelog =~ "**Check the endpoint.**"
    refute changelog =~ "Errors carry a stable"
    assert read!(dir, "docs/changelog/v0.9.0.md") =~ "Errors carry a stable `code`."
  end

  test "entries sharing a lead keep their own long forms across runs", %{tmp_dir: dir} do
    write_changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Fixed

    - **Typo fixes.** The editor toolbar
      said "Bodl" instead of "Bold".

    - **Typo fixes.** The sign-in page
      said "Pasword" instead of "Password".

    ### Security

    - **Typo fixes.** The audit log
      said "Adit" instead of "Audit".
    """)

    condense!(dir)
    first = snapshot(dir)
    condense!(dir)
    archive = read!(dir, "docs/changelog/v0.9.0.md")

    assert snapshot(dir) == first

    assert ~w(typo-fixes typo-fixes-1 typo-fixes-2) ==
             ~r/<a id="([^"]+)"/ |> Regex.scan(archive) |> Enum.map(&List.last/1)

    for word <- ~w(Bodl Pasword Adit), do: assert(archive =~ word)
    check!(dir)
  end

  # Two summaries naming one anchor was green under `--check` and only failed
  # the *second* `--condense` — the archive by then held two blocks under one
  # `<a id>`, in a file nobody had edited by hand, and whoever condensed next
  # inherited it. So the rule reads the summaries, where the fix is one link.
  test "two summaries linking one long form fail --check", %{tmp_dir: dir} do
    write_changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Upgrade notes

    - **Existing accounts keep the sidebar they had.**
      ([long form](docs/changelog/v0.9.0.md#sidebar-presets))

    ### Added

    - **Sidebar presets.**
      ([long form](docs/changelog/v0.9.0.md#sidebar-presets))
    """)

    write_archive!(dir, """
    ## Added

    <a id="sidebar-presets"></a>

    - **Sidebar presets.** Each user picks one.

      **Upgrading:** the column backfills to the sidebar the account had.
    """)

    assert_raise Mix.Error, fn -> check!(dir) end
    assert_received {:mix_shell, :error, [message]}
    assert message =~ "2 summaries link the same long form"
    assert message =~ "docs/changelog/v0.9.0.md#sidebar-presets"
    assert message =~ "under Upgrade notes, Added"
  end

  # The fix that rule asks for: the upgrade note gets an anchor and a block of
  # its own, and the pair then survives the runs the shared anchor could not.
  test "a long form per summary condenses twice and passes --check", %{tmp_dir: dir} do
    write_changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Upgrade notes

    - **Existing accounts keep the sidebar they had.**
      ([long form](docs/changelog/v0.9.0.md#sidebar-presets-upgrading))

    ### Added

    - **Sidebar presets.**
      ([long form](docs/changelog/v0.9.0.md#sidebar-presets))
    """)

    write_archive!(dir, """
    ## Upgrade notes

    <a id="sidebar-presets-upgrading"></a>

    **Upgrading:** the column backfills to the sidebar the account had.

    ## Added

    <a id="sidebar-presets"></a>

    - **Sidebar presets.** Each user picks one.
    """)

    check!(dir)
    condense!(dir)
    first = snapshot(dir)
    condense!(dir)

    assert snapshot(dir) == first
    check!(dir)

    archive = read!(dir, "docs/changelog/v0.9.0.md")
    assert archive =~ "backfills to the sidebar the account had"
    assert archive =~ "Each user picks one."
  end

  # With no pull request to link, a summary still has to link somewhere, or
  # `--check` fails what `--condense` wrote.
  test "an entry with no reference links its long form", %{tmp_dir: dir} do
    write_changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Fixed

    - A single sentence with no reference of its own.
    """)

    condense!(dir)

    assert read!(dir, "CHANGELOG.md") =~ "[long form](docs/changelog/v0.9.0.md#"
    check!(dir)
  end

  # The release-cut order `docs/releasing.md` gives: `--condense`, then
  # `--verify`. A summary condensed before its merge had a number gets the pull
  # request on the next run, beside its long-form link. That is navigation, not
  # prose, so `--verify` must not read it as a lost paragraph — and must still
  # catch a sentence dropped from the long form.
  test "--verify accepts a pull request --condense attributed, not a dropped sentence",
       %{tmp_dir: dir} do
    write_changelog!(dir, """
    ## [Unreleased]

    ### Added

    - **Widget export writes one file per locale.** Each locale gets its own file,
      so a translator can take one without the others.
    """)

    condense!(dir)
    {_out, 0} = System.cmd("git", ~w[init -q], cd: dir, stderr_to_stdout: true)
    commit!(dir, "Add widget export (#1450)")
    assert read!(dir, "CHANGELOG.md") =~ "\n  ([long form](docs/changelog/unreleased.md#"

    condense!(dir)

    assert read!(dir, "CHANGELOG.md") =~
             "([#1450](https://github.com/The-Verscienta/kiln_cms/issues/1450) · [long form]("

    verify!(dir, "HEAD")
    assert_received {:mix_shell, :info, ["No loss: " <> _]}

    archive = "docs/changelog/unreleased.md"

    File.write!(
      Path.join(dir, archive),
      String.replace(read!(dir, archive), "so a translator", "")
    )

    assert_raise Mix.Error, ~r/1 paragraph\(s\) .* no destination/, fn -> verify!(dir, "HEAD") end
  end

  describe "the Unreleased cap after --condense" do
    test "a three-line opening passes, since the links line is not prose", %{tmp_dir: dir} do
      lead = "**" <> String.trim(String.duplicate("word ", 38)) <> ".**"

      write_changelog!(dir, """
      ## [Unreleased]

      ### Fixed

      - #{lead} Then
        the reasoning follows.
      """)

      condense!(dir)

      assert length(summary_lines(read!(dir, "CHANGELOG.md"), "word word")) == 3
      check!(dir)
    end

    # --condense never rewrites the author's opening, so its advice has to
    # change once there is nothing left for it to move.
    test "a longer opening fails, and says to shorten the lead", %{tmp_dir: dir} do
      lead = "**" <> String.trim(String.duplicate("word ", 70)) <> ".**"

      write_changelog!(dir, """
      ## [Unreleased]

      ### Fixed

      - #{lead} Then
        the reasoning follows.
      """)

      condense!(dir)

      assert_raise Mix.Error, fn -> check!(dir) end
      assert_received {:mix_shell, :error, [message]}
      assert message =~ "Shorten the bold lead"
    end
  end
end
