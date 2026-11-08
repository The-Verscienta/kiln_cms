defmodule KilnCMS.Search.PrivateFieldNeverIndexedTest do
  @moduledoc """
  A `private` custom field can be hidden from some editors by a read grant
  (#2281), but search and "Similar content" read the whole record without an
  actor. They stay leak-free only because a private field can never be
  searchable (`Validations.PrivateField`). This pins both halves: the
  definition is refused, and a stored private value reaches neither the
  keyword text nor the embedding inputs.
  """
  # async: false — private-field definitions are cached per org in a global cache.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.SearchableFields
  alias KilnCMS.Search.BlockIndexer

  @canary "CANARY-private-9d2e"

  setup do
    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "pfni-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: "latin_name",
        label: "Latin",
        field_type: :string,
        searchable: true
      },
      actor: admin
    )

    CMS.create_field_definition!(
      %{content_type: :page, name: "vault", label: "Vault", field_type: :string, private: true},
      actor: admin
    )

    %{admin: admin}
  end

  test "a field cannot be both private and searchable", %{admin: admin} do
    assert {:error, error} =
             CMS.create_field_definition(
               %{
                 content_type: :page,
                 name: "both",
                 label: "Both",
                 field_type: :string,
                 private: true,
                 searchable: true
               },
               actor: admin
             )

    assert Exception.message(error) =~ "searchable"
  end

  test "a stored private value is in neither the search text nor the embedding inputs", %{
    admin: admin
  } do
    doc =
      CMS.create_page!(
        %{
          title: "Herb",
          slug: "pfni-#{System.unique_integer([:positive])}",
          blocks: [],
          custom_fields: %{"latin_name" => "Tetradium ruticarpum", "vault" => @canary}
        },
        actor: admin
      )

    texts = SearchableFields.record_texts(doc)
    inputs = BlockIndexer.embedding_inputs(doc)

    # the searchable sibling proves the pipeline ran, so absence is not vacuous
    assert Enum.any?(texts, &(&1 =~ "Tetradium"))
    assert Enum.any?(inputs, &(&1 =~ "Tetradium"))

    refute Enum.any?(texts, &(&1 =~ @canary))
    refute Enum.any?(inputs, &(&1 =~ @canary))
  end
end
