defmodule KilnCMS.Scripts.ReleaseFloatingTagsTest do
  @moduledoc """
  `scripts/release/floating_tags.sh` decides whether a release tag moves the
  image's floating tags (`latest`, and the major line's `1`) in
  `.github/workflows/release.yml` (#1544). A workflow cannot be run from a
  test, so the decision lives in a script and is asserted here, against the
  release histories the support policy produces: a patch on the previous
  minor pushed after the current one, a patch on an old major, a candidate.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/release/floating_tags.sh", __DIR__)

  defp decide(ref, tags) do
    # The script explains each answer on stderr for the run log; keep it out
    # of the test output.
    {out, 0} = System.cmd("bash", ["-c", ~s("$0" "$@" 2>/dev/null), @script, ref | tags])

    out
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      {key, value == "true"}
    end)
  end

  @history ~w[v0.11.0 v0.12.0 v1.0.0-rc.1 v1.0.0 v1.0.1 v1.1.0-rc.1 v1.1.0]

  test "the highest final release moves latest and the major tag" do
    assert decide("v1.1.0", @history) == %{"latest" => true, "major" => true}
  end

  test "the ref counts even when the tag list has not caught up with it" do
    assert decide("v1.1.1", @history) == %{"latest" => true, "major" => true}
  end

  test "a patch on the previous minor moves neither, however recently it was pushed" do
    assert decide("v1.0.2", @history) == %{"latest" => false, "major" => false}
  end

  test "a patch on an old major moves that major's tag but not latest" do
    tags = ~w[v1.4.0 v1.4.1 v2.0.0]

    assert decide("v1.4.2", tags) == %{"latest" => false, "major" => true}
    assert decide("v1.3.9", tags) == %{"latest" => false, "major" => false}
  end

  test "a newer candidate does not outrank a final release" do
    assert decide("v1.0.1", ~w[v1.0.0 v1.1.0-rc.1 v2.0.0-rc.1]) ==
             %{"latest" => true, "major" => true}
  end

  test "a release candidate moves nothing" do
    assert decide("v1.0.0-rc.1", ~w[v0.12.0]) == %{"latest" => false, "major" => false}
    assert decide("v2.0.0-rc.1", @history) == %{"latest" => false, "major" => false}
  end

  test "pre-1.0 moves latest but there is no floating major" do
    assert decide("v0.12.1", ~w[v0.11.0 v0.12.0]) == %{"latest" => true, "major" => false}
  end

  test "re-running an old tag's workflow does not move latest back to it" do
    assert decide("v1.0.0", @history) == %{"latest" => false, "major" => false}
  end

  test "versions compare numerically, not as strings" do
    assert decide("v1.10.0", ~w[v1.9.0 v1.2.0]) == %{"latest" => true, "major" => true}
    assert decide("v1.9.0", ~w[v1.10.0]) == %{"latest" => false, "major" => false}
  end

  test "tags that are not releases are ignored, and a non-release ref moves nothing" do
    assert decide("v1.0.0", ~w[v9-wip vnext refs/tags/v0.12.0]) ==
             %{"latest" => true, "major" => true}

    assert decide("v1.0", ~w[v0.12.0]) == %{"latest" => false, "major" => false}
  end

  test "ls-remote's refs/tags/ prefix is stripped" do
    assert decide("v1.0.0", ~w[refs/tags/v1.1.0]) == %{"latest" => false, "major" => false}
  end
end
