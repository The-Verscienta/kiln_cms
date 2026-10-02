defmodule KilnCMS.Search.SearchableFieldsTest do
  @moduledoc """
  #1585: a custom field flagged `searchable` is indexed with the record's
  body text, so full-text search finds a record by a structured identity
  field — a Han name, a Latin binomial — that its prose never repeats.
  """
  # async: false — toggles the global `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.SearchableFields
  alias KilnCMS.Search

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Search, original) end)
    Application.put_env(:kiln_cms, KilnCMS.Search, Keyword.put(original, :semantic, false))
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sf-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "sf-#{System.unique_integer([:positive])}"

  defp field(admin, name, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, name: name, label: name, field_type: :string}, attrs),
      actor: admin
    )
  end

  defp keyword_hit?(query, record, opts) do
    case Search.hybrid(:page, query, opts) |> Enum.find(&(&1.id == record.id)) do
      nil -> false
      hit -> :keyword in Search.hit_legs(hit)
    end
  end

  defp anonymous_ids(query) do
    query
    |> Search.global(authorize?: true, sections: [:pages])
    |> Map.fetch!(:pages)
    |> Enum.map(& &1.id)
  end

  test "a searchable field's value is found by the keyword leg; an unflagged one is not" do
    admin = admin()
    field(admin, "chinese_name", %{searchable: true})
    field(admin, "internal_code")

    herb =
      CMS.create_page!(
        %{
          title: "Wu Zhu Yu",
          slug: slug(),
          body_markdown: "A warming herb for the middle burner.",
          custom_fields: %{"chinese_name" => "吴茱萸", "internal_code" => "zorptastic"}
        },
        actor: admin
      )

    assert herb.search_text =~ "吴茱萸"
    refute herb.search_text =~ "zorptastic"
    assert keyword_hit?("吴茱萸", herb, actor: admin)
    refute keyword_hit?("zorptastic", herb, actor: admin)
  end

  test "anonymous search finds a published record by it and never a draft" do
    admin = admin()
    field(admin, "latin_name", %{searchable: true})

    published =
      CMS.create_page!(
        %{title: "Huang Qi", slug: slug(), custom_fields: %{"latin_name" => "Astragalus quuxensis"}},
        actor: admin
      )
      |> then(&CMS.publish_page!(&1, %{}, actor: admin))

    draft =
      CMS.create_page!(
        %{title: "Dang Shen", slug: slug(), custom_fields: %{"latin_name" => "Codonopsis quuxensis"}},
        actor: admin
      )

    KilnCMS.DataCase.drain_oban()

    ids = anonymous_ids("quuxensis")
    assert published.id in ids
    refute draft.id in ids
  end

  test "flagging a field re-indexes the type's published documents, and deleting it un-indexes them" do
    admin = admin()
    definition = field(admin, "trade_name")

    page =
      CMS.create_page!(
        %{title: "Widget", slug: slug(), custom_fields: %{"trade_name" => "Frobnicator"}},
        actor: admin
      )
      |> then(&CMS.publish_page!(&1, %{}, actor: admin))

    KilnCMS.DataCase.drain_oban()
    refute page.id in anonymous_ids("frobnicator")

    definition = CMS.update_field_definition!(definition, %{searchable: true}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    assert page.id in anonymous_ids("frobnicator")

    CMS.destroy_field_definition!(definition, actor: admin)
    KilnCMS.DataCase.drain_oban()
    refute page.id in anonymous_ids("frobnicator")
  end

  describe "texts/2" do
    test "strings and numbers, depth first, without map keys or ids, in position order" do
      definitions = [
        %{name: "common_names", searchable: true, position: 2},
        %{name: "hidden", searchable: false, position: 0},
        %{name: "dose", searchable: true, position: 1},
        %{name: "flag", searchable: true, position: 3}
      ]

      fields = %{
        "common_names" => [
          %{"language" => "English", "name" => "Evodia fruit"},
          %{"id" => "6f1c", "language" => "Chinese", "name" => "吴茱萸"}
        ],
        "hidden" => "secret",
        "dose" => 3,
        "flag" => true
      }

      assert SearchableFields.texts(fields, definitions) ==
               ["3", "English", "Evodia fruit", "Chinese", "吴茱萸"]
    end

    test "nothing flagged, nothing indexed" do
      assert SearchableFields.texts(%{"a" => "b"}, [%{name: "a", searchable: false, position: 0}]) ==
               []

      assert SearchableFields.texts(nil, []) == []
    end
  end
end
