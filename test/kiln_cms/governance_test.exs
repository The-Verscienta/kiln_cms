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
end
