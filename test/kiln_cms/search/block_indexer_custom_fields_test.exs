defmodule KilnCMS.Search.BlockIndexerCustomFieldsTest do
  @moduledoc """
  The block index reads a document's **searchable** custom fields as one more
  input, so "Similar content" (near-duplicates and tag suggestions) compares
  what a record says in its fields, not only in its body — and a record whose
  text lives entirely in its fields is not told to "add some content".
  """
  # async: false — swaps the global embedder in the `KilnCMS.Search` app env.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.{CMS, SearchIndex}
  alias KilnCMS.Search.{BlockIndexer, VectorCache}

  setup do
    original = Application.get_env(:kiln_cms, KilnCMS.Search, [])

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Search, original)
      Cachex.clear(VectorCache.cache_name())
    end)

    Application.put_env(
      :kiln_cms,
      KilnCMS.Search,
      Keyword.merge(original, KilnCMS.StubEmbedder.search_env())
    )

    admin =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "bicf-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    for {name, attrs} <- [{"latin_name", %{searchable: true}}, {"internal_code", %{}}] do
      CMS.create_field_definition!(
        Map.merge(%{content_type: :page, name: name, label: name, field_type: :string}, attrs),
        actor: admin
      )
    end

    %{admin: admin}
  end

  defp page(admin, attrs) do
    CMS.create_page!(
      Map.merge(%{title: "Herb", slug: "bicf-#{System.unique_integer([:positive])}"}, attrs),
      actor: admin
    )
  end

  defp stored_keys(doc) do
    SearchIndex.block_embeddings_for!(:page, doc.id,
      actor: KilnCMS.SystemActor.new(:search),
      tenant: doc.org_id
    )
    |> Map.new(&{&1.block_key, &1.block_type})
  end

  test "a searchable field is an embedding input; an unflagged one is not", %{admin: admin} do
    doc =
      page(admin, %{
        blocks:
          KilnCMS.TypedFixtures.typed_blocks([
            %{type: :heading, content: "A warming herb", order: 0}
          ]),
        custom_fields: %{"latin_name" => "Tetradium ruticarpum", "internal_code" => "zorptastic"}
      })

    inputs = BlockIndexer.embedding_inputs(doc)

    assert inputs == ["Herb\n\nA warming herb", "Herb\n\nTetradium ruticarpum"]
    refute Enum.any?(inputs, &(&1 =~ "zorptastic"))
  end

  test "a document with no blocks but a searchable field still has something to compare", %{
    admin: admin
  } do
    doc = page(admin, %{blocks: [], custom_fields: %{"latin_name" => "Tetradium ruticarpum"}})

    assert BlockIndexer.embedding_inputs(doc) == ["Herb\n\nTetradium ruticarpum"]

    blank = page(admin, %{blocks: [], custom_fields: %{"internal_code" => "zorptastic"}})
    assert BlockIndexer.embedding_inputs(blank) == []
  end

  test "reindex stores the fields under their own key, and prunes it once they are emptied", %{
    admin: admin
  } do
    doc =
      page(admin, %{
        blocks:
          KilnCMS.TypedFixtures.typed_blocks([
            %{type: :heading, content: "A warming herb", order: 0}
          ]),
        custom_fields: %{"latin_name" => "Tetradium ruticarpum"}
      })

    assert {:ok, 2} = BlockIndexer.reindex(doc)
    assert %{"custom-fields" => :custom} = stored_keys(doc)

    # Unchanged text is not re-embedded.
    assert {:ok, 0} = BlockIndexer.reindex(doc)

    cleared = CMS.update_page!(doc, %{custom_fields: %{"latin_name" => ""}}, actor: admin)

    assert {:ok, 0} = BlockIndexer.reindex(cleared)
    refute Map.has_key?(stored_keys(cleared), "custom-fields")
    assert map_size(stored_keys(cleared)) == 1
  end
end
