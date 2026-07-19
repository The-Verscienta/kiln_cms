defmodule KilnCMS.StrictTenancyTest do
  @moduledoc """
  Smoke suite for the strict (`global?: false`) tenancy build (#419 PR 3).

  Runs ONLY on the strict CI leg (`KILN_STRICT_TEST=1` — see test_helper.exs):
  the main suite predates strict tenancy and exercises the fail-open build.
  Everything here asserts the properties the flip exists for.
  """
  use KilnCMS.DataCase, async: true

  @moduletag :strict_tenancy

  alias KilnCMS.CMS
  alias KilnCMS.Newsletter

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "strict-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org_id, do: KilnCMS.Accounts.default_org_id()

  defp slug, do: "strict-#{System.unique_integer([:positive])}"

  test "the strict build is actually strict" do
    refute Ash.Resource.Info.multitenancy_global?(KilnCMS.CMS.Page)
    refute Ash.Resource.Info.multitenancy_global?(KilnCMS.Newsletter.Subscriber)
    refute Ash.Resource.Info.multitenancy_global?(KilnCMS.CMS.WebhookEndpoint)
  end

  test "tenant-less actions on org-scoped resources are refused" do
    actor = admin()

    # The refusal may surface as an error return OR a raise from an internal
    # change's own tenanted read during changeset build — both fail closed.
    result =
      try do
        CMS.create_page(%{title: "No tenant", slug: slug()}, actor: actor)
      rescue
        error -> {:error, error}
      end

    assert {:error, error} = result
    assert Exception.message(error) =~ ~r/tenant/i

    assert {:error, %Ash.Error.Invalid{}} = CMS.list_pages(actor: actor)
  end

  test "tenanted flows work end to end (create → publish → delivery read)" do
    actor = admin()

    page =
      CMS.create_page!(%{title: "Strict page", slug: slug()}, actor: actor, tenant: org_id())

    published = CMS.publish_page!(page, %{}, actor: actor, tenant: org_id())
    assert published.state == :published

    assert [_ | _] =
             CMS.list_pages!(actor: actor, tenant: org_id())
             |> Enum.filter(&(&1.id == page.id))
  end

  test "the newsletter token lookups bypass tenancy; their writes re-scope" do
    {:ok, subscriber} =
      Newsletter.subscribe(%{email: "strict-#{System.unique_integer([:positive])}@example.com"},
        authorize?: false,
        tenant: org_id()
      )

    # Token-only lookup, deliberately tenant-less (multitenancy :bypass);
    # `authorize?: false` behind token verification, as the controller calls it.
    assert {:ok, found} =
             Newsletter.subscriber_by_confirm_token(subscriber.confirm_token,
               authorize?: false
             )

    assert found.id == subscriber.id

    assert {:ok, confirmed} =
             Newsletter.confirm_subscriber(found, authorize?: false, tenant: found.org_id)

    assert confirmed.status == :confirmed
  end

  test "version-touching changes run strict: autosave coalesce, restore, chain verify" do
    actor = admin()
    page = CMS.create_page!(%{title: "R1", slug: slug()}, actor: actor, tenant: org_id())

    # Autosave twice — CoalesceAutosaveVersions reads+destroys version twins.
    autosave = fn record, title ->
      record
      |> Ash.Changeset.for_update(:autosave, %{title: title}, actor: actor, tenant: org_id())
      |> Ash.update!()
    end

    page = autosave.(page, "R2")
    page = autosave.(page, "R3")

    # Publish — Chain.anchor folds the version chain (tenanted read) and
    # RecordPublishedVersion links the publish version.
    published = CMS.publish_page!(page, %{}, actor: actor, tenant: org_id())

    assert KilnCMS.Governance.Chain.verify(
             KilnCMS.CMS.Page,
             "page",
             published.id,
             published.org_id
           ) in [:verified, :unsigned]
  end

  test "the version twins remain readable through their tenanted source flow" do
    actor = admin()
    page = CMS.create_page!(%{title: "V1", slug: slug()}, actor: actor, tenant: org_id())
    {:ok, _} = CMS.update_page(page, %{title: "V2"}, actor: actor, tenant: org_id())

    require Ash.Query

    # The version twins inherit strict tenancy from their source — reads
    # carry the org like every other org-scoped resource.
    versions =
      KilnCMS.CMS.Page.Version
      |> Ash.Query.filter(version_source_id == ^page.id)
      |> Ash.read!(authorize?: false, tenant: org_id())

    assert length(versions) >= 2

    assert_raise Ash.Error.Invalid, ~r/tenant/i, fn ->
      KilnCMS.CMS.Page.Version
      |> Ash.Query.filter(version_source_id == ^page.id)
      |> Ash.read!(authorize?: false)
    end
  end
end
