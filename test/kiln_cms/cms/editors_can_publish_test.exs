defmodule KilnCMS.CMS.EditorsCanPublishTest do
  @moduledoc """
  The per-site "editors can publish" switch
  (`SiteEditorialSettings.editors_can_publish`, `Checks.EditorMayPublish`).

  Every actor here is an org **member** with the tier on that membership: a
  membership-less account off the default org resolves to `:none`, so an
  "editor is refused" test written with one would pass even if the gate
  admitted every editor.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.EditorialSettings
  alias KilnCMS.CMS.TaskSettings

  setup do
    org = seed_org()

    %{
      org: org,
      admin: member(org, :admin),
      editor: member(org, :editor),
      viewer: member(org, :viewer)
    }
  end

  describe "publishing" do
    test "by default an editor submits for review; an admin publishes", %{
      org: org,
      admin: admin,
      editor: editor
    } do
      page = page!(editor, org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.publish_page(page, %{}, actor: editor, tenant: org.id)

      assert {:ok, %{state: :published}} =
               CMS.publish_page(page, %{}, actor: admin, tenant: org.id)
    end

    test "once the site lets editors publish, an editor can", %{
      org: org,
      admin: admin,
      editor: editor
    } do
      allow_editors!(org, admin, true)
      page = page!(editor, org)

      assert {:ok, %{state: :published}} =
               CMS.publish_page(page, %{}, actor: editor, tenant: org.id)
    end

    test "turning it back off takes it away again", %{org: org, admin: admin, editor: editor} do
      allow_editors!(org, admin, true)
      allow_editors!(org, admin, false)
      page = page!(editor, org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.publish_page(page, %{}, actor: editor, tenant: org.id)
    end

    test "the switch is per site — another site's answer does not reach this one", %{
      org: org,
      editor: editor
    } do
      other = seed_org()
      allow_editors!(other, member(other, :admin), true)
      page = page!(editor, org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.publish_page(page, %{}, actor: editor, tenant: org.id)
    end

    test "a viewer cannot publish even where editors can", %{
      org: org,
      admin: admin,
      viewer: viewer
    } do
      allow_editors!(org, admin, true)
      page = page!(admin, org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.publish_page(page, %{}, actor: viewer, tenant: org.id)
    end
  end

  # The scheduler publishes whatever `scheduled_at` names through its bypass,
  # so the date itself has to carry the publish permission.
  describe "a publish date is a publish" do
    test "an editor cannot set one while publishing needs an admin", %{
      org: org,
      editor: editor
    } do
      page = page!(editor, org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_page(page, %{scheduled_at: tomorrow()}, actor: editor, tenant: org.id)
    end

    test "an editor can once editors may publish", %{org: org, admin: admin, editor: editor} do
      allow_editors!(org, admin, true)
      page = page!(editor, org)
      at = tomorrow()

      assert {:ok, updated} =
               CMS.update_page(page, %{scheduled_at: at}, actor: editor, tenant: org.id)

      assert DateTime.compare(updated.scheduled_at, at) == :eq
    end

    test "an editor can still edit a page an admin scheduled, leaving the date alone", %{
      org: org,
      admin: admin,
      editor: editor
    } do
      page = page!(admin, org, %{scheduled_at: tomorrow()})

      assert {:ok, updated} =
               CMS.update_page(page, %{title: "Retitled"}, actor: editor, tenant: org.id)

      assert updated.title == "Retitled"
      assert DateTime.compare(updated.scheduled_at, page.scheduled_at) == :eq
    end
  end

  describe "EditorialSettings" do
    test "no row, and no org, both answer no", %{org: org} do
      refute EditorialSettings.editors_can_publish?(org.id)
      refute EditorialSettings.editors_can_publish?(nil)
    end

    # `:save` is an upsert whose omitted columns arrive as their defaults — the
    # task switch saved alone would otherwise switch publishing back off.
    test "saving one column keeps the other", %{org: org, admin: admin} do
      allow_editors!(org, admin, true)

      assert {:ok, _} =
               EditorialSettings.save(%{auto_complete_tasks_on_publish: false},
                 actor: admin,
                 tenant: org.id
               )

      assert EditorialSettings.editors_can_publish?(org.id)
      refute TaskSettings.site_default(org.id)
    end

    test "only an admin may change it", %{org: org, editor: editor} do
      assert {:error, %Ash.Error.Forbidden{}} =
               EditorialSettings.save(%{editors_can_publish: true}, actor: editor, tenant: org.id)

      refute EditorialSettings.editors_can_publish?(org.id)
    end
  end

  defp seed_org do
    Ash.Seed.seed!(Accounts.Organization, %{
      name: "Publishing Site",
      slug: "pubswitch-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  # A global `:viewer` whose tier on `org` comes from the membership alone.
  defp member(org, tier) do
    user =
      Ash.Seed.seed!(Accounts.User, %{
        email: "pubswitch-#{tier}-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :viewer
      })

    Ash.Seed.seed!(Accounts.OrgMembership, %{
      user_id: user.id,
      organization_id: org.id,
      role: tier
    })

    user
  end

  defp page!(actor, org, attrs \\ %{}) do
    CMS.create_page!(
      Map.merge(
        %{title: "Switch", slug: "pubswitch-#{System.unique_integer([:positive])}"},
        attrs
      ),
      actor: actor,
      tenant: org.id
    )
  end

  defp allow_editors!(org, admin, value) do
    {:ok, _} = EditorialSettings.save(%{editors_can_publish: value}, actor: admin, tenant: org.id)
  end

  defp tomorrow, do: DateTime.add(DateTime.utc_now(), 1, :day)
end
