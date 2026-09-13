defmodule Mix.Tasks.Kiln.ChangelogReviewTest do
  @moduledoc """
  Regression cases for `mix kiln.changelog` found by a maximum-effort review of
  the condense/check/verify fixes. Each test is a reproduced failure: an input
  where `--condense` lost text, collapsed a note, misattributed an entry, or
  where a gate reported "no loss" after a loss.

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

  defp write!(dir, path, body) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
  end

  defp changelog!(dir, body), do: write!(dir, "CHANGELOG.md", "# Changelog\n\n" <> body)
  defp read!(dir, path), do: File.read!(Path.join(dir, path))
  defp run!(dir, args), do: File.cd!(dir, fn -> Changelog.run(args) end)
  defp condense!(dir), do: run!(dir, ["--condense"])

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp commit!(dir, subject) do
    git!(dir, ~w[add -A])
    git!(dir, ~w[-c user.name=t -c user.email=t@t commit -qm] ++ [subject])
  end

  defp snapshot(dir) do
    File.cd!(dir, fn ->
      Map.new(["CHANGELOG.md" | Path.wildcard("docs/**/*.md")], &{&1, File.read!(&1)})
    end)
  end

  defp printed(changelog, from, to) do
    changelog
    |> Update.upgrade_notes(Version.parse!(from), Version.parse!(to))
    |> Enum.flat_map(fn {_version, blocks} -> blocks end)
    |> Enum.map_join("\n", fn {_name, body} -> body end)
  end

  # The links line is wider than the file's 80 columns; an editor fill splits
  # its label, and the summary must still read as condensed.
  test "a reflowed long-form link keeps its long form", %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Fixed

    - **Scheduled publishes survive a node restart.** The Oban job was enqueued
      with a unique period shorter than the delay, so a restart dropped it (#1392).
    """)

    condense!(dir)

    reflowed =
      dir
      |> read!("CHANGELOG.md")
      |> String.replace(" · [long form](", " · [long\n  form](")

    write!(dir, "CHANGELOG.md", reflowed)
    condense!(dir)

    assert read!(dir, "docs/changelog/v0.9.0.md") =~ "shorter than the delay"
  end

  test "a summary whose long-form link was deleted by hand does not replace the long form",
       %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Fixed

    - **Scheduled publishes survive a node restart.** The Oban job was enqueued
      with a unique period shorter than the delay, so a restart dropped it (#1392).
    """)

    condense!(dir)

    edited =
      dir
      |> read!("CHANGELOG.md")
      |> String.replace(~r/ · \[long form\]\([^)]*\)/, "")

    write!(dir, "CHANGELOG.md", edited)
    condense!(dir)

    assert read!(dir, "docs/changelog/v0.9.0.md") =~ "shorter than the delay"
    assert read!(dir, "CHANGELOG.md") =~ "[long form](docs/changelog/v0.9.0.md#"
  end

  test "a Breaking bullet keeps an unindented continuation line", %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Breaking

    - `POST /api/a` answers 200 where it answered 201. Clients that
    check for 201 must accept 200.
    - `POST /api/b` now requires a `code` field.
    """)

    condense!(dir)

    assert read!(dir, "docs/changelog/v0.9.0.md") =~ "check for 201 must accept 200."
    assert printed(read!(dir, "CHANGELOG.md"), "0.8.0", "0.9.0") =~ "`POST /api/b`"
  end

  test "a note added above a rendered bullet note does not swallow it", %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Breaking

    **Everyone is signed out once on deploy.** (#686)
    """)

    condense!(dir)

    with_new_note =
      dir
      |> read!("CHANGELOG.md")
      |> String.replace(
        "### Breaking\n\n",
        "### Breaking\n\n**Set `WIDGET_KEY` before deploying.** The widget refuses to boot without it (#1500).\n\n"
      )

    write!(dir, "CHANGELOG.md", with_new_note)
    condense!(dir)

    shown = printed(read!(dir, "CHANGELOG.md"), "0.8.0", "0.9.0")
    assert shown =~ "Everyone is signed out once on deploy."
    assert shown =~ "Set `WIDGET_KEY` before deploying."
  end

  test "an indented sub-list stays inside its bullet note", %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Breaking

    - **Sign-in answers `200`.** Clients must: (#726)

      - accept 200 as success
      - stop treating 201 as the only success code
    """)

    condense!(dir)
    shown = printed(read!(dir, "CHANGELOG.md"), "0.8.0", "0.9.0")

    refute shown =~ "accept 200 as success"
    assert read!(dir, "docs/changelog/v0.9.0.md") =~ "  - accept 200 as success"
  end

  test "an indented code block in an upgrade note is archived intact", %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Upgrade notes

    **Pin the embedder origins.** Set both before deploying:

        EMBED_ORIGINS=https://a.example
        KILN_OTHER=1
    """)

    condense!(dir)

    assert read!(dir, "docs/changelog/v0.9.0.md") =~ "    EMBED_ORIGINS=https://a.example"
  end

  test "an indented paragraph followed directly by the next bullet keeps both notes",
       %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Breaking

    - **A changed.** First. (#1)

      More about A.
    - **B changed.** Second. (#2)
    """)

    condense!(dir)
    shown = printed(read!(dir, "CHANGELOG.md"), "0.8.0", "0.9.0")

    assert shown =~ "A changed."
    assert shown =~ "B changed."
  end

  test "a same-lead entry added above an unshortened one leaves its archive text alone",
       %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Changed

    - **Dependency updates across the umbrella apps.** (#1502)
    """)

    condense!(dir)

    with_new =
      dir
      |> read!("CHANGELOG.md")
      |> String.replace(
        "### Changed\n\n",
        "### Changed\n\n- **Dependency updates across the umbrella apps.** Phoenix 1.8.1 and\n  Ash 3.5.4 (#1510).\n\n"
      )

    write!(dir, "CHANGELOG.md", with_new)
    condense!(dir)

    assert read!(dir, "docs/changelog/v0.9.0.md") =~
             "- **Dependency updates across the umbrella apps.** (#1502)"
  end

  test "a summary linking another entry's long form keeps its own", %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Fixed

    - **Typo fixes.** The editor toolbar said "Bodl" instead of "Bold". (#100)

    - **Finishes [the typo fixes](docs/changelog/v0.9.0.md#typo-fixes).** The
      public theme said "Contnue reading". (#101)
    """)

    condense!(dir)
    first = snapshot(dir)
    condense!(dir)

    assert snapshot(dir) == first
    assert read!(dir, "docs/changelog/v0.9.0.md") =~ "Contnue reading"
  end

  test "an unshortened entry with a docs link is stable across runs", %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Added

    - **Webhooks are documented in [the webhooks guide](docs/webhooks.md).** (#1501)
    """)

    condense!(dir)
    first = snapshot(dir)
    condense!(dir)

    assert snapshot(dir) == first
    assert read!(dir, "docs/changelog/v0.9.0.md") =~ "(#1501)"
  end

  test "correcting an unshortened entry's reference updates its archive block",
       %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Fixed

    - **Short fix.** (#12)
    """)

    condense!(dir)
    corrected = dir |> read!("CHANGELOG.md") |> String.replace("issues/12)", "issues/13)")
    write!(dir, "CHANGELOG.md", String.replace(corrected, "[#12]", "[#13]"))
    condense!(dir)

    refute read!(dir, "docs/changelog/v0.9.0.md") =~ "#12"
  end

  test "a long form mentioning a decision record's path does not replace its stub",
       %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.8.0] - 2026-09-11

    ### Security

    - **Bypass reasons are listed by `mix kiln.authz.check`.** It reads the reasons
      recorded in `docs/decisions/0001-policy-bypasses-on-request-paths-must-name-their-reason-and-a-gate-enforces-it.md`. (#2001)

    - **Every policy bypass on a request path now says why it is safe.** A gate
      keeps it that way. (#2002)
    """)

    condense!(dir)
    first = read!(dir, "docs/changelog/v0.8.0.md")
    condense!(dir)

    assert read!(dir, "docs/changelog/v0.8.0.md") == first
    assert first =~ "recorded as a decision in"
  end

  test "two blocks under one anchor stop --condense and fail --check", %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Fixed

    - **Typo fixes.** The editor said "Bodl".
      More text. (#1)
    """)

    condense!(dir)
    archive = read!(dir, "docs/changelog/v0.9.0.md")

    write!(
      dir,
      "docs/changelog/v0.9.0.md",
      archive <>
        "\n<a id=\"typo-fixes\"></a>\n\n- **Typo fixes.** The toolbar said \"Pasword\".\n"
    )

    assert_raise Mix.Error, ~r/more than one block/, fn -> condense!(dir) end
    assert_raise Mix.Error, fn -> run!(dir, ["--check"]) end
  end

  test "an advisory link beside the reference keeps a long-form link", %{tmp_dir: dir} do
    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Security

    - **Bump `plug` past the header-injection advisory** (#1500).
      ([GHSA-abcd-efgh-ijkl](https://github.com/advisories/GHSA-abcd-efgh-ijkl))
    """)

    condense!(dir)

    assert read!(dir, "CHANGELOG.md") =~ "[long form](docs/changelog/v0.9.0.md#"
  end

  test "--verify sees a long form lost from the archive", %{tmp_dir: dir} do
    git!(dir, ~w[init -q])

    changelog!(dir, """
    ## [0.9.0] - 2026-09-20

    ### Fixed

    - **Scheduled publishes survive a node restart.** The Oban job was enqueued
      with a unique period shorter than the delay, so a restart dropped it (#1392).
    """)

    condense!(dir)
    commit!(dir, "Condense (#1)")

    write!(
      dir,
      "docs/changelog/v0.9.0.md",
      String.replace(read!(dir, "docs/changelog/v0.9.0.md"), "shorter than the delay", "")
    )

    assert_raise Mix.Error, ~r/no destination/, fn -> run!(dir, ["--verify", "HEAD"]) end
  end

  test "a condensed entry with no reference is credited once its merge exists",
       %{tmp_dir: dir} do
    git!(dir, ~w[init -q])

    changelog!(dir, """
    ## [Unreleased]

    ### Added

    - **Widget export writes one file per locale.** Each locale gets its own file,
      so a translator can take one without the others.
    """)

    condense!(dir)
    refute read!(dir, "CHANGELOG.md") =~ "/issues/"

    commit!(dir, "Add widget export (#1450)")
    condense!(dir)

    assert read!(dir, "CHANGELOG.md") =~
             "[#1450](https://github.com/The-Verscienta/kiln_cms/issues/1450)"
  end
end
