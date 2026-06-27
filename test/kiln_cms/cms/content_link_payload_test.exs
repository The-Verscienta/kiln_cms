defmodule KilnCMS.CMS.ContentLinkPayloadTest do
  @moduledoc """
  Coverage for payload-carrying ContentLinks: a named relation (`kind`) that
  carries per-link data in `metadata`/`label`, reachable through the
  `content_links` / `incoming_links` relationships on content — the lightweight
  alternative to a bespoke typed join resource per relation.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "cl-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp page(title) do
    Ash.Seed.seed!(KilnCMS.CMS.Page, %{
      title: title,
      slug: "cl-#{System.unique_integer([:positive])}",
      locale: "en",
      state: :published
    })
  end

  test "a link carries kind, label and a metadata payload" do
    actor = admin()
    formula = page("Formula")
    ingredient = page("Ingredient")

    link =
      CMS.create_content_link!(
        %{
          source_id: formula.id,
          target_id: ingredient.id,
          kind: :ingredient,
          label: "Chief herb",
          position: 1,
          metadata: %{"dosage_g" => 9, "role" => "jun"}
        },
        actor: actor
      )

    assert link.kind == :ingredient
    assert link.label == "Chief herb"
    assert link.metadata == %{"dosage_g" => 9, "role" => "jun"}
  end

  test "payload is reachable from the source via content_links" do
    actor = admin()
    formula = page("Formula")
    ingredient = page("Ingredient")

    CMS.create_content_link!(
      %{
        source_id: formula.id,
        target_id: ingredient.id,
        kind: :ingredient,
        metadata: %{"dosage_g" => 6, "role" => "chen"}
      },
      actor: actor
    )

    loaded = CMS.get_page!(formula.id, load: [:content_links], actor: actor)
    [link] = loaded.content_links

    assert link.target_id == ingredient.id
    assert link.metadata["role"] == "chen"
  end

  test "payload is reachable from the target via incoming_links" do
    actor = admin()
    formula = page("Formula")
    ingredient = page("Ingredient")

    CMS.create_content_link!(
      %{
        source_id: formula.id,
        target_id: ingredient.id,
        kind: :ingredient,
        metadata: %{"x" => 1}
      },
      actor: actor
    )

    loaded = CMS.get_page!(ingredient.id, load: [:incoming_links], actor: actor)
    [link] = loaded.incoming_links

    assert link.source_id == formula.id
    assert link.metadata == %{"x" => 1}
  end

  test "metadata defaults to an empty map" do
    actor = admin()
    a = page("A")
    b = page("B")

    link = CMS.create_content_link!(%{source_id: a.id, target_id: b.id}, actor: actor)

    assert link.metadata == %{}
    assert link.kind == :related
  end
end
