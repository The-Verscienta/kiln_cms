defmodule KilnCMS.CMS.ContentLifecycleTest do
  @moduledoc """
  Content lifecycles: the freshness axis (`review_after_days` /
  `last_reviewed_at` / `due_at` / `health`) and the three expiry actions the
  embargo end can take. See `docs/content-lifecycles.md`.

  Health is an expression calculation, so every assertion here is also an
  assertion that it computes **in SQL** — the filter tests below would raise out
  of AshSql rather than fail if it had been written as an Elixir-side calc.
  """
  use KilnCMS.DataCase, async: true

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "life-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "life-#{System.unique_integer([:positive])}"

  defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 86_400, :second)
  defp days_from_now(n), do: DateTime.add(DateTime.utc_now(), n * 86_400, :second)

  defp page(admin, attrs \\ %{}) do
    CMS.create_page!(Map.merge(%{title: "Lifecycle", slug: slug()}, attrs), actor: admin)
  end

  defp published_page(admin, attrs \\ %{}) do
    admin |> page(attrs) |> CMS.publish_page!(%{}, actor: admin)
  end

  # `published_at` is stamped by the publish; move it backwards through the
  # internal action so "published a year ago" is expressible without sleeping.
  defp backdate!(record, at) do
    record
    |> Ash.Changeset.for_update(:backdate_published_at, %{published_at: at})
    |> Ash.update!(authorize?: false)
  end

  defp health(record, admin) do
    record.__struct__
    |> Ash.get!(record.id, actor: admin, load: [:health, :due_at, :effective_review_after_days])
  end

  describe "health" do
    test "unpublished content is always fresh, however far past due" do
      admin = user(:admin)

      draft =
        page(admin, %{review_after_days: 1})
        |> Ash.Changeset.for_update(:mark_reviewed, %{})
        |> Ash.update!(authorize?: false)

      # A draft has no `published_at` either, so this is belt and braces — the
      # point is that the state check short-circuits before anything else.
      assert health(draft, admin).health == :fresh
    end

    test "published content with no cadence is fresh" do
      admin = user(:admin)
      assert health(published_page(admin), admin).health == :fresh
    end

    test "a cadence not yet approaching is fresh" do
      admin = user(:admin)
      live = published_page(admin, %{review_after_days: 90})
      live = mark_reviewed_at!(live, days_ago(10))

      loaded = health(live, admin)
      assert loaded.health == :fresh
      assert loaded.effective_review_after_days == 90
    end

    test "falling due inside the week is due_soon" do
      admin = user(:admin)
      live = published_page(admin, %{review_after_days: 90})
      live = mark_reviewed_at!(live, days_ago(85))

      assert health(live, admin).health == :due_soon
    end

    test "past due, inside the grace week, is due" do
      admin = user(:admin)
      live = published_page(admin, %{review_after_days: 90})
      live = mark_reviewed_at!(live, days_ago(95))

      assert health(live, admin).health == :due
    end

    test "past due by more than the grace week is overdue" do
      admin = user(:admin)
      live = published_page(admin, %{review_after_days: 90})
      live = mark_reviewed_at!(live, days_ago(120))

      assert health(live, admin).health == :overdue
    end

    test "content never reviewed counts its cadence from the publish" do
      admin = user(:admin)
      live = published_page(admin, %{review_after_days: 30})
      assert health(live, admin).health == :fresh

      live = backdate!(live, days_ago(100))

      loaded = health(live, admin)
      assert loaded.health == :overdue
      assert is_nil(loaded.last_reviewed_at)
      # due_at is publish + cadence, i.e. 70 days ago.
      assert_in_delta DateTime.diff(loaded.due_at, days_ago(70)), 0, 120
    end

    test "a passed embargo end on still-published content reads expired, beating overdue" do
      admin = user(:admin)

      live =
        published_page(admin, %{review_after_days: 90, expiry_action: :flag})
        |> mark_reviewed_at!(days_ago(200))

      live = set_unpublish_at!(live, days_ago(1))

      # Overdue on the freshness axis *and* past its embargo end; expiry wins,
      # because "this should not be live at all" outranks "this needs a re-read".
      assert health(live, admin).health == :expired
    end

    test "a future embargo end does not make content expired" do
      admin = user(:admin)
      live = published_page(admin) |> set_unpublish_at!(days_from_now(30))

      assert health(live, admin).health == :fresh
    end

    test "due_at is nil without a cadence" do
      admin = user(:admin)
      assert is_nil(health(published_page(admin), admin).due_at)
    end
  end

  describe "health as a filter" do
    test "filters and counts in SQL" do
      admin = user(:admin)

      overdue = published_page(admin, %{review_after_days: 30}) |> mark_reviewed_at!(days_ago(90))
      fresh = published_page(admin, %{review_after_days: 30}) |> mark_reviewed_at!(days_ago(1))

      matched =
        CMS.Page
        |> Ash.Query.filter(health == :overdue)
        |> Ash.read!(actor: admin)
        |> Enum.map(& &1.id)

      assert overdue.id in matched
      refute fresh.id in matched
    end

    test "sorting by due_at orders the review queue" do
      admin = user(:admin)

      later = published_page(admin, %{review_after_days: 30}) |> mark_reviewed_at!(days_ago(10))
      sooner = published_page(admin, %{review_after_days: 30}) |> mark_reviewed_at!(days_ago(25))

      ordered =
        CMS.Page
        |> Ash.Query.filter(id in [^later.id, ^sooner.id])
        |> Ash.Query.sort(due_at: :asc)
        |> Ash.read!(actor: admin)
        |> Enum.map(& &1.id)

      assert ordered == [sooner.id, later.id]
    end
  end

  describe "mark_reviewed" do
    test "stamps the attestation and resets health" do
      admin = user(:admin)
      live = published_page(admin, %{review_after_days: 30}) |> mark_reviewed_at!(days_ago(90))
      assert health(live, admin).health == :overdue

      reviewed = CMS.mark_page_reviewed!(live, %{}, actor: admin)

      assert DateTime.diff(DateTime.utc_now(), reviewed.last_reviewed_at) < 5
      assert health(reviewed, admin).health == :fresh
    end

    test "records its own PaperTrail version, distinct from an edit" do
      admin = user(:admin)
      live = published_page(admin, %{review_after_days: 30})

      CMS.mark_page_reviewed!(live, %{}, actor: admin)

      actions =
        CMS.list_page_versions!(actor: admin)
        |> Enum.filter(&(&1.version_source_id == live.id))
        |> Enum.map(& &1.version_action_name)

      assert :mark_reviewed in actions
    end

    test "an ordinary update cannot write last_reviewed_at" do
      admin = user(:admin)
      live = published_page(admin, %{review_after_days: 30})

      assert_raise Ash.Error.Invalid, fn ->
        CMS.update_page!(live, %{last_reviewed_at: DateTime.utc_now()}, actor: admin)
      end
    end

    test "an editor may attest; a viewer may not" do
      admin = user(:admin)
      live = published_page(admin, %{review_after_days: 30})

      assert CMS.mark_page_reviewed!(live, %{}, actor: user(:editor))
      assert {:error, _} = CMS.mark_page_reviewed(live, %{}, actor: user(:viewer))
    end
  end

  describe "review_after_days bounds" do
    test "rejects zero and anything past three years" do
      admin = user(:admin)

      assert {:error, _} =
               CMS.create_page(%{title: "T", slug: slug(), review_after_days: 0}, actor: admin)

      assert {:error, _} =
               CMS.create_page(%{title: "T", slug: slug(), review_after_days: 1096}, actor: admin)

      assert CMS.create_page!(%{title: "T", slug: slug(), review_after_days: 1095}, actor: admin)
    end
  end

  describe "expiry_action" do
    defp expire!(page) do
      AshOban.schedule_and_run_triggers(CMS.Page,
        drain_queues?: true,
        with_recursion: true,
        with_scheduled: true
      )

      CMS.get_page!(page.id, authorize?: false)
    end

    test ":unpublish (the default) takes the record back to draft" do
      admin = user(:admin)
      live = published_page(admin) |> set_unpublish_at!(days_ago(1))
      assert live.expiry_action == :unpublish

      expired = expire!(live)

      assert expired.state == :draft
      assert is_nil(expired.unpublish_at)
      assert is_nil(expired.published_version_id)
    end

    test ":archive sends it to the archive instead, clearing the embargo end" do
      admin = user(:admin)

      live =
        published_page(admin, %{expiry_action: :archive}) |> set_unpublish_at!(days_ago(1))

      expired = expire!(live)

      assert expired.state == :archived
      assert is_nil(expired.unpublish_at)
      assert is_nil(expired.published_version_id)
    end

    test ":flag changes nothing about the row — the signal is the health calc" do
      admin = user(:admin)
      live = published_page(admin, %{expiry_action: :flag}) |> set_unpublish_at!(days_ago(1))

      expired = expire!(live)

      assert expired.state == :published
      assert expired.unpublish_at, "a flagged record keeps its past embargo end"
      assert health(expired, admin).health == :expired
    end

    test "a flagged record is not re-picked-up on every subsequent sweep" do
      admin = user(:admin)
      live = published_page(admin, %{expiry_action: :flag}) |> set_unpublish_at!(days_ago(1))

      before = CMS.list_page_versions!(actor: admin) |> length()
      expire!(live)
      expire!(live)

      assert CMS.list_page_versions!(actor: admin) |> length() == before,
             "a :flag expiry must write nothing, so it can never churn version history"
    end

    test "a future embargo end is left alone whatever the expiry action" do
      admin = user(:admin)

      live =
        published_page(admin, %{expiry_action: :archive})
        |> set_unpublish_at!(days_from_now(30))

      assert expire!(live).state == :published
    end
  end

  describe "per-type default cadence (dynamic entry tier)" do
    test "an entry with no cadence of its own inherits its type's default" do
      admin = user(:admin)

      type =
        CMS.create_type_definition!(
          %{
            name: "dyn#{System.unique_integer([:positive])}",
            label: "Monograph",
            default_review_after_days: 30
          },
          actor: admin
        )

      entry =
        ContentTypes.create!(type.name, %{title: "Aconite", slug: slug()}, actor: admin)

      {:ok, entry} = ContentTypes.transition(type.name, "publish", entry, actor: admin)
      entry = backdate!(entry, days_ago(100))

      loaded =
        Ash.get!(CMS.Entry, entry.id,
          actor: admin,
          load: [:health, :due_at, :effective_review_after_days]
        )

      assert loaded.effective_review_after_days == 30
      assert loaded.health == :overdue
    end

    test "the entry's own cadence overrides the type default" do
      admin = user(:admin)

      type =
        CMS.create_type_definition!(
          %{
            name: "dyn#{System.unique_integer([:positive])}",
            label: "Monograph",
            default_review_after_days: 30
          },
          actor: admin
        )

      entry =
        ContentTypes.create!(
          type.name,
          %{title: "Aconite", slug: slug(), review_after_days: 365},
          actor: admin
        )

      {:ok, entry} = ContentTypes.transition(type.name, "publish", entry, actor: admin)
      entry = backdate!(entry, days_ago(100))

      loaded =
        Ash.get!(CMS.Entry, entry.id,
          actor: admin,
          load: [:health, :effective_review_after_days]
        )

      assert loaded.effective_review_after_days == 365
      assert loaded.health == :fresh
    end

    test "no cadence anywhere leaves the entry fresh forever" do
      admin = user(:admin)

      type =
        CMS.create_type_definition!(
          %{name: "dyn#{System.unique_integer([:positive])}", label: "Note"},
          actor: admin
        )

      entry = ContentTypes.create!(type.name, %{title: "Note", slug: slug()}, actor: admin)
      {:ok, entry} = ContentTypes.transition(type.name, "publish", entry, actor: admin)
      entry = backdate!(entry, days_ago(2000))

      loaded = Ash.get!(CMS.Entry, entry.id, actor: admin, load: [:health, :due_at])
      assert loaded.health == :fresh
      assert is_nil(loaded.due_at)
    end
  end

  # --- helpers that write timestamps the actions deliberately won't ------------

  # `:mark_reviewed` always stamps *now*, which is the point of it. Tests need a
  # review in the past, so they seed the column directly rather than through the
  # action — the action's own behaviour is asserted in its own describe block.
  defp mark_reviewed_at!(record, at) do
    record
    |> Ash.Changeset.for_update(:mark_reviewed, %{})
    |> Ash.Changeset.force_change_attribute(:last_reviewed_at, at)
    |> Ash.update!(authorize?: false)
  end

  defp set_unpublish_at!(record, at) do
    record
    |> Ash.Changeset.for_update(:update, %{unpublish_at: at})
    |> Ash.update!(authorize?: false)
  end
end
