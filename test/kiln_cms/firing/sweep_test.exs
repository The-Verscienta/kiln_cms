defmodule KilnCMS.Firing.SweepTest do
  @moduledoc "Re-fire sweep (#357): refresh every published document's artifacts."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Firing
  alias KilnCMS.Firing.{Engine, Sweep}

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sweep-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "sweep-#{System.unique_integer([:positive])}"

  test "re-fires published documents and skips drafts" do
    actor = admin()
    org = KilnCMS.Accounts.default_org_id()

    published =
      CMS.create_page!(
        %{title: "Old", slug: slug(), blocks: [%{type: :heading, content: "H", order: 0}]},
        actor: actor
      )

    published = CMS.publish_page!(published, actor: actor)
    KilnCMS.DataCase.drain_oban()

    draft = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: actor)

    # Simulate pre-deploy content: purge its artifacts, as if fired by an old
    # release that lacked today's surfaces.
    :ok = Engine.purge(org, :page, published.id)
    assert :error = Engine.read(org, :page, published.id, :json_ld)

    counts = Sweep.run()
    assert counts.page >= 1
    KilnCMS.DataCase.drain_oban()

    # All four surfaces are back for the published page…
    {:ok, artifacts} = Firing.artifacts_for(:page, published.id, authorize?: false)
    assert artifacts |> Enum.map(& &1.surface) |> Enum.sort() == [:json, :json_ld, :llm, :web]

    # …and the draft never fired.
    {:ok, none} = Firing.artifacts_for(:page, draft.id, authorize?: false)
    assert none == []
  end

  test "sweeps the dynamic entry tier too" do
    actor = admin()
    org = KilnCMS.Accounts.default_org_id()

    definition =
      CMS.create_type_definition!(
        %{name: "swp#{System.unique_integer([:positive])}", label: "Sweepable"},
        actor: actor
      )

    entry =
      CMS.ContentTypes.create!(definition.name, %{title: "Swept", slug: slug()}, actor: actor)

    {:ok, entry} = CMS.ContentTypes.transition(definition.name, "publish", entry, actor: actor)
    KilnCMS.DataCase.drain_oban()

    :ok = Engine.purge(org, :entry, entry.id)

    counts = Sweep.run()
    assert counts.entry >= 1
    KilnCMS.DataCase.drain_oban()

    assert {:ok, _} = Engine.read(org, :entry, entry.id, :json_ld)
  end
end
