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

  defp today, do: Date.utc_today()

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

  test "repeated arrivals from the same source on the same day increment one bucket" do
    id = Ash.UUID.generate()

    Analytics.record_referrer!("page", id, :search, authorize?: false)
    Analytics.record_referrer!("page", id, :search, authorize?: false)
    Analytics.record_referrer!("page", id, :search, authorize?: false)

    day = today()

    assert [%{content_type: "page", content_id: ^id, source: :search, hits: 3, day: ^day}] =
             stored_rows()
  end

  test "different sources on the same content and day get separate buckets" do
    id = Ash.UUID.generate()

    Analytics.record_referrer!("page", id, :search, authorize?: false)
    Analytics.record_referrer!("page", id, :social, authorize?: false)
    Analytics.record_referrer!("page", id, :search, authorize?: false)

    rows = stored_rows() |> Enum.sort_by(& &1.source)

    assert [%{source: :search, hits: 2}, %{source: :social, hits: 1}] = rows
  end

  test "the same source on a different day gets a separate bucket" do
    id = Ash.UUID.generate()
    yesterday = Date.add(today(), -1)

    seed_bucket(%{content_id: id, source: :direct, day: yesterday, hits: 5})
    Analytics.record_referrer!("page", id, :direct, authorize?: false)

    rows = stored_rows() |> Enum.sort_by(& &1.day)

    assert [%{day: ^yesterday, hits: 5}, %{day: _today, hits: 1}] = rows
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
