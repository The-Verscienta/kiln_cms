defmodule Mix.Tasks.Kiln.Analytics.ExportTest do
  @moduledoc """
  `mix kiln.analytics.export` (#618): ops/backup export, run with an explicit
  in-memory admin actor rather than `authorize?: false`.
  """
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureIO

  alias KilnCMS.Analytics.ContentViewDay
  alias KilnCMS.Analytics.ReferrerDay
  alias Mix.Tasks.Kiln.Analytics.Export

  defp seed_bucket(attrs) do
    Ash.Seed.seed!(
      ContentViewDay,
      Map.merge(%{content_type: "page", content_id: Ash.UUID.generate(), views: 1}, attrs)
    )
  end

  defp seed_referrer_bucket(attrs) do
    Ash.Seed.seed!(
      ReferrerDay,
      Map.merge(
        %{content_type: "page", content_id: Ash.UUID.generate(), source: :direct, hits: 1},
        attrs
      )
    )
  end

  defp enable_referrers(threshold) do
    original = Application.get_env(:kiln_cms, :analytics_referrers, [])

    Application.put_env(:kiln_cms, :analytics_referrers,
      enabled: true,
      low_count_threshold: threshold
    )

    on_exit(fn -> Application.put_env(:kiln_cms, :analytics_referrers, original) end)
  end

  defp today, do: Date.utc_today()

  test "writes a CSV export to stdout by default, with nothing else on stdout" do
    seed_bucket(%{day: today(), views: 5})

    output =
      capture_io(fn ->
        Export.run(["--from=#{today()}", "--to=#{today()}"])
      end)

    assert String.starts_with?(
             output,
             "kind,day,content_type,content_id,title,views,source,hits,funnel_slug,ratio\r\n"
           )

    assert output =~ ",5,,,,\r\n"
    # The "Exported ..." summary goes to stderr, never stdout — stdout carries
    # only the export itself, so a piped/redirected run stays parseable.
    refute output =~ "Exported"
  end

  test "includes referrer rows when the phase-2 gate is on, suppressed as \"< n\" when appropriate" do
    enable_referrers(5)
    id = Ash.UUID.generate()
    seed_referrer_bucket(%{content_id: id, day: today(), source: :search, hits: 2})

    output =
      capture_io(fn ->
        Export.run(["--from=#{today()}", "--to=#{today()}"])
      end)

    assert output =~ "referrer,#{today()},page,#{id},(deleted),,search,< 5"
  end

  test "omits referrer rows when the phase-2 gate is off, even if buckets exist" do
    seed_referrer_bucket(%{day: today(), source: :search, hits: 9})

    output =
      capture_io(fn ->
        Export.run(["--from=#{today()}", "--to=#{today()}"])
      end)

    refute output =~ "referrer,"
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

    assert File.read!(path) =~ ",3,,,,\r\n"
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

  describe "funnel rows (#622)" do
    defp admin do
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "kae-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })
    end

    test "includes a funnel step row alongside view rows" do
      id = Ash.UUID.generate()
      seed_bucket(%{content_id: id, day: today(), views: 8})

      funnel =
        KilnCMS.Analytics.create_funnel!(
          %{name: "Signup", slug: "kae-#{System.unique_integer([:positive])}"},
          actor: admin()
        )

      KilnCMS.Analytics.create_funnel_step!(
        %{funnel_id: funnel.id, content_type: "page", content_id: id, position: 0},
        actor: admin()
      )

      output =
        capture_io(fn ->
          Export.run(["--from=#{today()}", "--to=#{today()}"])
        end)

      assert output =~ "funnel_step,,page,#{id},(deleted),8,,,#{funnel.slug},\r\n"
    end
  end
end
