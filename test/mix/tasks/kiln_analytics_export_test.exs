defmodule Mix.Tasks.Kiln.Analytics.ExportTest do
  @moduledoc """
  `mix kiln.analytics.export` (#618): ops/backup export, run with an explicit
  in-memory admin actor rather than `authorize?: false`.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.Analytics.ContentViewDay
  alias Mix.Tasks.Kiln.Analytics.Export

  defp seed_bucket(attrs) do
    Ash.Seed.seed!(
      ContentViewDay,
      Map.merge(%{content_type: "page", content_id: Ash.UUID.generate(), views: 1}, attrs)
    )
  end

  defp today, do: Date.utc_today()

  test "writes a CSV export to stdout by default, with nothing else on stdout" do
    seed_bucket(%{day: today(), views: 5})

    output =
      capture_io(fn ->
        Export.run(["--from=#{today()}", "--to=#{today()}"])
      end)

    assert String.starts_with?(output, "day,content_type,content_id,title,views\r\n")
    assert output =~ ",5\r\n"
    # The "Exported ..." summary goes to stderr, never stdout — stdout carries
    # only the export itself, so a piped/redirected run stays parseable.
    refute output =~ "Exported"
  end

  test "writes a JSON export when --format=json, with nothing else on stdout" do
    seed_bucket(%{day: today(), views: 9})

    output =
      capture_io(fn ->
        Export.run(["--format=json", "--from=#{today()}", "--to=#{today()}"])
      end)

    assert [%{"views" => 9}] = Jason.decode!(output)
  end

  test "the done summary is printed to stderr, not stdout" do
    seed_bucket(%{day: today(), views: 1})

    stderr =
      capture_io(:stderr, fn ->
        capture_io(fn -> Export.run(["--from=#{today()}", "--to=#{today()}"]) end)
      end)

    assert stderr =~ "Exported csv"
  end

  test "--org scopes the export to a single site" do
    other_org = KilnCMS.OrgFixtures.org("mix-export-other")
    foreign_id = Ash.UUID.generate()

    seed_bucket(%{
      content_type: "page",
      content_id: foreign_id,
      day: today(),
      views: 1,
      org_id: other_org.id
    })

    seed_bucket(%{day: today(), views: 2})

    output =
      capture_io(fn ->
        Export.run(["--from=#{today()}", "--to=#{today()}", "--org=#{other_org.id}"])
      end)

    assert output =~ foreign_id
  end

  test "writes to a file with --out" do
    seed_bucket(%{day: today(), views: 3})

    path =
      Path.join(
        System.tmp_dir!(),
        "kiln-analytics-export-test-#{System.unique_integer([:positive])}.csv"
      )

    capture_io(fn ->
      Export.run(["--from=#{today()}", "--to=#{today()}", "--out=#{path}"])
    end)

    on_exit(fn -> File.rm(path) end)

    assert File.read!(path) =~ ",3\r\n"
  end

  test "raises when --from is after --to" do
    assert_raise Mix.Error, ~r/--from must not be after --to/, fn ->
      capture_io(fn -> Export.run(["--from=#{today()}", "--to=#{Date.add(today(), -1)}"]) end)
    end
  end

  test "raises when the span exceeds the retention window" do
    too_wide_from = Date.add(today(), -ContentViewDay.retention_days())

    assert_raise Mix.Error, ~r/retention window/, fn ->
      capture_io(fn -> Export.run(["--from=#{too_wide_from}", "--to=#{today()}"]) end)
    end
  end

  test "raises on an unknown --format" do
    assert_raise Mix.Error, ~r/unknown --format/, fn ->
      capture_io(fn -> Export.run(["--format=xml"]) end)
    end
  end
end
