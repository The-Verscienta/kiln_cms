defmodule KilnCMS.CMS.TrashPurgeTest do
  @moduledoc """
  The `:purge` action hard-deletes trashed content (bypassing AshArchival), and
  the nightly AshOban `purge_trashed` trigger purges anything that has sat in
  the trash for 30+ days.
  """
  # Oban runs in :manual mode; `schedule_and_run_triggers/2` drains the queue
  # inline in this process (see scheduled_publishing_test.exs).
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  defp trashed_page(archived_at) do
    Ash.Seed.seed!(Page, %{
      title: "Trashed",
      slug: "purge-#{System.unique_integer([:positive])}",
      state: :draft,
      archived_at: archived_at
    })
  end

  test "purge hard-deletes a trashed page" do
    page = trashed_page(DateTime.utc_now())

    assert :ok = CMS.purge_page(page, authorize?: false)
    refute Enum.any?(CMS.list_trashed_pages!(authorize?: false), &(&1.id == page.id))
  end

  test "the nightly trigger purges 30+ day-old trash but keeps recent items" do
    old = trashed_page(DateTime.add(DateTime.utc_now(), -31, :day))
    recent = trashed_page(DateTime.add(DateTime.utc_now(), -5, :day))

    AshOban.schedule_and_run_triggers(KilnCMS.CMS.Page,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    trashed_ids = Enum.map(CMS.list_trashed_pages!(authorize?: false), & &1.id)
    refute old.id in trashed_ids
    assert recent.id in trashed_ids
  end

  # R5: a record a "Don't allow it" reference field still links to would only
  # refuse its purge — as a failed job, every night. The trigger leaves it out.
  test "the nightly trigger skips old trash a restrict field still links to" do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "purge-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    name = "lead_#{System.unique_integer([:positive])}"

    CMS.create_field_definition!(
      %{
        content_type: :post,
        name: name,
        label: "Lead",
        field_type: :reference,
        target_type: "page",
        on_target_delete: :restrict
      },
      actor: admin
    )

    linked =
      CMS.create_page!(%{title: "Linked", slug: "purge-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    referrer =
      CMS.create_post!(
        %{
          title: "Referrer",
          slug: "purge-#{System.unique_integer([:positive])}",
          custom_fields: %{name => linked.id}
        },
        actor: admin
      )

    month_ago = DateTime.add(DateTime.utc_now(), -31, :day)
    :ok = CMS.destroy_page!(linked, actor: admin)

    # Backdated the way `trashed_page/1` seeds one: no update action takes a
    # trashed row (#2332).
    linked =
      CMS.list_trashed_pages!(authorize?: false)
      |> Enum.find(&(&1.id == linked.id))
      |> Ash.Seed.update!(%{archived_at: month_ago})

    old = trashed_page(month_ago)

    result = run_purge()

    trashed_ids = Enum.map(CMS.list_trashed_pages!(authorize?: false), & &1.id)
    refute old.id in trashed_ids
    assert linked.id in trashed_ids
    refute failed?(result)

    # Unlinked, it goes on the next run.
    CMS.update_post!(referrer, %{custom_fields: %{name => ""}}, actor: admin)
    run_purge()

    refute linked.id in Enum.map(CMS.list_trashed_pages!(authorize?: false), & &1.id)
  end

  defp run_purge do
    AshOban.schedule_and_run_triggers({KilnCMS.CMS.Page, :purge_trashed},
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )
  end

  defp failed?(result), do: Map.get(result, :failure, 0) > 0 or Map.get(result, :discard, 0) > 0
end
