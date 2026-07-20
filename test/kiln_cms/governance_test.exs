defmodule KilnCMS.GovernanceTest do
  @moduledoc "Governance trail assembly (#352)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Governance

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gov-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "gov-#{System.unique_integer([:positive])}"

  test "assembles the trail: version timeline, publish points, and consents" do
    admin = admin()
    post = CMS.create_post!(%{title: "Guidance", slug: slug()}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    CMS.record_consent!(
      %{content_type: "post", content_id: post.id, kind: :reviewer_signoff, grantor: "Dr. Ada"},
      actor: admin
    )

    trail = Governance.trail("post", post.id, KilnCMS.Accounts.default_org_id())

    assert trail.item.title == "Guidance"
    assert trail.item.state == :published
    # A create + a publish version, publish flagged and captured as a publish point.
    assert Enum.any?(trail.timeline, & &1.publish?)
    assert trail.publishes != []
    assert [consent] = trail.consents
    assert consent.kind == :reviewer_signoff
  end

  test "trail/3 is nil for unknown content" do
    org = KilnCMS.Accounts.default_org_id()
    assert Governance.trail("post", Ecto.UUID.generate(), org) == nil
    assert Governance.trail("nope", Ecto.UUID.generate(), org) == nil
  end

  test "content_index lists content" do
    admin = admin()
    CMS.create_post!(%{title: "Indexed", slug: slug()}, actor: admin)

    assert Enum.any?(
             Governance.content_index(KilnCMS.Accounts.default_org_id()),
             &(&1.title == "Indexed" and &1.type == "post")
           )
  end

  test "timeline events carry the acting user (#352 'who')" do
    admin = admin()
    post = CMS.create_post!(%{title: "Attributed", slug: slug()}, actor: admin)
    CMS.update_post!(post, %{title: "Attributed v2"}, actor: admin)

    trail = Governance.trail("post", post.id, KilnCMS.Accounts.default_org_id())

    assert length(trail.timeline) >= 2
    # No display name on the seeded admin → the email is the display string.
    assert Enum.all?(trail.timeline, &(&1.actor == to_string(admin.email)))
  end

  test "dynamic (D17) entries appear in the index and have a trail" do
    admin = admin()
    org = KilnCMS.Accounts.default_org_id()
    name = "govdyn#{System.unique_integer([:positive])}"
    td = CMS.create_type_definition!(%{name: name, label: "Gov Dyn"}, actor: admin)

    entry =
      CMS.create_entry!(
        %{title: "Dynamic Guidance", slug: slug(), type_definition_id: td.id},
        actor: admin
      )

    # Indexed under the PUBLIC type name, not the storage tier's "entry".
    assert Enum.any?(Governance.content_index(org), &(&1.type == name and &1.id == entry.id))

    trail = Governance.trail(name, entry.id, org)
    assert trail.item.title == "Dynamic Guidance"
    assert trail.item.dynamic?
    assert trail.timeline != []

    # The entry tier is shared: an entry must not resolve under ANOTHER
    # dynamic type's name.
    other = CMS.create_type_definition!(%{name: name <> "b", label: "Other"}, actor: admin)
    assert Governance.trail(other.name, entry.id, org) == nil
  end
end
