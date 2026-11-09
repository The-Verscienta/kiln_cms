defmodule KilnCMS.CMS.FieldSyncTest do
  @moduledoc """
  Config-sync for custom fields (#2288, `KilnCMS.CMS.FieldSync`): the export
  covers every definition attribute and the link/group nesting, an import
  plans before it writes, applies in one transaction, is idempotent, refuses
  changes that drop stored values without a flag, and is admin only.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldSync

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sync-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  setup do
    {:ok, admin: user(:admin)}
  end

  defp field!(admin, attrs),
    do: CMS.create_field_definition!(Map.put_new(attrs, :content_type, :post), actor: admin)

  # A model touching every kind of owner and every rule attribute.
  defp model!(admin) do
    field!(admin, %{
      name: "rating",
      label: "Rating",
      field_type: :integer,
      position: 1,
      validation: %{"min" => 1, "max" => 5}
    })

    field!(admin, %{
      name: "kind",
      label: "Kind",
      field_type: :select,
      options: ["a", "b"],
      option_labels: %{"a" => "Alpha"},
      position: 2,
      section: "Identity",
      help_text: "Pick one",
      searchable: true,
      widget: "radios"
    })

    field!(admin, %{
      name: "note",
      label: "Note",
      field_type: :text,
      format: :plain,
      widget: "single_line",
      deliver_plain: true,
      plain_breaks: true,
      visible_when: %{"field" => "kind", "op" => "eq", "value" => "a"},
      required_when: %{"field" => "kind", "op" => "eq", "value" => "b"},
      position: 3
    })

    field!(admin, %{
      name: "secret",
      label: "Secret",
      field_type: :string,
      private: true,
      localization: :shared,
      position: 4
    })

    group =
      field!(admin, %{name: "doses", label: "Doses", field_type: :group, multiple: true})

    field!(admin, %{
      content_type: nil,
      group_of_id: group.id,
      name: "amount",
      label: "Amount",
      field_type: :float
    })

    type = CMS.create_type_definition!(%{name: "recipe", label: "Recipe"}, actor: admin)

    field!(admin, %{
      content_type: nil,
      type_definition_id: type.id,
      name: "serves",
      label: "Serves",
      field_type: :integer,
      section: "Kitchen"
    })

    ref =
      field!(admin, %{
        name: "related",
        label: "Related",
        field_type: :reference,
        target_type: "page"
      })

    field!(admin, %{
      content_type: nil,
      link_of_id: ref.id,
      name: "qty",
      label: "Qty",
      field_type: :integer
    })

    # Section layouts (#2280): one per kind of owner.
    CMS.create_field_section!(
      %{content_type: :post, name: "Identity", display: :tab, initially: :expanded},
      actor: admin
    )

    CMS.create_field_section!(
      %{type_definition_id: type.id, name: "Kitchen", display: :fieldset},
      actor: admin
    )
  end

  defp wipe!(admin) do
    top =
      for f <- CMS.list_field_definitions!(actor: admin),
          is_nil(KilnCMS.CMS.FieldDefinition.parent_id(f)),
          do: f

    # Fields whose rules read a sibling go first.
    for f <- Enum.sort_by(top, &is_nil(&1.visible_when)),
        do: CMS.destroy_field_definition!(f, actor: admin)

    for s <- CMS.list_field_sections!(actor: admin),
        do: CMS.destroy_field_section!(s, actor: admin)
  end

  defp sections(admin), do: CMS.list_field_sections!(actor: admin)

  defp owner(doc, kind, type),
    do: Enum.find(doc["owners"], &(&1["kind"] == kind and &1["type"] == type))

  defp field_count(doc), do: doc["owners"] |> Enum.map(&length(&1["fields"])) |> Enum.sum()

  defp export!(admin) do
    {:ok, doc} = FieldSync.export(actor: admin)
    doc
  end

  defp apply!(doc, admin, opts \\ []),
    do: FieldSync.import_doc(doc, [actor: admin, apply?: true] ++ opts)

  describe "export" do
    test "carries every accepted attribute, the nesting and the dynamic type", %{admin: admin} do
      model!(admin)
      doc = export!(admin)

      assert %{"format" => "kiln-field-definitions", "version" => 1} = doc

      post = Enum.find(doc["owners"], &(&1["kind"] == "compiled" and &1["type"] == "post"))
      note = Enum.find(post["fields"], &(&1["name"] == "note"))

      assert Enum.sort(Map.keys(note)) == FieldSync.field_keys()
      assert note["visible_when"] == %{"field" => "kind", "op" => "eq", "value" => "a"}
      assert note["deliver_plain"] and note["plain_breaks"]

      doses = Enum.find(post["fields"], &(&1["name"] == "doses"))
      assert [%{"name" => "amount"}] = doses["group_fields"]

      related = Enum.find(post["fields"], &(&1["name"] == "related"))
      assert [%{"name" => "qty"}] = related["link_fields"]

      recipe = Enum.find(doc["owners"], &(&1["kind"] == "dynamic"))
      assert recipe["type"] == "recipe"
      assert recipe["definition"]["label"] == "Recipe"
      assert [%{"name" => "serves"}] = recipe["fields"]

      assert owner(doc, "compiled", "post")["sections"] == [
               %{"name" => "Identity", "display" => "tab", "initially" => "expanded"}
             ]

      assert [%{"name" => "Kitchen", "display" => "fieldset", "initially" => "auto"}] =
               recipe["sections"]

      assert {:ok, _json} = Jason.encode(doc)
    end

    test "leaves out a layout no field of its owner carries", %{admin: admin} do
      model!(admin)
      # Left behind by a renamed section, on a type with fields and on one
      # without any.
      CMS.create_field_section!(%{content_type: :post, name: "Gone", display: :tab}, actor: admin)
      CMS.create_field_section!(%{content_type: :page, name: "Lonely"}, actor: admin)

      doc = export!(admin)

      assert [%{"name" => "Identity"}] = owner(doc, "compiled", "post")["sections"]
      assert owner(doc, "compiled", "page") == nil
    end

    test "every stored section attribute is exported or deliberately not" do
      not_synced = ~w(id org_id inserted_at updated_at content_type type_definition_id)

      stored =
        KilnCMS.CMS.FieldSection
        |> Ash.Resource.Info.attributes()
        |> Enum.map(&Atom.to_string(&1.name))
        |> Kernel.--(not_synced)
        |> Enum.sort()

      assert stored == FieldSync.section_keys()
    end

    test "every stored definition attribute is exported or deliberately not", %{admin: _admin} do
      # A new FieldDefinition attribute lands in the document through the create
      # action's accept list. One that is not accepted would be silently left
      # out of every sync, so it must be named here as a decision.
      not_synced =
        ~w(id org_id inserted_at updated_at content_type type_definition_id link_of_id group_of_id)a

      stored =
        KilnCMS.CMS.FieldDefinition
        |> Ash.Resource.Info.attributes()
        |> Enum.map(&Atom.to_string(&1.name))
        |> Kernel.--(Enum.map(not_synced, &Atom.to_string/1))
        |> Enum.sort()

      assert stored == FieldSync.field_keys()
    end

    test "the export is admin only", %{admin: _admin} do
      assert {:error, :forbidden} = FieldSync.export(actor: user(:editor))
      assert {:error, :forbidden} = FieldSync.export(actor: nil)
    end
  end

  describe "import" do
    test "round-trips a model into an empty site, then is idempotent", %{admin: admin} do
      model!(admin)
      doc = export!(admin)
      wipe!(admin)
      assert field_count(export!(admin)) == 0

      assert sections(admin) == []

      assert {:ok, %{applied?: true} = report} = apply!(doc, admin)
      assert report.counts[:create] > 0
      assert export!(admin) == doc
      assert length(sections(admin)) == 2

      assert {:ok, again} = apply!(doc, admin)
      assert Map.keys(again.counts) == [:unchanged]
      assert export!(admin) == doc
    end

    test "a dry run writes nothing but plans the diff", %{admin: admin} do
      model!(admin)
      doc = export!(admin)
      wipe!(admin)

      assert {:ok, %{dry_run?: true, applied?: false} = report} =
               FieldSync.import_doc(doc, actor: admin)

      assert report.counts[:create] > 0
      assert FieldSync.describe(report) =~ "+ post.rating"
      assert FieldSync.describe(report) =~ "+ post/section/Identity (tab)"
      assert field_count(export!(admin)) == 0
      assert sections(admin) == []
    end

    test "a dry run reports a write the apply would refuse, and writes nothing", %{admin: admin} do
      model!(admin)
      doc = export!(admin)
      wipe!(admin)

      bad =
        update_in(doc, ["owners", Access.all(), "fields", Access.all()], fn f ->
          if f["name"] == "note",
            do: Map.put(f, "visible_when", %{"field" => "ghost", "op" => "eq", "value" => "x"}),
            else: f
        end)

      assert {:error, %{errors: [%{path: "post.note"} | _]}} =
               FieldSync.import_doc(bad, actor: admin)

      assert field_count(export!(admin)) == 0
    end

    test "an update shows only the attributes that differ", %{admin: admin} do
      model!(admin)
      doc = export!(admin)

      changed =
        update_in(doc, ["owners", Access.all(), "fields", Access.all()], fn f ->
          if f["name"] == "rating", do: Map.put(f, "label", "Score"), else: f
        end)

      assert {:ok, report} = FieldSync.import_doc(changed, actor: admin)

      assert [%{path: "post.rating", changes: %{"label" => {"Rating", "Score"}} = changes}] =
               Enum.filter(report.ops, &(&1.op == :update))

      assert map_size(changes) == 1
    end

    test "a key the file leaves out takes the attribute default", %{admin: admin} do
      doc = %{
        "format" => "kiln-field-definitions",
        "version" => 1,
        "owners" => [
          %{
            "kind" => "compiled",
            "type" => "post",
            "fields" => [%{"name" => "tiny", "label" => "Tiny", "field_type" => "string"}]
          }
        ]
      }

      assert {:ok, _} = apply!(doc, admin)
      [tiny] = CMS.field_definitions_for!(:post, actor: admin)
      assert tiny.required == false and tiny.format == :rich
      assert {:ok, again} = apply!(doc, admin)
      assert Map.keys(again.counts) == [:unchanged]
    end

    test "refuses an unknown key, a wrong version and a non-document", %{admin: admin} do
      assert {:error, %{errors: [%{messages: [m]}]}} =
               FieldSync.import_doc(%{"nope" => 1}, actor: admin)

      assert m =~ "not a kiln-field-definitions document"

      assert {:error, %{errors: [%{messages: [m]}]}} =
               FieldSync.import_doc(
                 %{"format" => "kiln-field-definitions", "version" => 99, "owners" => []},
                 actor: admin
               )

      assert m =~ "unsupported document version"

      doc = %{
        "format" => "kiln-field-definitions",
        "version" => 1,
        "owners" => [
          %{
            "kind" => "compiled",
            "type" => "post",
            "fields" => [%{"name" => "x", "label" => "X", "colour" => "red"}]
          }
        ]
      }

      assert {:error, %{errors: [%{messages: [m]}]}} = FieldSync.import_doc(doc, actor: admin)
      assert m =~ "unknown key(s) colour"
    end

    test "is admin only", %{admin: admin} do
      model!(admin)
      doc = export!(admin)
      assert {:error, :forbidden} = FieldSync.import_doc(doc, actor: user(:editor), apply?: true)
      assert {:error, :forbidden} = FieldSync.import_doc(doc, actor: nil)
    end
  end

  describe "editor widget (#2284)" do
    defp with_field(doc, name, fun),
      do:
        update_in(doc, ["owners", Access.all(), "fields", Access.all()], fn f ->
          if f["name"] == name, do: fun.(f), else: f
        end)

    test "the export carries each field's widget, nil for the default", %{admin: admin} do
      model!(admin)
      post = Enum.find(export!(admin)["owners"], &(&1["type"] == "post"))
      by_name = Map.new(post["fields"], &{&1["name"], &1})

      assert by_name["kind"]["widget"] == "radios"
      assert by_name["note"]["widget"] == "single_line"
      assert Map.has_key?(by_name["rating"], "widget")
      assert by_name["rating"]["widget"] == nil
    end

    test "a changed widget imports, and a second import changes nothing", %{admin: admin} do
      model!(admin)
      doc = export!(admin) |> with_field("kind", &Map.put(&1, "widget", "buttons"))

      assert {:ok, report} = apply!(doc, admin)

      assert [%{path: "post.kind", changes: %{"widget" => {"radios", "buttons"}}}] =
               Enum.filter(report.ops, &(&1.op == :update))

      kind = Enum.find(CMS.field_definitions_for!(:post, actor: admin), &(&1.name == "kind"))
      assert kind.widget == "buttons"

      assert {:ok, again} = apply!(doc, admin)
      assert Map.keys(again.counts) == [:unchanged]
    end

    test "a widget the field doesn't offer is reported by a dry run", %{admin: admin} do
      model!(admin)
      doc = export!(admin) |> with_field("kind", &Map.put(&1, "widget", "single_line"))

      assert {:error, %{errors: [%{path: "post.kind", messages: messages}]}} =
               FieldSync.import_doc(doc, actor: admin)

      assert Enum.any?(messages, &(&1 =~ "single_line"))
    end

    test "a file whose other settings no longer suit its widget is refused, not cleared", %{
      admin: admin
    } do
      # The file keeps `radios` (as stored) but makes the select multiple:
      # only `multiple` differs, yet the widget must travel with the update,
      # or the write would drop it and the site would disagree with the file.
      model!(admin)
      doc = export!(admin) |> with_field("kind", &Map.put(&1, "multiple", true))

      assert {:error, %{errors: [%{path: "post.kind", messages: messages}]}} =
               apply!(doc, admin)

      assert Enum.any?(messages, &(&1 =~ "radios"))

      kind = Enum.find(CMS.field_definitions_for!(:post, actor: admin), &(&1.name == "kind"))
      assert kind.widget == "radios" and kind.multiple == false
    end
  end

  describe "pruning and data loss" do
    defp post_with!(admin, key, value),
      do:
        CMS.create_post!(
          %{
            title: "T",
            slug: "t-#{System.unique_integer([:positive])}",
            custom_fields: %{key => value}
          },
          actor: admin
        )

    defp without(doc, name),
      do:
        update_in(doc, ["owners", Access.all(), "fields"], fn fs ->
          Enum.reject(fs, &(&1["name"] == name))
        end)

    test "a field missing from the file is kept unless pruned", %{admin: admin} do
      model!(admin)
      doc = export!(admin) |> without("rating")

      assert {:ok, report} = apply!(doc, admin)
      assert "post.rating" in report.untouched
      assert Enum.any?(CMS.field_definitions_for!(:post, actor: admin), &(&1.name == "rating"))

      assert {:ok, _} = apply!(doc, admin, prune?: true)
      refute Enum.any?(CMS.field_definitions_for!(:post, actor: admin), &(&1.name == "rating"))
    end

    test "pruning a field that holds data is blocked without the flag", %{admin: admin} do
      model!(admin)
      post = post_with!(admin, "rating", 3)
      doc = export!(admin) |> without("rating")

      assert {:error, %{blocked: [%{path: "post.rating"}]}} = apply!(doc, admin, prune?: true)
      assert Enum.any?(CMS.field_definitions_for!(:post, actor: admin), &(&1.name == "rating"))
      assert CMS.get_post!(post.id, actor: admin).custom_fields["rating"] == 3

      assert {:ok, _} = apply!(doc, admin, prune?: true, allow_data_loss?: true)
      refute Enum.any?(CMS.field_definitions_for!(:post, actor: admin), &(&1.name == "rating"))
    end

    test "a type change over stored values is blocked; an empty field retypes freely", %{
      admin: admin
    } do
      model!(admin)
      post_with!(admin, "rating", 3)
      doc = export!(admin)

      retyped =
        update_in(doc, ["owners", Access.all(), "fields", Access.all()], fn f ->
          cond do
            f["name"] == "rating" ->
              %{f | "field_type" => "string", "validation" => %{}}

            f["name"] == "secret" ->
              %{f | "field_type" => "text", "private" => false, "localization" => "localized"}

            true ->
              f
          end
        end)

      assert {:error, %{blocked: [%{path: "post.rating"}]}} =
               FieldSync.import_doc(retyped, actor: admin)
    end
  end

  describe "section layouts" do
    defp map_sections(doc, fun),
      do: update_in(doc, ["owners", Access.all()], &Map.update!(&1, "sections", fun))

    test "a changed layout is an update of only what differs", %{admin: admin} do
      model!(admin)

      doc =
        map_sections(export!(admin), fn ss ->
          Enum.map(
            ss,
            &if(&1["name"] == "Identity", do: %{&1 | "display" => "fieldset"}, else: &1)
          )
        end)

      assert {:ok, report} = FieldSync.import_doc(doc, actor: admin)

      assert [%{path: "post/section/Identity", changes: %{"display" => {"tab", "fieldset"}}}] =
               Enum.filter(report.ops, &(&1.op == :update))

      assert [%{display: :tab}] = CMS.field_sections_for!(:post, actor: admin)

      assert {:ok, _} = apply!(doc, admin)

      assert [%{display: :fieldset, initially: :expanded}] =
               CMS.field_sections_for!(:post, actor: admin)
    end

    test "a layout missing from the file is kept unless pruned", %{admin: admin} do
      model!(admin)
      doc = map_sections(export!(admin), fn _ -> [] end)

      assert {:ok, report} = FieldSync.import_doc(doc, actor: admin, prune?: true)
      assert report.dry_run?
      assert "post/section/Identity" in for(%{op: :delete, path: p} <- report.ops, do: p)
      assert report.blocked == []
      assert length(sections(admin)) == 2

      assert {:ok, report} = apply!(doc, admin)
      assert "post/section/Identity" in report.untouched
      assert length(sections(admin)) == 2

      assert {:ok, _} = apply!(doc, admin, prune?: true)
      assert sections(admin) == []
      # Pruning a layout touched no field.
      assert field_count(export!(admin)) == field_count(doc)
    end

    test "a file without a sections key declares none", %{admin: admin} do
      model!(admin)
      doc = update_in(export!(admin), ["owners", Access.all()], &Map.delete(&1, "sections"))

      assert {:ok, report} = apply!(doc, admin)
      assert Map.keys(report.counts) == [:unchanged]
      assert length(sections(admin)) == 2
    end

    test "a file without a sections key leaves the layouts alone even when pruning",
         %{admin: admin} do
      model!(admin)
      doc = update_in(export!(admin), ["owners", Access.all()], &Map.delete(&1, "sections"))

      assert {:ok, report} = apply!(doc, admin, prune?: true)
      refute Enum.any?(report.ops, &(&1.kind == :section))
      assert length(sections(admin)) == 2
    end

    test "a pruned field that was the last of its section takes the layout with it",
         %{admin: admin} do
      model!(admin)
      field!(admin, %{name: "latin", label: "Latin", field_type: :string, section: "Names"})
      field!(admin, %{name: "pinyin", label: "Pinyin", field_type: :string, section: "Names"})

      CMS.create_field_section!(%{content_type: :post, name: "Names", display: :tab},
        actor: admin
      )

      drop = fn doc, names ->
        update_in(doc, ["owners", Access.all()], fn
          %{"type" => "post"} = o ->
            Map.update!(o, "fields", fn fs -> Enum.reject(fs, &(&1["name"] in names)) end)

          o ->
            o
        end)
      end

      doc = export!(admin)

      # One of two fields goes: the other still carries the section.
      assert {:ok, _} = apply!(drop.(doc, ["latin"]), admin, prune?: true)
      assert [_] = Enum.filter(sections(admin), &(&1.name == "Names"))

      # The last one goes, and so does the layout; the others stay.
      assert {:ok, _} = apply!(drop.(doc, ["latin", "pinyin"]), admin, prune?: true)

      assert ["Identity", "Kitchen"] == admin |> sections() |> Enum.map(& &1.name) |> Enum.sort()
    end

    test "a section names a known display, and a key the file leaves out defaults",
         %{admin: admin} do
      field!(admin, %{name: "rating", label: "Rating", field_type: :integer, section: "Main"})

      doc = fn sections ->
        %{
          "format" => "kiln-field-definitions",
          "version" => 1,
          "owners" => [
            %{
              "kind" => "compiled",
              "type" => "post",
              "fields" => [
                %{
                  "name" => "rating",
                  "label" => "Rating",
                  "field_type" => "integer",
                  "section" => "Main"
                }
              ],
              "sections" => sections
            }
          ]
        }
      end

      assert {:error, %{errors: [%{path: "post/section/Main"}]}} =
               FieldSync.import_doc(doc.([%{"name" => "Main", "display" => "carousel"}]),
                 actor: admin
               )

      assert sections(admin) == []

      assert {:error, %{errors: [%{messages: [m]}]}} =
               FieldSync.import_doc(doc.([%{"name" => "Main", "colour" => "red"}]), actor: admin)

      assert m =~ "unknown key(s) colour"

      assert {:error, %{errors: [%{messages: [m]}]}} =
               FieldSync.import_doc(doc.([%{"name" => "Main"}, %{"name" => "Main"}]),
                 actor: admin
               )

      assert m =~ "appears twice"

      assert {:error, %{errors: [%{messages: [m]}]}} =
               FieldSync.import_doc(doc.("Main"), actor: admin)

      assert m =~ "must be a list"

      assert {:ok, _} = apply!(doc.([%{"name" => "Main"}]), admin)

      assert [%{display: :accordion, initially: :auto}] =
               CMS.field_sections_for!(:post, actor: admin)
    end

    test "a new dynamic type's layout is tied to the type the import creates", %{admin: admin} do
      model!(admin)
      doc = export!(admin)
      wipe!(admin)

      # The same type under a new name, so the import creates it.
      doc =
        update_in(doc, ["owners", Access.all()], fn
          %{"kind" => "dynamic"} = o ->
            o
            |> Map.put("type", "recipe_two")
            |> update_in(
              ["definition"],
              &%{&1 | "name" => "recipe_two", "path_segment" => "recipe-two"}
            )

          o ->
            o
        end)

      assert {:ok, _} = apply!(doc, admin)
      type = CMS.get_type_definition_by_name!("recipe_two", actor: admin)

      assert [%{name: "Kitchen", display: :fieldset}] =
               CMS.field_sections_for_definition!(type.id, actor: admin)
    end
  end

  describe "command line glue" do
    @tag :tmp_dir
    test "export_file writes the document and import_file reads it back", %{
      admin: admin,
      tmp_dir: dir
    } do
      model!(admin)
      path = Path.join(dir, "fields.json")
      quiet = fn _ -> :ok end

      assert {:ok, _} = FieldSync.export_file(path, [actor: admin.email], quiet)
      assert {:ok, report} = FieldSync.import_file(path, [actor: admin.email], quiet)
      assert report.dry_run?
      assert Map.keys(report.counts) == [:unchanged]

      assert {:error, message} = FieldSync.import_file(path, [colour: 1], quiet)
      assert message =~ "Unknown option"

      assert {:error, message} = FieldSync.import_file(Path.join(dir, "nope.json"), [], quiet)
      assert message =~ "Could not read"
    end
  end
end
