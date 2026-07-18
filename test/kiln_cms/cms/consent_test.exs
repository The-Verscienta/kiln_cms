defmodule KilnCMS.CMS.ConsentTest do
  @moduledoc "Editorial consent linking + the config-gated publish gate (#356)."
  # async: false — the publish-gate test toggles global :consent config.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "consent-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "consent-#{System.unique_integer([:positive])}"

  test "records consent linked to a content item and lists it" do
    admin = user(:admin)
    id = Ecto.UUID.generate()

    {:ok, consent} =
      CMS.record_consent(
        %{
          content_type: "post",
          content_id: id,
          kind: :reviewer_signoff,
          grantor: "Dr. Ada",
          reference: "REVIEW-1234"
        },
        actor: admin
      )

    assert consent.recorded_by_id == admin.id
    assert consent.kind == :reviewer_signoff

    assert [listed] = CMS.list_consents_for!("post", id, actor: admin)
    assert listed.id == consent.id
  end

  test "editors may record consent; viewers may not" do
    editor = user(:editor)
    viewer = user(:viewer)
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             CMS.record_consent(%{content_type: "post", content_id: id, kind: :source_release},
               actor: editor
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             CMS.record_consent(%{content_type: "post", content_id: id, kind: :source_release},
               actor: viewer
             )
  end

  test "with no gate configured (default), publish needs no consent" do
    admin = user(:admin)
    post = CMS.create_post!(%{title: "Ungated", slug: slug()}, actor: admin)
    assert {:ok, _} = CMS.publish_post(post, %{}, actor: admin)
  end

  test "the gate blocks publish when a required consent is missing, and clears once recorded" do
    Application.put_env(:kiln_cms, :consent, required_before_publish: [:reviewer_signoff])
    on_exit(fn -> Application.delete_env(:kiln_cms, :consent) end)

    admin = user(:admin)
    post = CMS.create_post!(%{title: "Medical guidance", slug: slug()}, actor: admin)

    assert {:error, error} = CMS.publish_post(post, %{}, actor: admin)
    assert Exception.message(error) =~ "consent"

    CMS.record_consent!(
      %{content_type: "post", content_id: post.id, kind: :reviewer_signoff, grantor: "Dr. Ada"},
      actor: admin
    )

    assert {:ok, published} = CMS.publish_post(post, %{}, actor: admin)
    assert published.state == :published
  end
end
