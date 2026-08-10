defmodule KilnCMS.CMS.SlugsDescriptorsTest do
  @moduledoc """
  `descriptors_for_records/1` is the shared memo for `PublicPath` and
  `EffectiveSeo` (#1138): one registry lookup per distinct type, not per row.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Slugs

  setup do
    KilnCMS.Cache.bust_published()
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "slug-desc-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  test "returns one descriptor per record, memoized on type identity" do
    actor = admin()
    name = "guide#{uniq()}"

    defn =
      CMS.create_type_definition!(
        %{name: name, label: "Guide", plural_label: name, path_segment: name},
        actor: actor
      )

    e1 =
      CMS.create_entry!(
        %{type_definition_id: defn.id, title: "One", slug: "one-#{uniq()}"},
        actor: actor
      )

    e2 =
      CMS.create_entry!(
        %{type_definition_id: defn.id, title: "Two", slug: "two-#{uniq()}"},
        actor: actor
      )

    assert Slugs.descriptors_for_records([]) == []

    [d1, d2] = Slugs.descriptors_for_records([e1, e2])
    assert d1
    assert d1 === d2
    assert d1.definition.id == defn.id
  end
end
