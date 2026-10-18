defmodule KilnCMS.CMS.ReferenceTargetRulesTest do
  @moduledoc """
  The two target-side options of a `:reference` field, workstreams R1b and R5
  of `docs/relationships-plan.md`:

    * `max_sources` — how many records may connect to any one target through
      the field, checked in the source's own write where the edge is written;
    * `on_target_delete` — what purging a target does to the connections:
      `:keep`, `:clear` or `:restrict`.

  The concurrent race for the last slot is in
  `KilnCMS.CMS.ReferenceCapRaceTest`, which needs connections of its own.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentLink
  alias KilnCMS.CMS.Errors.TargetStillConnected
  alias KilnCMS.Firing
  alias KilnCMS.SchemaExport

  require Ash.Query

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rtr-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "rtr-#{System.unique_integer([:positive])}"
  defp field_name, do: "authors_#{System.unique_integer([:positive])}"

  defp page!(admin, title, publish? \\ false) do
    page = CMS.create_page!(%{title: title, slug: slug()}, actor: admin)
    if publish?, do: CMS.publish_page!(page, %{}, actor: admin), else: page
  end

  defp field!(admin, name, attrs) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: name,
          label: "Authors",
          field_type: :reference,
          target_type: "page"
        },
        attrs
      ),
      actor: admin
    )
  end

  defp post!(admin, fields, title \\ "Referrer") do
    CMS.create_post!(%{title: title, slug: slug(), custom_fields: fields}, actor: admin)
  end

  defp post(admin, fields, title \\ "Referrer") do
    CMS.create_post(%{title: title, slug: slug(), custom_fields: fields}, actor: admin)
  end

  defp edges_to(target) do
    ContentLink
    |> Ash.Query.filter(target_id == ^target.id and kind == :reference)
    |> Ash.Query.sort(source_id: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp edges_from(source) do
    ContentLink
    |> Ash.Query.filter(source_id == ^source.id and kind == :reference)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp message(%Ash.Error.Invalid{} = error), do: Exception.message(error)

  defp trash_and_purge(:page, page, admin) do
    :ok = CMS.destroy_page!(page, actor: admin)
    trashed = Enum.find(CMS.list_trashed_pages!(actor: admin), &(&1.id == page.id))
    CMS.purge_page(trashed, actor: admin)
  end

  defp reload_post(post, admin) do
    case CMS.get_post(post.id, actor: admin) do
      {:ok, post} -> post
      _gone -> Enum.find(CMS.list_trashed_posts!(actor: admin), &(&1.id == post.id))
    end
  end

  describe "max_sources (R1b)" do
    setup do
      admin = admin()
      name = field_name()
      %{admin: admin, name: name, field: field!(admin, name, %{max_sources: 2})}
    end

    test "a target with as many sources as the cap refuses the next, naming the count only",
         %{admin: admin, name: name} do
      target = page!(admin, "Jane Doe")
      post!(admin, %{name => target.id}, "First book")
      post!(admin, %{name => target.id}, "Second book")

      assert {:error, error} = post(admin, %{name => target.id}, "Third book")
      text = message(error)
      assert text =~ "Authors (#{name}) — “Jane Doe” is full: it already has 2 of 2 connected"
      refute text =~ "First book"
      refute text =~ "Second book"

      # Refused whole: no third edge, and another target is still free.
      assert length(edges_to(target)) == 2
      other = page!(admin, "John Roe")
      assert {:ok, _post} = post(admin, %{name => other.id})
    end

    test "a source already connected may re-save, retitle and drop the target when full",
         %{admin: admin, name: name} do
      target = page!(admin, "Jane Doe")
      post!(admin, %{name => target.id})
      second = post!(admin, %{name => target.id})

      assert {:ok, second} =
               CMS.update_post(second, %{title: "Renamed", custom_fields: second.custom_fields},
                 actor: admin
               )

      assert {:ok, second} =
               CMS.update_post(second, %{custom_fields: %{name => ""}}, actor: admin)

      assert edges_from(second) == []
    end

    test "a draft and a trashed source each hold a slot", %{admin: admin, name: name} do
      target = page!(admin, "Jane Doe")
      draft = post!(admin, %{name => target.id})
      trashed = post!(admin, %{name => target.id})
      :ok = CMS.destroy_post!(trashed, actor: admin)

      assert {:error, error} = post(admin, %{name => target.id})
      assert message(error) =~ "2 of 2"

      # Freeing a slot lets the next one in.
      {:ok, _draft} = CMS.update_post(draft, %{custom_fields: %{name => ""}}, actor: admin)
      assert {:ok, _post} = post(admin, %{name => target.id})
    end

    test "tightening the cap leaves existing connections alone; it applies to the next add",
         %{admin: admin, name: name, field: field} do
      target = page!(admin, "Jane Doe")
      first = post!(admin, %{name => target.id})
      post!(admin, %{name => target.id})

      CMS.update_field_definition!(field, %{max_sources: 1}, actor: admin)

      assert length(edges_to(target)) == 2
      assert {:ok, _first} = CMS.update_post(first, %{title: "Still here"}, actor: admin)
      assert {:error, error} = post(admin, %{name => target.id})
      assert message(error) =~ "2 of 1"
    end

    test "a list field counts per target, and the source's own other targets don't count",
         %{admin: admin} do
      name = field_name()
      field!(admin, name, %{multiple: true, max_sources: 1})
      [a, b, c] = for t <- ~w(A B C), do: page!(admin, t)

      holder = post!(admin, %{name => [a.id, b.id]})
      # Reordering its own targets is not an add.
      assert {:ok, _holder} =
               CMS.update_post(holder, %{custom_fields: %{name => [b.id, a.id]}}, actor: admin)

      assert {:error, error} = post(admin, %{name => [c.id, b.id]})
      assert message(error) =~ "“B” is full: it already has 1 of 1"
      assert {:ok, _post} = post(admin, %{name => [c.id]})
    end

    test "a working copy's add is checked when Publish changes folds it",
         %{admin: admin, name: name} do
      target = page!(admin, "Jane Doe")
      post!(admin, %{name => target.id})
      published = CMS.publish_post!(post!(admin, %{}), %{}, actor: admin)

      {:ok, staged} =
        CMS.save_post_working_copy(
          published,
          %{fields: %{"custom_fields" => %{name => target.id}}},
          actor: admin,
          tenant: published.org_id
        )

      # The slot fills while the change waits.
      post!(admin, %{name => target.id})

      assert {:error, error} = CMS.publish_post_changes(staged, %{}, actor: admin)
      assert message(error) =~ "“Jane Doe” is full: it already has 2 of 2"
      assert edges_from(published) == []
    end

    test "is cleared on any type but a reference, and on a link field", %{admin: admin} do
      field =
        CMS.create_field_definition!(
          %{content_type: :post, name: field_name(), label: "Note", field_type: :string},
          actor: admin
        )

      assert CMS.update_field_definition!(field, %{max_sources: 3, on_target_delete: :clear},
               actor: admin
             )
             |> Map.take([:max_sources, :on_target_delete]) ==
               %{max_sources: nil, on_target_delete: :keep}
    end

    test "must be at least 1", %{admin: admin} do
      assert {:error, _} =
               CMS.create_field_definition(
                 %{
                   content_type: :post,
                   name: field_name(),
                   label: "X",
                   field_type: :reference,
                   target_type: "page",
                   max_sources: 0
                 },
                 actor: admin
               )
    end
  end

  describe "on_target_delete (R5)" do
    setup do
      %{admin: admin()}
    end

    test ":keep (the default) leaves the broken reference", %{admin: admin} do
      name = field_name()
      field = field!(admin, name, %{})
      assert field.on_target_delete == :keep

      target = page!(admin, "Gone")
      referrer = post!(admin, %{name => target.id})

      assert :ok = trash_and_purge(:page, target, admin)
      assert reload_post(referrer, admin).custom_fields[name]["id"] == target.id
      assert [_edge] = edges_from(referrer)
    end

    test ":restrict refuses the purge, not the trash, while anything connects",
         %{admin: admin} do
      name = field_name()
      field!(admin, name, %{on_target_delete: :restrict, label: "Lead author"})
      target = page!(admin, "Kept")
      first = post!(admin, %{name => target.id})
      second = post!(admin, %{name => target.id})
      # A trashed referrer still holds its edge, and still counts.
      :ok = CMS.destroy_post!(second, actor: admin)

      :ok = CMS.destroy_page!(target, actor: admin)
      trashed = Enum.find(CMS.list_trashed_pages!(actor: admin), &(&1.id == target.id))

      assert {:error, %Ash.Error.Invalid{errors: errors}} = CMS.purge_page(trashed, actor: admin)

      assert %TargetStillConnected{count: 2, field_label: "Lead author"} =
               Enum.find(errors, &match?(%TargetStillConnected{}, &1))

      # Nothing was deleted.
      assert Enum.any?(CMS.list_trashed_pages!(actor: admin), &(&1.id == target.id))
      assert length(edges_to(target)) == 2

      {:ok, _} = CMS.update_post(first, %{custom_fields: %{name => ""}}, actor: admin)
      second = reload_post(second, admin)
      CMS.purge_post!(second, actor: admin)

      assert :ok = CMS.purge_page(trashed, actor: admin)
    end

    test ":clear takes the target out of each list, keeping the rest and their link data",
         %{admin: admin} do
      name = field_name()
      parent = field!(admin, name, %{multiple: true, on_target_delete: :clear})

      CMS.create_field_definition!(
        %{link_of_id: parent.id, name: "role", label: "Role", field_type: :string},
        actor: admin
      )

      [a, gone, b] = for t <- ~w(A Gone B), do: page!(admin, t, true)

      referrer =
        post!(admin, %{
          name => [
            %{"id" => a.id, "link" => %{"role" => "lead"}},
            %{"id" => gone.id, "link" => %{"role" => "editor"}},
            %{"id" => b.id}
          ]
        })

      referrer = CMS.publish_post!(referrer, %{}, actor: admin)
      lock_version = referrer.lock_version
      KilnCMS.DataCase.drain_oban()

      assert :ok = trash_and_purge(:page, gone, admin)

      cleared = reload_post(referrer, admin)
      assert Enum.map(cleared.custom_fields[name], & &1["id"]) == [a.id, b.id]
      assert hd(cleared.custom_fields[name])["link"] == %{"role" => "lead"}
      assert cleared.lock_version > lock_version

      # The edges follow the value: positions closed up, link data kept.
      assert Enum.map(edges_from(cleared), &{&1.target_id, &1.position, &1.metadata}) == [
               {a.id, 0, %{"role" => "lead"}},
               {b.id, 1, %{}}
             ]

      # Re-fired: the artifact and its re-fire edges no longer name it.
      assert %{failure: 0} = KilnCMS.DataCase.drain_oban()

      {:ok, artifact} =
        Firing.get_artifact(:post, cleared.id, :json,
          authorize?: false,
          tenant: cleared.org_id
        )

      assert Enum.map(artifact.body["custom_fields"][name], & &1["id"]) == [a.id, b.id]

      {:ok, fired_edges} = Firing.edges_from(:post, cleared.id, authorize?: false)
      refute Enum.any?(fired_edges, &(&1.to_id == gone.id))
    end

    test ":clear removes a single reference, from live and trashed referrers, and from a held copy",
         %{admin: admin} do
      name = field_name()
      note = field_name()
      field!(admin, name, %{on_target_delete: :clear})

      CMS.create_field_definition!(
        %{content_type: :post, name: note, label: "Note", field_type: :string},
        actor: admin
      )

      gone = page!(admin, "Gone")

      live = post!(admin, %{name => gone.id})
      trashed = post!(admin, %{name => gone.id})
      :ok = CMS.destroy_post!(trashed, actor: admin)

      published = CMS.publish_post!(post!(admin, %{name => gone.id}), %{}, actor: admin)

      {:ok, _staged} =
        CMS.save_post_working_copy(
          published,
          %{fields: %{"custom_fields" => %{name => gone.id, note => "draft"}}},
          actor: admin,
          tenant: published.org_id
        )

      assert :ok = trash_and_purge(:page, gone, admin)

      refute Map.has_key?(reload_post(live, admin).custom_fields, name)
      refute Map.has_key?(reload_post(trashed, admin).custom_fields, name)
      assert edges_from(live) == []
      assert edges_from(trashed) == []

      # The held copy no longer brings it back, and publishing it is no conflict.
      staged = reload_post(published, admin)
      held = staged.working_fields["custom_fields"]
      refute Map.has_key?(held, name)
      assert held[note] == "draft"
      assert KilnCMS.CMS.WorkingCopy.reconcile(staged).conflicts == []
      assert {:ok, after_publish} = CMS.publish_post_changes(staged, %{}, actor: admin)
      assert after_publish.custom_fields[note] == "draft"
      refute Map.has_key?(after_publish.custom_fields, name)
    end

    test "a dynamic type's field is honoured too", %{admin: admin} do
      definition =
        CMS.create_type_definition!(
          %{name: "rtr#{System.unique_integer([:positive])}", label: "Recipe"},
          actor: admin
        )

      CMS.create_field_definition!(
        %{
          type_definition_id: definition.id,
          name: "ingredient",
          label: "Ingredient",
          field_type: :reference,
          target_type: "page",
          on_target_delete: :restrict
        },
        actor: admin
      )

      target = page!(admin, "Flour")

      CMS.ContentTypes.create!(
        definition.name,
        %{title: "Bread", slug: slug(), custom_fields: %{"ingredient" => target.id}},
        actor: admin
      )

      assert {:error, %Ash.Error.Invalid{} = error} = trash_and_purge(:page, target, admin)
      assert message(error) =~ "1 record still connects to it through “Ingredient”"
    end
  end

  describe "the schema export" do
    test "reports max_sources and a non-default on_target_delete" do
      admin = admin()
      capped = field_name()
      plain = field_name()
      field!(admin, capped, %{max_sources: 3, on_target_delete: :restrict})
      field!(admin, plain, %{})

      props =
        SchemaExport.json_schema()["$defs"]["content_post"]["properties"]["custom_fields"][
          "properties"
        ]

      assert props[capped]["x-kiln-max-sources"] == 3
      assert props[capped]["x-kiln-on-target-delete"] == "restrict"
      refute Map.has_key?(props[plain], "x-kiln-max-sources")
      refute Map.has_key?(props[plain], "x-kiln-on-target-delete")
    end
  end
end
