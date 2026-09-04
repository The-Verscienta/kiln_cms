defmodule KilnCMS.Analytics.ContentViewDayTest do
  @moduledoc """
  Recording a view upserts a per-day bucket alongside the totals-only counter,
  so the dashboard can show a 7d/30d trend (#45). Reading buckets is
  editor/admin only, and buckets never cross site boundaries.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.ContentViewDay

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cvd-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # `today/0` is KilnCMS.Test.StableDay's: ONE clock read per test, so every
  # seeded bucket and window bound in a test derives from the same day and a
  # run straddling UTC midnight can't disagree with itself (#1358).

  # Buckets for `day` are keyed by the identity, so a backdated one has to be
  # seeded directly — `:record` always writes today (the attribute is not
  # writable, precisely so a caller can't backdate).
  defp seed_bucket(attrs) do
    Ash.Seed.seed!(
      ContentViewDay,
      Map.merge(%{content_type: "page", content_id: Ash.UUID.generate(), views: 1}, attrs)
    )
  end

  test "repeated views of the same content on the same day increment one bucket" do
    # `:record` buckets on the app's own clock read, so a midnight roll under
    # the three calls would split them across two buckets. `stable_day`
    # re-runs once on the new day; the fresh id + filter keep the retry from
    # tripping over the first attempt's rows (#1358).
    stable_day(fn day ->
      id = Ash.UUID.generate()

      Analytics.record_view_day!("page", id, authorize?: false)
      Analytics.record_view_day!("page", id, authorize?: false)
      Analytics.record_view_day!("page", id, authorize?: false)

      assert [%{content_type: "page", content_id: ^id, views: 3, day: ^day}] =
               Analytics.views_since!(day, authorize?: false)
               |> Enum.filter(&(&1.content_id == id))
    end)
  end

  test "the same content on different days gets separate buckets" do
    # Wrapped for the same reason as above: the `:record` half of the pair
    # writes on the app's clock while `yesterday` is the test's.
    stable_day(fn day ->
      id = Ash.UUID.generate()
      yesterday = Date.add(day, -1)

      seed_bucket(%{content_id: id, day: yesterday, views: 5})
      Analytics.record_view_day!("page", id, authorize?: false)

      buckets =
        Analytics.views_since!(yesterday, authorize?: false)
        |> Enum.filter(&(&1.content_id == id))

      # Sorted oldest first by the `:in_window` action.
      assert [%{day: ^yesterday, views: 5}, %{day: ^day, views: 1}] = buckets
    end)
  end

  test "views_since excludes buckets before the window" do
    inside = Date.add(today(), -3)
    outside = Date.add(today(), -10)

    seed_bucket(%{day: inside, views: 2})
    old = seed_bucket(%{day: outside, views: 9})

    days = Analytics.views_since!(Date.add(today(), -6), authorize?: false)

    assert [%{day: ^inside, views: 2}] = days
    refute old.id in Enum.map(days, & &1.id)
  end

  test "buckets are visible to editors/admins but not viewers" do
    Analytics.record_view_day!("page", Ash.UUID.generate(), authorize?: false)

    assert [_] = Analytics.views_since!(today(), actor: user(:editor))
    assert [_] = Analytics.views_since!(today(), actor: user(:admin))

    # The read policy filters non-editors to nothing.
    assert [] = Analytics.views_since!(today(), actor: user(:viewer))
  end

  # Mirrors the ContentView case in analytics_policies_test: the OrgAdmin bypass
  # means admins are allowed, so the invariant is that no *non-admin* role can.
  test "no non-admin role may record a bucket" do
    input = %{content_type: "page", content_id: Ash.UUID.generate()}

    refute Ash.can?({ContentViewDay, :record, input}, user(:editor))
    refute Ash.can?({ContentViewDay, :record, input}, user(:viewer))
    refute Ash.can?({ContentViewDay, :record, input}, nil)
  end

  # `:in_range` is the export's source read (#618) — bounded on both ends and
  # keyset-paginated, unlike `:in_window`.
  describe "in_range" do
    defp in_range!(from, to, opts) do
      ContentViewDay
      |> Ash.Query.for_read(:in_range, %{from: from, to: to})
      |> Ash.read!(opts)
    end

    test "returns buckets within the inclusive window, oldest first" do
      inside_start = Date.add(today(), -5)
      inside_end = Date.add(today(), -1)
      before_window = Date.add(today(), -6)
      after_window = Date.add(today(), 1)

      seed_bucket(%{day: before_window, views: 1})
      seed_bucket(%{day: inside_start, views: 2})
      seed_bucket(%{day: inside_end, views: 3})
      seed_bucket(%{day: after_window, views: 4})

      buckets = in_range!(inside_start, inside_end, authorize?: false)

      assert Enum.map(buckets, & &1.day) == [inside_start, inside_end]
    end

    test "an empty window returns no buckets" do
      seed_bucket(%{day: today(), views: 1})
      assert [] = in_range!(Date.add(today(), 30), Date.add(today(), 31), authorize?: false)
    end

    test "streams through Ash.stream! (keyset pagination)" do
      for offset <- 0..2, do: seed_bucket(%{day: Date.add(today(), -offset), views: offset + 1})

      from = Date.add(today(), -2)

      rows =
        ContentViewDay
        |> Ash.Query.for_read(:in_range, %{from: from, to: today()})
        |> Ash.stream!(authorize?: false, batch_size: 1)
        |> Enum.to_list()

      assert length(rows) == 3
      assert Enum.map(rows, & &1.day) == Enum.sort([from, Date.add(from, 1), today()], Date)
    end

    test "buckets are visible to editors/admins but not viewers" do
      seed_bucket(%{day: today(), views: 1})

      assert [_] = in_range!(today(), today(), actor: user(:editor))
      assert [_] = in_range!(today(), today(), actor: user(:admin))
      assert [] = in_range!(today(), today(), actor: user(:viewer))
    end
  end
end
