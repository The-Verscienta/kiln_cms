defmodule KilnCMS.Firing.FirePathAuthorizationTest do
  @moduledoc """
  What the fire path is *authorized* to do, now that it runs as
  `%KilnCMS.SystemActor{subsystem: :firing}` instead of `authorize?: false`
  (#1402).

  Every test here is written so that removing the corresponding
  `KilnCMS.Checks.SystemActor` clause from the resource turns it red — a
  conversion that passes either way has converted nothing. The negative
  assertions matter just as much: admitting the system actor must not have
  opened a write path for anybody else.

  Deliberately *not* converted, and pinned as such at the bottom: the content
  reads in `Firing.Sweep` and `Firing.Delivery`. Granting the system actor a
  clause on the `Content` read policy would be a standing grant over the whole
  corpus, drafts included — wider than the single bypass it would replace.
  """
  use KilnCMS.DataCase, async: true

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.Firing
  alias KilnCMS.SystemActor

  defp uniq, do: System.unique_integer([:positive])

  defp org_id, do: Accounts.default_org_id()

  defp system, do: SystemActor.new(:firing)

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fpa-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp page(attrs \\ %{}) do
    Ash.Seed.seed!(
      KilnCMS.CMS.Page,
      Map.merge(
        %{title: "Fire path", slug: "fpa-#{uniq()}", locale: "en", state: :published},
        attrs
      )
    )
  end

  defp artifact(document, attrs \\ %{}) do
    Ash.Seed.seed!(
      Firing.PublishedArtifact,
      Map.merge(
        %{
          org_id: org_id(),
          document_type: :page,
          document_id: document.id,
          surface: :web,
          format_version: 1,
          body: %{"html" => "<p>fired</p>"},
          fired_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  describe "PublishedArtifact — the engine writes them, nobody else does" do
    test "the system actor upserts an artifact" do
      document = page()

      assert {:ok, %{id: id}} =
               Firing.upsert_artifact(
                 %{
                   document_type: :page,
                   document_id: document.id,
                   surface: :web,
                   format_version: 2,
                   body: %{"html" => "<p>x</p>"},
                   fired_at: DateTime.utc_now()
                 },
                 actor: system(),
                 tenant: org_id()
               )

      assert is_binary(id)
    end

    test "no person may write one, admin included" do
      document = page()

      for actor <- [nil, user(:viewer), user(:editor), user(:admin)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Firing.upsert_artifact(
                   %{
                     document_type: :page,
                     document_id: document.id,
                     surface: :json,
                     format_version: 2,
                     body: %{},
                     fired_at: DateTime.utc_now()
                   },
                   actor: actor,
                   tenant: org_id()
                 )
      end
    end

    test "the system actor destroys them (the unpublish purge)" do
      row = artifact(page())

      assert :ok = Ash.destroy(row, actor: system(), tenant: org_id())
    end

    test "no person may destroy one, admin included" do
      row = artifact(page())

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(row, actor: user(:admin), tenant: org_id())
    end

    test "the system actor reads a gated document's artifact that a consumer cannot" do
      gated = page(%{audience: hd(CMS.Audiences.gated())})
      row = artifact(gated)

      assert {:ok, %{id: id}} =
               Firing.get_artifact(:page, gated.id, :web, actor: system(), tenant: org_id())

      assert id == row.id

      # The audience axis is still enforced one tier down for everyone else —
      # that is the #565 guarantee the system clause must not have undone.
      assert {:ok, []} =
               Firing.artifacts_for(:page, gated.id, actor: nil, tenant: org_id())
    end
  end

  describe "TypeDefinition / FieldDefinition — the schema the engine reads" do
    test "the system actor reads a type definition; a viewer does not" do
      definition =
        CMS.create_type_definition!(
          %{name: "fpa#{uniq()}", label: "Guide"},
          actor: user(:admin)
        )

      assert {:ok, %{name: name}} =
               CMS.get_type_definition(definition.id, actor: system(), tenant: org_id())

      assert name == definition.name

      assert {:error, _} =
               CMS.get_type_definition(definition.id, actor: user(:viewer), tenant: org_id())
    end

    test "the system actor reads field definitions; a viewer does not" do
      name = "fpa_field_#{uniq()}"

      CMS.create_field_definition!(
        %{content_type: :page, name: name, label: "Field", field_type: :string},
        actor: user(:admin)
      )

      names =
        :page
        |> CMS.field_definitions_for!(actor: system(), tenant: org_id())
        |> Enum.map(& &1.name)

      assert name in names

      assert CMS.field_definitions_for!(:page, actor: user(:viewer), tenant: org_id()) == []
    end

    test "the system actor may read a definition but not write one" do
      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_type_definition(%{name: "fpa#{uniq()}", label: "Nope"}, actor: system())
    end
  end

  describe ":reindex_search_text — a system-only content action" do
    # `Firing.Engine.fire/2` recomputes this denormalized column against the
    # fragment-expanded tree. The grant lives INSIDE the
    # `action_type([:create, :update])` policy written for people
    # (`EditableContentType`), narrowed to this action by
    # `forbid_unless action(...)` — not in a bypass, so nothing else in the
    # stack is short-circuited. Drop either clause and the first assertion
    # fails.
    test "the system actor may reindex, and gets nothing else on the resource" do
      document = page()

      assert {:ok, %{search_text: "recomputed"}} =
               document
               |> Ash.Changeset.for_update(:reindex_search_text, %{search_text: "recomputed"},
                 actor: system(),
                 tenant: org_id()
               )
               |> Ash.update()

      # The bypass names ONE action. Everything else on the resource still
      # refuses the system actor — it holds no tier and no audience.
      assert {:error, %Ash.Error.Forbidden{}} =
               document
               |> Ash.Changeset.for_update(:update, %{title: "Renamed"},
                 actor: system(),
                 tenant: org_id()
               )
               |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{}} =
               document
               |> Ash.Changeset.for_destroy(:destroy, %{}, actor: system(), tenant: org_id())
               |> Ash.destroy()
    end

    test "an anonymous caller may not reindex" do
      document = page()

      assert {:error, %Ash.Error.Forbidden{}} =
               document
               |> Ash.Changeset.for_update(:reindex_search_text, %{search_text: "nope"},
                 actor: nil,
                 tenant: org_id()
               )
               |> Ash.update()
    end
  end

  describe "what the system actor deliberately cannot read" do
    test "no content read grant came with the conversion" do
      draft = page(%{state: :draft, title: "Unpublished"})

      # `Firing.Sweep` and `Firing.Delivery` keep their bypasses precisely so
      # this stays true: a system actor is not a reader of the corpus.
      assert {:ok, []} =
               KilnCMS.CMS.Page
               |> Ash.Query.filter(id == ^draft.id)
               |> Ash.read(actor: system(), tenant: org_id())
    end
  end
end
