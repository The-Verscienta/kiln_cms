defmodule KilnCMS.DeliveryInternalsPolicyTest do
  @moduledoc """
  Read policies for the four resources that used to declare `authorize_if
  always()` (#565): `Firing.PublishedArtifact`, `Firing.ReferenceEdge`,
  `CMS.FormField` and `Search.BlockEmbedding`.

  The one that mattered is `PublishedArtifact` — it holds the *rendered* body of a
  document, so a blanket read grant meant the audience axis enforced on `Content`
  was not re-enforced one layer down. The rest are enumeration surfaces.

  Two things are being pinned at once, and both matter:

    * a caller carrying an **actor** is now filtered, and
    * the **system** paths (firing engine, indexer, form renderer) still work —
      they ran `authorize?: false`, which is the whole reason tightening these
      was safe. `ReferenceEdge` has since moved to `%KilnCMS.SystemActor{}` and
      an explicit policy clause (#1402); the rest still bypass.

  Assertions are membership checks over seeded rows, never full-table counts —
  the sandbox is shared.
  """
  use KilnCMS.DataCase, async: true

  require Ash.Query

  alias KilnCMS.Accounts
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.Firing
  alias KilnCMS.Firing.Engine
  alias KilnCMS.Firing.References
  alias KilnCMS.Search.BlockEmbedding
  alias KilnCMS.SearchIndex
  alias KilnCMS.SystemActor

  @gated hd(Audiences.gated())

  defp uniq, do: System.unique_integer([:positive])

  defp org_id, do: Accounts.default_org_id()

  defp user(role, audiences \\ []) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "dip-#{role}-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role,
      audiences: audiences
    })
  end

  # Seed the document directly in its final state — the publish workflow isn't
  # under test, and seeding keeps the artifact row's audience unambiguous.
  defp page(audience, state \\ :published) do
    Ash.Seed.seed!(KilnCMS.CMS.Page, %{
      title: "Artifact #{audience}",
      slug: "dip-#{uniq()}",
      locale: "en",
      state: state,
      audience: audience
    })
  end

  defp artifact(page, surface \\ :web) do
    Ash.Seed.seed!(Firing.PublishedArtifact, %{
      org_id: org_id(),
      document_type: :page,
      document_id: page.id,
      surface: surface,
      format_version: 1,
      body: %{"html" => "<p>#{page.title}</p>"},
      fired_at: DateTime.utc_now()
    })
  end

  defp edge do
    Ash.Seed.seed!(Firing.ReferenceEdge, %{
      org_id: org_id(),
      from_type: :page,
      from_id: Ash.UUID.generate(),
      to_type: :page,
      to_id: Ash.UUID.generate()
    })
  end

  # A typed block tree whose single block references `target_id` — the shape
  # `References.extract/1` pulls an edge out of.
  defp ref_blocks(target_id) do
    KilnCMS.CMS.TypedBlocks.from_legacy([
      %{
        type: :custom,
        content: "see also",
        data: %{"ref" => %{"type" => "page", "id" => target_id}},
        order: 0
      }
    ])
  end

  defp embedding do
    Ash.Seed.seed!(BlockEmbedding, %{
      org_id: org_id(),
      document_type: :page,
      document_id: Ash.UUID.generate(),
      block_key: "block-#{uniq()}",
      block_type: :rich_text,
      content_hash: "hash-#{uniq()}",
      ancestor_context: "Draft-only prose that should not be enumerable"
    })
  end

  defp form(active?) do
    Ash.Seed.seed!(KilnCMS.CMS.Form, %{
      org_id: org_id(),
      name: "Form #{uniq()}",
      slug: "dip-form-#{uniq()}",
      active: active?
    })
  end

  defp field(form) do
    Ash.Seed.seed!(KilnCMS.CMS.FormField, %{
      org_id: org_id(),
      form_id: form.id,
      name: "field_#{uniq()}",
      label: "Field",
      field_type: :string
    })
  end

  defp readable_artifact_ids(actor) do
    {:ok, artifacts} = Firing.list_artifacts(actor: actor, tenant: org_id())
    MapSet.new(artifacts, & &1.id)
  end

  describe "PublishedArtifact reads re-enforce the audience axis" do
    test "an artifact of :public published content stays world-readable" do
      artifact = artifact(page(:public))

      assert artifact.id in readable_artifact_ids(nil)
    end

    test "an artifact of gated content is hidden from anonymous readers" do
      artifact = artifact(page(@gated))

      refute artifact.id in readable_artifact_ids(nil)
    end

    test "an artifact of gated content is hidden from a reader lacking the audience" do
      artifact = artifact(page(@gated))

      refute artifact.id in readable_artifact_ids(user(:viewer, []))
    end

    test "an artifact of gated content is visible to a reader holding the audience" do
      artifact = artifact(page(@gated))

      assert artifact.id in readable_artifact_ids(user(:viewer, [@gated]))
    end

    test "editors and admins see artifacts of every document" do
      artifact = artifact(page(@gated))

      assert artifact.id in readable_artifact_ids(user(:editor))
      assert artifact.id in readable_artifact_ids(user(:admin))
    end

    # The fall-through in `DocumentReadable.readable_ids/4`: a document type with
    # no backing resource — a dynamic type's descriptor, or a type since removed
    # — cannot be authorized against, so the artifact must be dropped rather than
    # served. Denying is the safe direction for a read, and this branch had no
    # coverage until #599 changed what it returns.
    test "an artifact whose document type has no backing resource is dropped" do
      artifact =
        Ash.Seed.seed!(Firing.PublishedArtifact, %{
          org_id: org_id(),
          document_type: :type_that_no_longer_exists,
          document_id: Ash.UUID.generate(),
          surface: :web,
          format_version: 1,
          body: %{"html" => "<p>orphan</p>"},
          fired_at: DateTime.utc_now()
        })

      refute artifact.id in readable_artifact_ids(nil)
      refute artifact.id in readable_artifact_ids(user(:viewer, []))
    end

    test "an artifact of unpublished content is hidden from consumers" do
      # Shouldn't normally exist (unpublishing purges artifacts), but the policy
      # must not depend on that housekeeping to hold.
      artifact = artifact(page(:public, :draft))

      refute artifact.id in readable_artifact_ids(nil)
      refute artifact.id in readable_artifact_ids(user(:viewer, [@gated]))
      assert artifact.id in readable_artifact_ids(user(:editor))
    end

    test "the argument-taking delivery reads are gated too, not just the list read" do
      gated = page(@gated)
      artifact(gated)

      assert {:error, _} =
               Firing.get_artifact(:page, gated.id, :web, actor: nil, tenant: org_id())

      assert {:ok, []} = Firing.artifacts_for(:page, gated.id, actor: nil, tenant: org_id())

      assert {:ok, %{surface: :web}} =
               Firing.get_artifact(:page, gated.id, :web,
                 actor: user(:viewer, [@gated]),
                 tenant: org_id()
               )
    end

    test "the system delivery path is unaffected" do
      gated = page(@gated)
      artifact(gated)

      # `Engine.read/4` is what `Firing.Delivery` (and therefore every HTTP
      # surface) actually calls, with `authorize?: false` — it must keep serving
      # gated bodies, because the caller has already resolved the record through
      # the audience-gated content read.
      assert {:ok, %{"html" => _}} = Engine.read(org_id(), :page, gated.id, :web)
    end
  end

  describe "ReferenceEdge reads" do
    test "the link graph is not readable by consumers" do
      edge = edge()

      assert {:ok, []} =
               Firing.edges_from(edge.from_type, edge.from_id, actor: nil, tenant: org_id())

      assert {:ok, []} =
               Firing.edges_from(edge.from_type, edge.from_id,
                 actor: user(:viewer, [@gated]),
                 tenant: org_id()
               )
    end

    test "editors and admins may read it" do
      edge = edge()

      for actor <- [user(:editor), user(:admin)] do
        assert {:ok, [%{id: id}]} =
                 Firing.edges_from(edge.from_type, edge.from_id, actor: actor, tenant: org_id())

        assert id == edge.id
      end
    end

    test "the re-fire wave (system) is unaffected" do
      edge = edge()

      assert {:ok, [%{id: _}]} =
               Firing.edges_from(edge.from_type, edge.from_id,
                 authorize?: false,
                 tenant: org_id()
               )
    end

    test "the system actor reads it under the policy, not around it (#1402)" do
      edge = edge()

      assert {:ok, [%{id: id}]} =
               Firing.edges_from(edge.from_type, edge.from_id,
                 actor: SystemActor.new(:firing),
                 tenant: org_id()
               )

      assert id == edge.id
    end
  end

  describe "ReferenceEdge writes (#1402)" do
    # `References.rebuild/4` on the fire path is the only writer there has ever
    # been; it used to reach a `forbid_if always()` policy through
    # `authorize?: false`, and now carries `%SystemActor{}` which the policy
    # admits by name. Drop `authorize_if KilnCMS.Checks.SystemActor` from
    # `ReferenceEdge`'s write policy and the first test below fails — that is
    # what makes the conversion real rather than cosmetic.

    test "the fire path rebuilds a document's edges" do
      referrer = page(:public)
      target = page(:public)

      assert :ok = References.rebuild(org_id(), :page, referrer, ref_blocks(target.id))

      assert {:ok, [%{to_type: :page, to_id: to_id}]} =
               Firing.edges_from(:page, referrer.id, authorize?: false, tenant: org_id())

      assert to_id == target.id

      # The destroy half of the rebuild is the same grant: re-running with no
      # references has to clear the edge, not leave it behind.
      assert :ok = References.rebuild(org_id(), :page, referrer, [])

      assert {:ok, []} =
               Firing.edges_from(:page, referrer.id, authorize?: false, tenant: org_id())
    end

    test "no person may write the graph, admin included" do
      target = page(:public)

      for actor <- [nil, user(:viewer), user(:editor), user(:admin)] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Ash.create(
                   Firing.ReferenceEdge,
                   %{
                     from_type: :page,
                     from_id: Ash.UUID.generate(),
                     to_type: :page,
                     to_id: target.id
                   },
                   action: :upsert,
                   actor: actor,
                   tenant: org_id()
                 )
      end
    end

    test "an admin may not destroy an edge the system wrote" do
      edge = edge()

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.destroy(edge, actor: user(:admin), tenant: org_id())
    end
  end

  describe "BlockEmbedding reads" do
    test "indexed block text is not readable by consumers" do
      row = embedding()

      assert {:ok, []} =
               SearchIndex.block_embeddings_for(row.document_type, row.document_id,
                 actor: nil,
                 tenant: org_id()
               )

      assert {:ok, []} =
               SearchIndex.block_embeddings_for(row.document_type, row.document_id,
                 actor: user(:viewer, [@gated]),
                 tenant: org_id()
               )
    end

    test "editors and admins may read it" do
      row = embedding()

      for actor <- [user(:editor), user(:admin)] do
        assert {:ok, [%{id: id}]} =
                 SearchIndex.block_embeddings_for(row.document_type, row.document_id,
                   actor: actor,
                   tenant: org_id()
                 )

        assert id == row.id
      end
    end

    test "the indexer and BlockSearch (system) are unaffected" do
      row = embedding()

      assert {:ok, [%{id: _}]} =
               SearchIndex.block_embeddings_for(row.document_type, row.document_id,
                 authorize?: false,
                 tenant: org_id()
               )
    end
  end

  describe "FormField reads mirror the parent form's visibility" do
    test "fields of an active form are readable by anonymous visitors" do
      field = field(form(true))

      assert {:ok, [%{id: id}]} =
               CMS.form_fields_for(field.form_id, actor: nil, tenant: org_id())

      assert id == field.id
    end

    test "fields of an inactive form are not" do
      field = field(form(false))

      assert {:ok, []} = CMS.form_fields_for(field.form_id, actor: nil, tenant: org_id())
    end

    test "editors still see the fields of a form they are building" do
      field = field(form(false))

      for actor <- [user(:editor), user(:admin)] do
        assert {:ok, [%{id: id}]} =
                 CMS.form_fields_for(field.form_id, actor: actor, tenant: org_id())

        assert id == field.id
      end
    end

    test "the same rule holds on the unfiltered read, which is what a load uses" do
      # `Forms.get_active/2` renders public forms via `load: [:fields]` — an
      # anonymous *authorized* read that runs the primary `:read`, not `:for_form`.
      # If this grant were editor-only, the form would render with no fields at
      # all, and silently: a relationship load filters rather than raises.
      active = field(form(true))
      inactive = field(form(false))

      readable =
        KilnCMS.CMS.FormField
        |> Ash.Query.filter(id in ^[active.id, inactive.id])
        |> Ash.read!(actor: nil, tenant: org_id())
        |> Enum.map(& &1.id)

      assert readable == [active.id]
    end

    test "rendering an active form loads its fields anonymously" do
      field = field(form(true))
      form = Ash.get!(KilnCMS.CMS.Form, field.form_id, authorize?: false, tenant: org_id())

      assert %{fields: [%{id: id}]} =
               Ash.load!(form, [:fields], actor: nil, tenant: org_id())

      assert id == field.id
    end

    test "public form rendering (system) is unaffected" do
      field = field(form(true))

      assert {:ok, [%{id: _}]} =
               CMS.form_fields_for(field.form_id, authorize?: false, tenant: org_id())
    end
  end
end
