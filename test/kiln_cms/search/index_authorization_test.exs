defmodule KilnCMS.Search.IndexAuthorizationTest do
  @moduledoc """
  The semantic index tables run under their policies as
  `%KilnCMS.SystemActor{subsystem: :search}` rather than around them (#1402).

  `BlockEmbedding` and `TagEmbedding` are internal indexes: the indexer is the
  only writer either has ever had, and whether a *caller* may see a hit is
  decided one tier up, when the matching document or tag is hydrated under
  their own authorization. Removing a `KilnCMS.Checks.SystemActor` clause from
  either resource must turn a test here red.

  The negatives matter as much: naming the indexer in the policy must not have
  opened a write path for anybody else, and must not have handed the system
  actor the corpus — the search workers' *content* reads keep their bypass
  precisely because it would.
  """
  use KilnCMS.DataCase, async: true

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.Search.BlockEmbedding
  alias KilnCMS.Search.TagEmbedding
  alias KilnCMS.SearchIndex
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])

  defp org_id, do: Accounts.default_org_id()

  defp system, do: SystemActor.new(:search)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sia-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp block_row(attrs \\ %{}) do
    Ash.Seed.seed!(
      BlockEmbedding,
      Map.merge(
        %{
          org_id: org_id(),
          document_type: :page,
          document_id: Ash.UUID.generate(),
          block_key: "block-#{uniq()}",
          block_type: :rich_text,
          content_hash: "hash-#{uniq()}",
          ancestor_context: "Draft-only prose"
        },
        attrs
      )
    )
  end

  defp tag do
    n = uniq()
    KilnCMS.CMS.create_tag!(%{name: "sia-tag-#{n}", slug: "sia-tag-#{n}"}, actor: user(:admin))
  end

  # A zero vector of the configured width — this file is about who may write
  # one, not about what it contains.
  defp vector, do: List.duplicate(0.0, KilnCMS.Search.Vector.dimensions())

  describe "BlockEmbedding — the indexer writes it, nobody else does" do
    test "the system actor upserts a row" do
      assert {:ok, %{id: id}} =
               SearchIndex.upsert_block_embedding(
                 %{
                   document_type: :page,
                   document_id: Ash.UUID.generate(),
                   block_key: "block-#{uniq()}",
                   block_type: :rich_text,
                   content_hash: "hash-#{uniq()}",
                   ancestor_context: "Indexed"
                 },
                 actor: system(),
                 tenant: org_id()
               )

      assert is_binary(id)
    end

    test "no person may write one, admin included" do
      for actor <- [nil, user(:viewer), user(:editor), user(:admin)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 SearchIndex.upsert_block_embedding(
                   %{
                     document_type: :page,
                     document_id: Ash.UUID.generate(),
                     block_key: "block-#{uniq()}",
                     block_type: :rich_text,
                     content_hash: "hash-#{uniq()}"
                   },
                   actor: actor,
                   tenant: org_id()
                 )
      end
    end

    test "the system actor destroys stale rows; an admin may not" do
      row = block_row()

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(row, actor: user(:admin), tenant: org_id())

      assert :ok = Ash.destroy(row, actor: system(), tenant: org_id())
    end

    test "the system actor reads the index; a consumer still does not" do
      row = block_row()

      assert {:ok, [%{id: id}]} =
               SearchIndex.block_embeddings_for(row.document_type, row.document_id,
                 actor: system(),
                 tenant: org_id()
               )

      assert id == row.id

      # The #565 tightening is untouched: `ancestor_context` is block text from
      # every indexed document, drafts included.
      assert {:ok, []} =
               SearchIndex.block_embeddings_for(row.document_type, row.document_id,
                 actor: nil,
                 tenant: org_id()
               )
    end
  end

  describe "TagEmbedding — same shape, for tag-name vectors" do
    test "the system actor upserts and reads; nobody else writes" do
      tag = tag()

      assert {:ok, _row} =
               SearchIndex.upsert_tag_embedding(
                 %{tag_id: tag.id, name: tag.name, embedded_at: DateTime.utc_now()},
                 actor: system(),
                 tenant: org_id()
               )

      assert {:ok, [%{tag_id: tag_id}]} =
               SearchIndex.tag_embeddings_for([tag.id], actor: system(), tenant: org_id())

      assert tag_id == tag.id

      assert {:error, %Ash.Error.Forbidden{}} =
               SearchIndex.upsert_tag_embedding(
                 %{tag_id: tag.id, name: tag.name, embedded_at: DateTime.utc_now()},
                 actor: user(:admin),
                 tenant: org_id()
               )
    end

    test "a consumer cannot read the table" do
      tag = tag()

      {:ok, _row} =
        SearchIndex.upsert_tag_embedding(
          %{tag_id: tag.id, name: tag.name, embedded_at: DateTime.utc_now()},
          actor: system(),
          tenant: org_id()
        )

      assert {:ok, []} = SearchIndex.tag_embeddings_for([tag.id], actor: nil, tenant: org_id())
    end
  end

  describe ":set_embedding — the second system-only content action" do
    test "the system actor may set a document vector, and nothing else" do
      document =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Indexed",
          slug: "sia-#{uniq()}",
          locale: "en",
          state: :published
        })

      assert {:ok, updated} =
               document
               |> Ash.Changeset.for_update(:set_embedding, %{embedding: vector()},
                 actor: system(),
                 tenant: org_id()
               )
               |> Ash.update()

      assert updated.embedded_at

      # Still no standing grant on the resource — the clause that admits this
      # actor is narrowed to the two system-only actions by `forbid_unless`.
      assert {:error, %Ash.Error.Forbidden{}} =
               document
               |> Ash.Changeset.for_update(:update, %{title: "Renamed"},
                 actor: system(),
                 tenant: org_id()
               )
               |> Ash.update()
    end
  end

  describe "what the search system actor deliberately cannot do" do
    test "it reads no content — which is why the workers' document reads keep a bypass" do
      draft =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Unpublished",
          slug: "sia-draft-#{uniq()}",
          locale: "en",
          state: :draft
        })

      assert {:ok, []} =
               KilnCMS.CMS.Page
               |> Ash.Query.filter(id == ^draft.id)
               |> Ash.read(actor: system(), tenant: org_id())
    end
  end
end
