defmodule Mix.Tasks.Kiln.UpdateTest do
  @moduledoc """
  The parts of `mix kiln.update` an operator acts on without a second source.

  Three things are covered here. The upgrade notes, because they are the one
  part of an update a downstream operator is expected to *act* on before
  deploying: showing a note that doesn't apply erodes trust in the whole
  report, and silently dropping one that does can mean a broken deploy. The
  Kiln-checkout guard, because everything the task reports and everything it
  checks out is scoped to the repo that guard identifies. And the printed next
  steps, because they are copy-pasted verbatim in order.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Kiln.Update

  defp version(string), do: Version.parse!(string)

  @changelog """
  # Changelog

  Preamble prose that mentions 1.2.3 but heads no section.

  ## [Unreleased]

  ### Added

  - Something unreleased.

  ## [0.3.0]

  ### Added

  - A feature.

  ### Upgrading

  1. Set NEW_ENV_VAR before deploying.

  ### Fixed

  - A bug that is not upgrade advice.

  ## [0.2.0]

  ### Upgrading

  Run the backfill task after deploying.

  ## [0.1.0]

  First release.
  """

  describe "upgrade_notes/3" do
    test "returns only sections in (from, to], oldest first" do
      assert [{from_version, _}, {to_version, _}] =
               Update.upgrade_notes(@changelog, version("0.1.0"), version("0.3.0"))

      assert Version.compare(from_version, version("0.2.0")) == :eq
      assert Version.compare(to_version, version("0.3.0")) == :eq
    end

    test "excludes the version being upgraded from" do
      notes = Update.upgrade_notes(@changelog, version("0.2.0"), version("0.3.0"))

      assert [{version, _}] = notes
      assert Version.compare(version, version("0.3.0")) == :eq
    end

    test "excludes versions beyond the target" do
      notes = Update.upgrade_notes(@changelog, version("0.1.0"), version("0.2.0"))

      assert [{version, _}] = notes
      assert Version.compare(version, version("0.2.0")) == :eq
    end

    test "stops at the next h3 so unrelated sections aren't read as advice" do
      [{_, body}] = Update.upgrade_notes(@changelog, version("0.2.0"), version("0.3.0"))

      assert body =~ "Set NEW_ENV_VAR"
      refute body =~ "not upgrade advice"
      refute body =~ "###"
    end

    test "skips releases that carry no Upgrading section" do
      notes = Update.upgrade_notes(@changelog, nil, version("0.1.0"))

      assert notes == []
    end

    # An untagged pin has no reliable lower bound, so every note up to the
    # target is shown rather than none — better to over-report than to let an
    # operator deploy past a destructive migration unwarned.
    test "shows every note up to the target when the current pin is untagged" do
      notes = Update.upgrade_notes(@changelog, nil, version("0.3.0"))

      assert length(notes) == 2
    end

    test "ignores Unreleased and prose that merely mentions a version" do
      notes = Update.upgrade_notes(@changelog, nil, version("0.3.0"))

      mentioned_in_prose = version("1.2.3")

      refute Enum.any?(notes, fn {found, _} ->
               Version.compare(found, mentioned_in_prose) == :eq
             end)
    end

    test "returns nothing when the changelog has no sections at all" do
      assert Update.upgrade_notes("# Changelog\n", nil, version("9.9.9")) == []
    end
  end

  # The task derives the repo to operate on from `git rev-parse --show-toplevel`
  # — "which repo am I standing in", not "where is the Kiln pin". When those
  # differ, every downstream step is aimed at the wrong repo: the newest `v*`
  # tag, the new-migrations list, the CHANGELOG it prints as upgrade advice,
  # and the working tree `git checkout --detach` rewrites. So the guard has to
  # reject anything it can't positively identify as Kiln.
  defp write_marker!(root) do
    path = Path.join(root, "lib/kiln_cms/application.ex")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "defmodule KilnCMS.Application do\nend\n")
  end

  defp write_mix_exs!(root, app) do
    File.write!(Path.join(root, "mix.exs"), """
    defmodule Some.MixProject do
      use Mix.Project

      def project do
        [app: #{inspect(app)}, version: "0.1.0"]
      end
    end
    """)
  end

  defp index_of(steps, prefix) do
    Enum.find_index(steps, &String.starts_with?(&1, prefix))
  end

  describe "kiln_checkout?/1" do
    test "accepts this repo" do
      assert Update.kiln_checkout?(File.cwd!())
    end

    @tag :tmp_dir
    test "accepts a checkout carrying both markers", %{tmp_dir: tmp_dir} do
      write_marker!(tmp_dir)
      write_mix_exs!(tmp_dir, :kiln_cms)

      assert Update.kiln_checkout?(tmp_dir)
    end

    # The failure that motivated the guard: a project that vendored the core
    # rather than pinning it. The Kiln source is *present*, but the git repo it
    # is standing in — and so every tag, migration and changelog the task would
    # read — belongs to the project.
    @tag :tmp_dir
    test "rejects a repo whose own mix.exs is some other app", %{tmp_dir: tmp_dir} do
      write_marker!(Path.join(tmp_dir, "kiln"))
      write_mix_exs!(tmp_dir, :my_project)

      refute Update.kiln_checkout?(tmp_dir)
    end

    @tag :tmp_dir
    test "rejects a non-Elixir repo", %{tmp_dir: tmp_dir} do
      write_marker!(tmp_dir)

      refute Update.kiln_checkout?(tmp_dir)
    end

    @tag :tmp_dir
    test "rejects a Kiln-named mix project without the core source", %{tmp_dir: tmp_dir} do
      write_mix_exs!(tmp_dir, :kiln_cms)

      refute Update.kiln_checkout?(tmp_dir)
    end
  end

  # The steps are printed as a numbered-feeling list and copy-pasted in order,
  # so ordering is behaviour: `mix deps.get` after the `cd` fails with "Could
  # not find a Mix.Project" in the submodule layout, because the superproject
  # of a polyglot monorepo has no root mix.exs.
  describe "next_steps/2" do
    @target %{tag: "v0.3.0", sha: "abc1234def", version: nil}
    @submodule %{root: "/proj/kiln/upstream", superproject: "/proj"}

    test "runs mix deps.get before leaving the Kiln checkout" do
      steps = Update.next_steps(@submodule, @target)

      assert index_of(steps, "mix deps.get") < index_of(steps, "cd ")
    end

    test "commits the pin from the superproject, by its relative path" do
      steps = Update.next_steps(@submodule, @target)

      assert "cd /proj" in steps
      assert "git add kiln/upstream" in steps
      assert Enum.any?(steps, &(&1 =~ ~s(chore: update kiln to v0.3.0)))
    end

    # Nothing pins a standalone checkout, so there is no path to `cd` to and no
    # index entry to commit — the move is already in this repo's own HEAD.
    test "omits the pin commit for a standalone checkout" do
      steps = Update.next_steps(%{root: "/kiln", superproject: nil}, @target)

      assert "mix deps.get" in steps
      assert index_of(steps, "cd ") == nil
      assert index_of(steps, "git ") == nil
    end
  end
end
