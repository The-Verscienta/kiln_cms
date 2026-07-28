defmodule Mix.Tasks.Kiln.UpdateTest do
  @moduledoc """
  Changelog parsing for `mix kiln.update`.

  The upgrade notes are the one part of an update a downstream operator is
  expected to *act* on before deploying, so the range selection is covered
  directly: showing a note that doesn't apply erodes trust in the whole
  report, and silently dropping one that does can mean a broken deploy.
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
end
