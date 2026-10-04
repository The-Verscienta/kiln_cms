defmodule KilnCMS.CMS.PreviewGrantPolicyTest do
  @moduledoc """
  `KilnCMS.CMS.Checks.PreviewGrant` at the Ash level: a grant in the read's
  context admits its one record to the primary `:read`, and nothing more.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.PreviewGrant

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pgp-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp draft(actor, title \\ "Granted draft") do
    CMS.create_post!(
      %{title: title, slug: "pgp-#{System.unique_integer([:positive])}"},
      actor: actor
    )
  end

  defp grant_for(post, resource \\ KilnCMS.CMS.Post) do
    %PreviewGrant{type: "post", id: post.id, org_id: post.org_id, resource: resource}
  end

  defp read_ids(context, tenant) do
    KilnCMS.CMS.Post
    |> Ash.Query.set_context(context)
    |> Ash.read!(actor: nil, tenant: tenant)
    |> Enum.map(& &1.id)
  end

  test "the grant admits its draft to an anonymous read, and only it" do
    actor = admin()
    post = draft(actor)
    other = draft(actor, "Other draft")

    refute post.id in read_ids(%{}, post.org_id)

    ids = read_ids(PreviewGrant.context(grant_for(post)), post.org_id)
    assert post.id in ids
    refute other.id in ids
  end

  test "a plain map shaped like a grant authorizes nothing" do
    post = draft(admin())

    spoof = %{shared: %{kiln_preview_grant: Map.from_struct(grant_for(post))}}
    refute post.id in read_ids(spoof, post.org_id)
  end

  test "a grant naming another resource does not reach this one" do
    post = draft(admin())

    refute post.id in read_ids(
             PreviewGrant.context(grant_for(post, KilnCMS.CMS.Page)),
             post.org_id
           )
  end

  test "search never surfaces the draft through a grant" do
    post = draft(admin(), "Searchable granted draft")

    results =
      CMS.search_posts!("Searchable",
        actor: nil,
        tenant: post.org_id,
        context: PreviewGrant.context(grant_for(post))
      )

    refute Enum.any?(results, &(&1.id == post.id))
  end

  test "a grant is never a write credential" do
    post = draft(admin())

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.update_post(post, %{title: "Hijacked"},
               actor: nil,
               tenant: post.org_id,
               context: PreviewGrant.context(grant_for(post))
             )
  end

  test "a grant does not cross into another tenant" do
    post = draft(admin())

    org =
      Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
        name: "Org PGP",
        slug: "pgp-org-#{System.unique_integer([:positive])}",
        status: :active
      })

    refute post.id in read_ids(PreviewGrant.context(grant_for(post)), org.id)
  end
end
