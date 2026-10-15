defmodule KilnCMS.ReleaseAdoptionTest do
  @moduledoc """
  `KilnCMS.Release.adopt_image_backend/1`, the adoption a release runs
  (`bin/kiln_cms rpc 'KilnCMS.Release.adopt_image_backend()'`), with no Mix in
  the VM: the task's report through `IO.puts/1`, refusals returned rather than
  raised, keyword options in place of flags.

  The adoption itself is `KilnCMS.Media.Adoption`'s and tested with the image
  backend (`KilnCMS.Media.ImageBackendTest`). This pins what only the release
  path decides.
  """
  # async: false — the selected backend lives in the global app env.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.CMS
  alias KilnCMS.FixturePlugin.ImageBackend, as: Fixture
  alias KilnCMS.Release

  setup do
    on_exit(fn ->
      Application.delete_env(:kiln_cms, :image_backend)
      Application.delete_env(:kiln_cms, :fixture_image_backend)
    end)
  end

  defp select_backend do
    Application.put_env(:kiln_cms, :image_backend, Fixture)
    Application.put_env(:kiln_cms, :fixture_image_backend, [])
  end

  defp imported(url), do: Ash.Seed.seed!(CMS.MediaItem, %{filename: "linked.png", url: url})

  # The result and everything printed, the way an `rpc` terminal sees it.
  defp run(fun) do
    test = self()
    out = capture_io(fn -> send(test, {:result, fun.()}) end)
    assert_received {:result, result}
    {result, out}
  end

  test "a dry run of the default site prints the task's report and writes nothing" do
    select_backend()
    row = imported("https://images.fixture.test/a/public")
    imported("https://cdn.example.com/x.png")

    {result, out} = run(fn -> Release.adopt_image_backend(dry_run: true) end)

    assert {:ok, %{scanned: 2, adopted: 1, failed: 0}} = result

    assert out =~
             "Would adopt 1 of 2 row(s) with no stored file in org " <>
               KilnCMS.Accounts.default_org_id()

    assert CMS.get_media_item!(row.id, authorize?: false).image_backend == nil
  end

  test "adopts into the org it's given" do
    select_backend()
    row = imported("https://images.fixture.test/a/public")
    org_id = KilnCMS.Accounts.default_org_id()

    {result, out} = run(fn -> Release.adopt_image_backend(org: org_id) end)

    assert {:ok, %{adopted: 1}} = result
    assert out =~ "Adopted 1 of 1 row(s)"
    assert CMS.get_media_item!(row.id, authorize?: false).image_backend == Fixture.name()
  end

  test "with no active backend it says how to select one" do
    {result, out} = run(fn -> Release.adopt_image_backend() end)

    assert {:error, message} = result
    assert message =~ "No image backend is active"
    assert out =~ message
  end

  test "on a node that is not serving it refuses and points at rpc" do
    select_backend()

    {result, out} = run(fn -> Release.run_adoption([], false) end)

    assert {:error, message} = result
    assert message =~ "bin/kiln_cms rpc"
    assert out =~ message
  end
end
