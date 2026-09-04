defmodule KilnCMS.Analytics.ReferrerDayTest do
  @moduledoc """
  Recording a classified referrer upserts a per-day, per-source bucket (#619).
  Reading buckets is editor/admin only, and buckets never cross site
  boundaries. No test here ever asserts a stored host or URL — because
  `:record` only accepts the classified atom, there is nothing to assert
  against.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.ReferrerDay

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "referrer-day-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  # today/0: one memoized clock read per test — see KilnCMS.Test.StableDay (#1358).

  defp seed_bucket(attrs) do
    Ash.Seed.seed!(
      ReferrerDay,
      Map.merge(
        %{content_type: "page", content_id: Ash.UUID.generate(), source: :direct, hits: 1},
        attrs
      )
    )
  end

  defp stored_rows do
    ReferrerDay |> Ash.read!(authorize?: false)
  end

  # Scoped to one content id — the default read inside a `stable_day` body,
  # so a retry never trips over the first attempt's rows. Reach for the
  # 0-arity whole-table form only outside a wrap (the retention test).
  defp stored_rows(content_id) do
    stored_rows() |> Enum.filter(&(&1.content_id == content_id))
  end

  test "repeated arrivals from the same source on the same day increment one bucket" do
    # `:record` buckets on the app's own clock read — a mid-body roll splits
    # the three calls across two buckets, which only a re-run can absorb.
    stable_day(fn day ->
      id = Ash.UUID.generate()

      Analytics.record_referrer!("page", id, :search, authorize?: false)
      Analytics.record_referrer!("page", id, :search, authorize?: false)
      Analytics.record_referrer!("page", id, :search, authorize?: false)

      assert [%{content_type: "page", content_id: ^id, source: :search, hits: 3, day: ^day}] =
               stored_rows(id)
    end)
  end

  test "different sources on the same content and day get separate buckets" do
    # A roll between the :search and :social records would put the buckets on
    # different days — same wrap as above.
    stable_day(fn _day ->
      id = Ash.UUID.generate()

      Analytics.record_referrer!("page", id, :search, authorize?: false)
      Analytics.record_referrer!("page", id, :social, authorize?: false)
      Analytics.record_referrer!("page", id, :search, authorize?: false)

      rows =
        stored_rows(id) |> Enum.sort_by(& &1.source)

      assert [%{source: :search, hits: 2}, %{source: :social, hits: 1}] = rows
    end)
  end

  test "the same source on a different day gets a separate bucket" do
    stable_day(fn day ->
      id = Ash.UUID.generate()
      yesterday = Date.add(day, -1)

      seed_bucket(%{content_id: id, source: :direct, day: yesterday, hits: 5})
      Analytics.record_referrer!("page", id, :direct, authorize?: false)

      # `Date` as the comparator: bare term ordering compares the struct's
      # :day field first, so on the 1st of a month ~D[2026-09-01] sorts BEFORE
      # ~D[2026-08-31] and this failed exactly one day a month.
      rows = stored_rows(id) |> Enum.sort_by(& &1.day, Date)

      assert [%{day: ^yesterday, hits: 5}, %{day: ^day, hits: 1}] = rows
    end)
  end

  test "source is bounded to the five known categories" do
    input = %{content_type: "page", content_id: Ash.UUID.generate(), source: :not_a_real_source}

    assert {:error, error} = Ash.create(ReferrerDay, input, action: :record, authorize?: false)
    assert %Ash.Error.Invalid{} = error
  end

  test "buckets are visible to editors/admins but not viewers" do
    Analytics.record_referrer!("page", Ash.UUID.generate(), :direct, authorize?: false)

    assert [_] = Ash.read!(ReferrerDay, actor: user(:editor))
    assert [_] = Ash.read!(ReferrerDay, actor: user(:admin))

    # The read policy filters non-editors to nothing.
    assert [] = Ash.read!(ReferrerDay, actor: user(:viewer))
  end

  # Mirrors the ContentViewDay case: the OrgAdmin bypass means admins are
  # allowed, so the invariant is that no *non-admin* role can.
  test "no non-admin role may record a bucket" do
    input = %{content_type: "page", content_id: Ash.UUID.generate(), source: :direct}

    refute Ash.can?({ReferrerDay, :record, input}, user(:editor))
    refute Ash.can?({ReferrerDay, :record, input}, user(:viewer))
    refute Ash.can?({ReferrerDay, :record, input}, nil)
  end

  describe "in_window" do
    defp in_window!(since, opts) do
      ReferrerDay
      |> Ash.Query.for_read(:in_window, %{since: since})
      |> Ash.read!(opts)
    end

    test "returns buckets on or after the given day, oldest first" do
      inside = Date.add(today(), -3)
      outside = Date.add(today(), -10)

      seed_bucket(%{day: outside, source: :search, hits: 9})
      seed_bucket(%{day: inside, source: :social, hits: 2})

      buckets = in_window!(Date.add(today(), -6), authorize?: false)

      assert [%{day: ^inside, source: :social, hits: 2}] = buckets
    end

    test "buckets are visible to editors/admins but not viewers" do
      seed_bucket(%{day: today()})

      assert [_] = in_window!(today(), actor: user(:editor))
      assert [_] = in_window!(today(), actor: user(:admin))
      assert [] = in_window!(today(), actor: user(:viewer))
    end
  end

  describe "in_range" do
    defp in_range!(from, to, opts) do
      ReferrerDay
      |> Ash.Query.for_read(:in_range, %{from: from, to: to})
      |> Ash.read!(opts)
    end

    test "returns buckets within the inclusive window, oldest first" do
      inside_start = Date.add(today(), -5)
      inside_end = Date.add(today(), -1)
      before_window = Date.add(today(), -6)
      after_window = Date.add(today(), 1)

      seed_bucket(%{day: before_window})
      seed_bucket(%{day: inside_start})
      seed_bucket(%{day: inside_end})
      seed_bucket(%{day: after_window})

      buckets = in_range!(inside_start, inside_end, authorize?: false)

      assert Enum.map(buckets, & &1.day) == [inside_start, inside_end]
    end

    test "streams through Ash.stream! (keyset pagination)" do
      for offset <- 0..2, do: seed_bucket(%{day: Date.add(today(), -offset), hits: offset + 1})

      from = Date.add(today(), -2)

      rows =
        ReferrerDay
        |> Ash.Query.for_read(:in_range, %{from: from, to: today()})
        |> Ash.stream!(authorize?: false, batch_size: 1)
        |> Enum.to_list()

      assert length(rows) == 3
    end
  end

  describe "retention" do
    defp bucket_at(inserted_at) do
      Ash.Seed.seed!(ReferrerDay, %{
        content_type: "page",
        content_id: Ash.UUID.generate(),
        source: :direct,
        day: DateTime.to_date(inserted_at),
        hits: 1,
        inserted_at: inserted_at,
        updated_at: inserted_at
      })
    end

    test "purges buckets older than the retention window, keeps recent ones" do
      days = ReferrerDay.retention_days()
      old = bucket_at(DateTime.add(DateTime.utc_now(), -(days + 1), :day))
      recent = bucket_at(DateTime.add(DateTime.utc_now(), -1, :day))

      AshOban.schedule_and_run_triggers(ReferrerDay,
        drain_queues?: true,
        with_recursion: true,
        with_scheduled: true
      )

      ids = stored_rows() |> Enum.map(& &1.id)
      refute old.id in ids
      assert recent.id in ids
    end
  end
end
