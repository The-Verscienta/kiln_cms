defmodule KilnCMS.CMS.HousekeepingAuthorizationTest do
  @moduledoc """
  What the CMS's helper modules are *authorized* to do now that they run as
  `KilnCMS.CMS.Housekeeping.system/1` instead of `authorize?: false` (#1659
  batch 10c), and that the reads they decide on fail CLOSED when the grant is
  gone.

  Every grant has a refusal beside it: the release worker marks a release and
  its items, which no person (admin included) may do; it may abandon a claim
  but not start or schedule one; it lists a release's items by status and
  nothing else; it reads the editorial settings but cannot save them.

  The fail-closed tests take the grant away with `Housekeeping.with_actor(nil,
  …)` and assert on what a *filtered* read could not produce — a raise, a
  refused job, the release and its content untouched — never on `{:ok, _}`.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.EditorialSettings
  alias KilnCMS.CMS.Housekeeping
  alias KilnCMS.CMS.NameFields
  alias KilnCMS.CMS.Releases
  alias KilnCMS.CMS.Slugs
  alias KilnCMS.CMS.TaskSettings
  alias KilnCMS.CMS.Workers.ReleaseWorker
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])
  defp system, do: Housekeeping.system(:releases)
  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "chk-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp without_grant(fun), do: Housekeeping.with_actor(nil, fun)

  test "system/1 is a system actor carrying the caller's label" do
    assert %SystemActor{subsystem: :releases} = Housekeeping.system(:releases)
    assert %SystemActor{subsystem: :cms_registry} = Housekeeping.system(:cms_registry)
  end

  test "with_actor/2 restores the real actor afterwards, even when the block raises" do
    assert_raise RuntimeError, fn -> without_grant(fn -> raise "boom" end) end
    assert %SystemActor{subsystem: :releases} = Housekeeping.system(:releases)
    assert without_grant(fn -> Housekeeping.system(:releases) end) == nil
  end

  describe "releases — the go-live worker's bookkeeping" do
    setup do
      admin = user(:admin)
      page = CMS.create_page!(%{title: "Launch #{uniq()}", slug: "chk-#{uniq()}"}, actor: admin)
      release = CMS.create_release!(%{name: "Campaign #{uniq()}"}, actor: admin)

      item =
        CMS.add_release_item!(
          %{release_id: release.id, content_type: "page", content_id: page.id},
          actor: admin
        )

      %{admin: admin, page: page, release: release, item: item}
    end

    defp claim(release, admin), do: CMS.start_release!(release, %{}, actor: admin)
    defp reload(release), do: CMS.get_release!(release.id, authorize?: false)
    defp reload_page(page), do: CMS.get_page!(page.id, authorize?: false)

    test "the system may read the release, but not list or browse releases",
         %{release: release} do
      assert {:ok, %{id: id}} = CMS.get_release(release.id, actor: system(), tenant: org_id())
      assert id == release.id

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.list_editable_releases(
                 actor: system(),
                 tenant: org_id(),
                 authorize_with: :error
               )
    end

    test "the system may record the outcome; an admin may not",
         %{release: release, admin: admin} do
      claimed = claim(release, admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.mark_release_published(claimed, %{}, actor: admin)

      assert {:ok, %{state: :published}} =
               CMS.mark_release_published(claimed, %{}, actor: system(), tenant: org_id())
    end

    test "the system may abandon a claim, but not start or schedule a release",
         %{release: release, admin: admin} do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.start_release(release, %{}, actor: system(), tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.schedule_release(
                 release,
                 %{scheduled_at: DateTime.add(DateTime.utc_now(), 3600)},
                 actor: system(),
                 tenant: org_id()
               )

      claimed = claim(release, admin)

      assert {:ok, %{state: :failed}} =
               CMS.abandon_release(claimed, %{}, actor: system(), tenant: org_id())
    end

    test "the system may list items by status and mark them; an admin may not mark",
         %{release: release, item: item, admin: admin} do
      assert [%{id: id}] =
               CMS.list_release_items_with_status!(release.id, :pending,
                 actor: system(),
                 tenant: org_id()
               )

      assert id == item.id

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.mark_release_item_applied(item, %{prior_state: :draft}, actor: admin)

      assert {:ok, %{status: :applied}} =
               CMS.mark_release_item_applied(item, %{prior_state: :draft},
                 actor: system(),
                 tenant: org_id()
               )
    end

    test "the system may not compose a release or read items another way",
         %{release: release, item: item} do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.cancel_release_item(item, %{}, actor: system(), tenant: org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.list_release_items_for(release.id,
                 actor: system(),
                 tenant: org_id(),
                 authorize_with: :error
               )
    end

    test "go-live publishes through the grants", %{release: release, admin: admin, page: page} do
      assert {:ok, %{state: :published}} = release |> claim(admin) |> Releases.publish()
      assert reload_page(page).state == :published
    end

    test "with the grant gone go-live RAISES rather than publish an empty release",
         %{release: release, admin: admin, page: page} do
      claimed = claim(release, admin)

      assert_raise Ash.Error.Forbidden, fn ->
        without_grant(fn -> Releases.publish(claimed) end)
      end

      assert reload(release).state == :publishing
      assert reload_page(page).state == :draft
    end

    test "with the grant gone rollback RAISES rather than mark nothing rolled back",
         %{release: release, admin: admin, page: page} do
      {:ok, published} = release |> claim(admin) |> Releases.publish()
      rolling = CMS.start_release_rollback!(published, %{}, actor: admin)

      assert_raise Ash.Error.Forbidden, fn ->
        without_grant(fn -> Releases.roll_back(rolling) end)
      end

      assert reload(release).state == :rolling_back
      assert reload_page(page).state == :published
    end

    test "with the grant gone the worker records a refusal, not a vanished release",
         %{release: release, admin: admin, page: page} do
      claimed = claim(release, admin)
      job = %Oban.Job{args: %{"release_id" => claimed.id, "org_id" => org_id()}}

      assert {:error, %Ash.Error.Forbidden{}} =
               without_grant(fn -> ReleaseWorker.perform(job) end)

      assert reload(release).state == :publishing
      assert reload_page(page).state == :draft
    end
  end

  describe "SiteEditorialSettings — asked from inside a publish" do
    setup do
      admin = user(:admin)

      CMS.save_site_editorial_settings!(
        %{editors_can_publish: true, auto_complete_tasks_on_publish: false},
        actor: admin
      )

      %{admin: admin}
    end

    test "the system reads the settings, and may not save them" do
      assert EditorialSettings.editors_can_publish?(org_id())
      refute TaskSettings.site_default(org_id())
      assert EditorialSettings.chosen?(org_id())

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.save_site_editorial_settings(%{editors_can_publish: false},
                 actor: Housekeeping.system(:cms_settings),
                 tenant: org_id()
               )
    end

    test "with the grant gone editors may NOT publish, though the row says they may" do
      refute without_grant(fn -> EditorialSettings.editors_can_publish?(org_id()) end)
    end

    test "with the grant gone the task default RAISES rather than answer the shipped one" do
      assert_raise Ash.Error.Forbidden, fn ->
        without_grant(fn -> TaskSettings.site_default(org_id()) end)
      end
    end
  end

  describe "HealthSummary — read as the person looking" do
    test "an admin sees the overdue record; an actor without its grant does not" do
      admin = user(:admin)
      title = "Stale #{uniq()}"

      page =
        CMS.create_page!(
          %{title: title, slug: "chk-h-#{uniq()}", review_after_days: 5, audience: :member},
          actor: admin
        )
        |> CMS.publish_page!(%{}, actor: admin)

      page
      |> Ash.Changeset.for_update(:backdate_published_at, %{
        published_at: DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)
      })
      |> Ash.update!(authorize?: false)

      titles = fn actor ->
        org_id()
        |> KilnCMS.CMS.HealthSummary.for_org(actor, 500)
        |> Map.fetch!(:worst)
        |> Enum.map(& &1.title)
      end

      assert title in titles.(admin)
      refute title in titles.(SystemActor.new(:test))
      refute Enum.any?(KilnCMS.CMS.HealthSummary.csv_rows(org_id(), SystemActor.new(:test)))
    end
  end

  describe "the field and type registry" do
    setup do
      admin = user(:admin)
      name = "hk#{uniq()}"

      definition =
        CMS.create_type_definition!(%{name: name, label: "Housekeeping"}, actor: admin)

      %{admin: admin, definition: definition}
    end

    test "a refused type registry read raises rather than listing no dynamic types",
         %{definition: definition} do
      assert Enum.any?(ContentTypes.dynamic_all(org_id()), &(&1.definition.id == definition.id))

      assert_raise Ash.Error.Forbidden, fn ->
        without_grant(fn -> ContentTypes.dynamic_all(org_id()) end)
      end
    end

    test "a refused name-field read raises rather than finding no name fields" do
      assert is_map(NameFields.all(org_id()))

      assert_raise Ash.Error.Forbidden, fn ->
        without_grant(fn -> NameFields.all(org_id()) end)
      end
    end

    test "a dynamic type's slug pattern read raises rather than falling back to the default",
         %{admin: admin} do
      patterned =
        CMS.create_type_definition!(
          %{name: "hkp#{uniq()}", label: "Patterned", slug_pattern: "[yyyy]-[title]"},
          actor: admin
        )

      changeset =
        KilnCMS.CMS.Entry
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attribute(:type_definition_id, patterned.id)
        |> Ash.Changeset.set_tenant(org_id())

      assert Slugs.pattern_for(changeset, :slug) == "[yyyy]-[title]"

      assert_raise Ash.Error.Forbidden, fn ->
        without_grant(fn -> Slugs.pattern_for(changeset, :slug) end)
      end
    end

    test "a [field:…] slug token's registry read raises rather than reading no fields" do
      changeset =
        KilnCMS.CMS.Page
        |> Ash.Changeset.new()
        |> Ash.Changeset.force_change_attribute(:custom_fields, %{"code" => "abc"})
        |> Ash.Changeset.set_tenant(org_id())

      assert %{custom_fields: %{"code" => "abc"}} =
               Slugs.changeset_context(changeset, "[field:code]")

      assert_raise Ash.Error.Forbidden, fn ->
        without_grant(fn -> Slugs.changeset_context(changeset, "[field:code]") end)
      end
    end

    test "a type token read for the editor preview raises when refused, not degrade" do
      ct = ContentTypes.get(:page)
      assert Slugs.descriptor_token_definitions(ct, "[no-such-token]", :slug, org_id()) == []

      assert_raise Ash.Error.Forbidden, fn ->
        without_grant(fn ->
          Slugs.descriptor_token_definitions(ct, "[no-such-token]", :slug, org_id())
        end)
      end
    end

    test "an anonymous custom_filter still resolves the registry, and a refusal is an error",
         %{admin: admin} do
      field = "hkf#{uniq()}"

      CMS.create_field_definition!(
        %{content_type: :page, name: field, label: "Code", field_type: :string},
        actor: admin
      )

      page =
        CMS.create_page!(
          %{title: "Filtered", slug: "chk-f-#{uniq()}", custom_fields: %{field => "x"}},
          actor: admin
        )

      CMS.publish_page!(page, %{}, actor: admin)

      assert [%{id: id}] = CMS.list_pages!(%{custom_filter: %{field => "x"}}, actor: nil)
      assert id == page.id

      # Never the unfiltered list, and never the "unknown custom field" 400 a
      # filtered-to-nothing registry would produce: the refusal itself.
      assert_raise Ash.Error.Forbidden, fn ->
        without_grant(fn -> CMS.list_pages(%{custom_filter: %{field => "x"}}) end)
      end
    end
  end
end
