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

  import KilnCMS.SectionLayoutFixtures, only: [orphan_layout!: 1]

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

  defp put_in_field(doc, name, key, value) do
    update_in(doc, ["owners", Access.all(), "fields", Access.filter(&(&1["name"] == name))], fn
      field -> Map.put(field, key, value)
    end)
  end

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
      name: "fs_secret",
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

      # `item_setting` (#2282) is left out of the file while it is false.
      assert Enum.sort(Map.keys(note)) ==
               FieldSync.field_keys() -- ["edit_inline", "item_setting"]

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
      orphan_layout!(%{content_type: :post, name: "Gone", display: :tab})
      orphan_layout!(%{content_type: :page, name: "Lonely", display: :fieldset})

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
      # `flex_of_id` is the nesting of `item_types` (#2282), like the other
      # owner ids; `item_setting` is a file key (left out when false).
      not_synced =
        ~w(id org_id inserted_at updated_at content_type type_definition_id link_of_id group_of_id flex_of_id selection)a

      stored =
        KilnCMS.CMS.FieldDefinition
        |> Ash.Resource.Info.attributes()
        |> Enum.map(&Atom.to_string(&1.name))
        |> Kernel.--(Enum.map(not_synced, &Atom.to_string/1))
        |> Enum.sort()

      assert stored == FieldSync.field_keys()
    end

    test "a reference's selection is per site: not exported, never touched by an import",
         %{admin: admin} do
      field =
        field!(admin, %{
          name: "pick",
          label: "Pick",
          field_type: :reference,
          target_type: "page",
          selection: %{"states" => ["published"]}
        })

      assert {:ok, doc} = FieldSync.export(actor: admin)
      doc = FieldSync.jsonify(doc)

      exported =
        for owner <- doc["owners"], f <- owner["fields"], f["name"] == "pick", do: f

      assert [pick] = exported
      refute Map.has_key?(pick, "selection")

      # Importing over it neither clears nor changes the site's selection,
      # even when the file changes the field.
      changed = put_in_field(doc, "pick", "label", "Pick one")
      assert {:ok, _report} = FieldSync.import_doc(changed, actor: admin, apply?: true)

      reloaded = CMS.get_field_definition!(field.id, actor: admin)
      assert reloaded.label == "Pick one"
      assert reloaded.selection == %{"states" => ["published"]}

      # A file that tries to carry one is refused like any unknown key.
      with_selection = put_in_field(doc, "pick", "selection", %{"owner" => "self"})

      assert {:error, %{errors: [%{messages: [m]}]}} =
               FieldSync.import_doc(with_selection, actor: admin)

      assert m =~ "unknown key(s) selection"
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

    test "a definition without title_template leaves a stored template unchanged (#2287)", %{
      admin: admin
    } do
      type =
        CMS.create_type_definition!(
          %{name: "tt#{System.unique_integer([:positive])}", label: "TT"},
          actor: admin
        )

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "city", label: "City", field_type: :string},
        actor: admin
      )

      CMS.update_type_definition!(type, %{title_template: "{{ field.city }}"}, actor: admin)

      doc = %{
        "format" => "kiln-field-definitions",
        "version" => 1,
        "owners" => [
          %{
            "kind" => "dynamic",
            "type" => type.name,
            "definition" => %{
              "name" => type.name,
              "label" => "Renamed",
              "path_segment" => type.path_segment
            },
            "fields" => []
          }
        ]
      }

      assert {:ok, _} = apply!(doc, admin)
      reloaded = CMS.get_type_definition!(type.id, actor: admin)
      assert reloaded.label == "Renamed"
      assert reloaded.title_template == "{{ field.city }}"
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

  describe "number options (#2432)" do
    defp options_field!(admin) do
      field!(admin, %{
        name: "dose",
        label: "Dose",
        field_type: :float,
        step: 0.5,
        prefix: "~",
        suffix: "mg",
        validation: %{"min" => 0, "max" => 10},
        widget: "slider"
      })
    end

    defp dose(admin),
      do: Enum.find(CMS.field_definitions_for!(:post, actor: admin), &(&1.name == "dose"))

    test "the export carries step, prefix and suffix, null when unset", %{admin: admin} do
      options_field!(admin)
      field!(admin, %{name: "plain", label: "Plain", field_type: :integer})

      post = Enum.find(export!(admin)["owners"], &(&1["type"] == "post"))
      by_name = Map.new(post["fields"], &{&1["name"], &1})

      assert %{"step" => 0.5, "prefix" => "~", "suffix" => "mg", "widget" => "slider"} =
               by_name["dose"]

      assert %{"step" => nil, "prefix" => nil, "suffix" => nil} = by_name["plain"]
    end

    test "round-trips into an empty site, then is idempotent", %{admin: admin} do
      options_field!(admin)
      doc = export!(admin)
      CMS.destroy_field_definition!(dose(admin), actor: admin)

      assert {:ok, _report} = apply!(doc, admin)
      restored = dose(admin)
      assert {restored.step, restored.prefix, restored.suffix} == {0.5, "~", "mg"}
      assert restored.widget == "slider"

      assert {:ok, again} = apply!(doc, admin)
      assert Map.keys(again.counts) == [:unchanged]
    end

    test "a file written before the options existed imports unchanged where none are set",
         %{admin: admin} do
      model!(admin)

      old =
        update_in(
          export!(admin),
          ["owners", Access.all(), "fields", Access.all()],
          &Map.drop(&1, ~w(step prefix suffix))
        )

      assert {:ok, again} = apply!(old, admin)
      assert Map.keys(again.counts) == [:unchanged]
    end

    test "a file without the keys takes their default, so it clears set options",
         %{admin: admin} do
      options_field!(admin)

      old =
        update_in(
          export!(admin),
          ["owners", Access.all(), "fields", Access.all()],
          &Map.drop(&1, ~w(step prefix suffix))
        )

      # Absent keys take the attribute default (nil), as for any key a file
      # leaves out, so this reads as clearing the options.
      assert {:ok, report} = apply!(old, admin)

      assert [%{changes: changes}] = Enum.filter(report.ops, &(&1.op == :update))
      assert Map.keys(changes) |> Enum.sort() == ~w(prefix step suffix)
    end

    test "a changed step imports as an update of only that attribute", %{admin: admin} do
      options_field!(admin)
      doc = export!(admin) |> with_field("dose", &Map.put(&1, "step", 1.0))

      assert {:ok, report} = apply!(doc, admin)

      assert [%{path: "post.dose", changes: %{"step" => {0.5, 1.0}} = changes}] =
               Enum.filter(report.ops, &(&1.op == :update))

      assert map_size(changes) == 1
      assert dose(admin).step == 1.0
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

            f["name"] == "fs_secret" ->
              %{f | "field_type" => "text", "private" => false, "localization" => "localized"}

            true ->
              f
          end
        end)

      assert {:error, %{blocked: [%{path: "post.rating"}]}} =
               FieldSync.import_doc(retyped, actor: admin)
    end
  end

  describe "applying exactly the plan that was shown (#2438)" do
    test "the digest is the same for a dry run and the apply of one plan", %{admin: admin} do
      model!(admin)
      doc = export!(admin) |> put_in_field("note", "label", "Renamed")

      assert {:ok, dry} = FieldSync.import_doc(doc, actor: admin)

      assert {:ok, %{applied?: true} = applied} =
               FieldSync.import_doc(doc,
                 actor: admin,
                 apply?: true,
                 expect_digest: FieldSync.digest(dry)
               )

      assert applied.counts == dry.counts
    end

    test "a plan that moved since the preview is refused and writes nothing", %{admin: admin} do
      model!(admin)
      doc = export!(admin) |> put_in_field("note", "label", "Renamed")
      assert {:ok, dry} = FieldSync.import_doc(doc, actor: admin)

      # Someone else edits the same field after the preview.
      note = Enum.find(CMS.field_definitions_for!(:post, actor: admin), &(&1.name == "note"))
      CMS.update_field_definition!(note, %{label: "Edited elsewhere"}, actor: admin)

      assert {:error, :stale} =
               FieldSync.import_doc(doc,
                 actor: admin,
                 apply?: true,
                 expect_digest: FieldSync.digest(dry)
               )

      assert Enum.find(CMS.field_definitions_for!(:post, actor: admin), &(&1.name == "note")).label ==
               "Edited elsewhere"
    end

    test "the digest tells the prune and data-loss flags apart", %{admin: admin} do
      model!(admin)
      doc = export!(admin) |> without("rating")

      {:ok, kept} = FieldSync.import_doc(doc, actor: admin)
      {:ok, pruned} = FieldSync.import_doc(doc, actor: admin, prune?: true)
      refute FieldSync.digest(kept) == FieldSync.digest(pruned)
    end
  end

  describe "section layouts" do
    defp map_sections(doc, fun),
      do: update_in(doc, ["owners", Access.all()], &Map.update!(&1, "sections", fun))

    defp post_doc(fields, sections) do
      %{
        "format" => "kiln-field-definitions",
        "version" => 1,
        "owners" => [
          %{"kind" => "compiled", "type" => "post", "fields" => fields, "sections" => sections}
        ]
      }
    end

    defp string_field(name, section),
      do: %{"name" => name, "label" => name, "field_type" => "string", "section" => section}

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

      # The last one goes while the file still lays its section out: that
      # entry lays nothing out, so the import is refused (#2881).
      assert {:error, %{errors: [%{path: "post/section/Names"}]}} =
               apply!(drop.(doc, ["latin", "pinyin"]), admin, prune?: true)

      # Without the entry (here, a file with no "sections" key at all, which
      # leaves the layouts to the fields), the layout goes with its last
      # field; the others stay.
      no_layouts =
        update_in(drop.(doc, ["latin", "pinyin"]), ["owners", Access.all()], fn
          %{"type" => "post"} = o -> Map.delete(o, "sections")
          o -> o
        end)

      assert {:ok, _} = apply!(no_layouts, admin, prune?: true)

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

      assert {:ok, _} = apply!(doc.([%{"name" => "Main", "display" => "tab"}]), admin)
      assert [%{display: :tab, initially: :auto}] = CMS.field_sections_for!(:post, actor: admin)

      # An entry with every key left out is at the defaults: no layout (#2652).
      assert {:ok, _} = apply!(doc.([%{"name" => "Main"}]), admin)
      assert sections(admin) == []
    end

    test "an import whose sections are all at the defaults stores no layout", %{admin: admin} do
      model!(admin)
      doc = export!(admin)
      wipe!(admin)

      doc =
        map_sections(doc, fn ss ->
          Enum.map(ss, &%{&1 | "display" => "accordion", "initially" => "auto"})
        end)

      assert {:ok, report} = FieldSync.import_doc(doc, actor: admin)
      refute Enum.any?(report.ops, &(&1.kind == :section))

      assert {:ok, _} = apply!(doc, admin)
      assert sections(admin) == []
    end

    test "a stored layout at the defaults is not exported, and only a prune removes it",
         %{admin: admin} do
      model!(admin)
      field!(admin, %{name: "plain", label: "Plain", field_type: :string, section: "Plain"})
      CMS.create_field_section!(%{content_type: :post, name: "Plain"}, actor: admin)

      doc = export!(admin)
      assert [%{"name" => "Identity"}] = owner(doc, "compiled", "post")["sections"]

      assert {:ok, report} = apply!(doc, admin)
      assert "post/section/Plain" in report.untouched
      assert "Plain" in Enum.map(sections(admin), & &1.name)

      assert {:ok, _} = apply!(doc, admin, prune?: true)
      refute "Plain" in Enum.map(sections(admin), & &1.name)
      assert "Identity" in Enum.map(sections(admin), & &1.name)
    end

    test "an entry at the defaults removes the section's row, without a prune",
         %{admin: admin} do
      model!(admin)
      field!(admin, %{name: "plain", label: "Plain", field_type: :string, section: "Plain"})
      CMS.create_field_section!(%{content_type: :post, name: "Plain"}, actor: admin)

      doc =
        map_sections(export!(admin), fn ss ->
          Enum.map(ss, fn
            %{"name" => "Identity"} = s -> %{s | "display" => "accordion", "initially" => "auto"}
            s -> s
          end) ++ [%{"name" => "Plain", "display" => "accordion", "initially" => "auto"}]
        end)

      assert {:ok, report} = FieldSync.import_doc(doc, actor: admin)

      assert ["post/section/Identity", "post/section/Plain"] ==
               report.ops
               |> Enum.filter(&(&1.kind == :section and &1.op == :delete))
               |> Enum.map(& &1.path)
               |> Enum.sort()

      assert report.untouched == []

      assert {:ok, _} = apply!(doc, admin)
      assert ["Kitchen"] == Enum.map(sections(admin), & &1.name)
      # Imported again, the defaults plan nothing; the stored layout is unchanged.
      assert {:ok, again} = FieldSync.import_doc(doc, actor: admin)

      assert [%{path: "recipe/section/Kitchen", op: :unchanged}] =
               Enum.filter(again.ops, &(&1.kind == :section))
    end

    test "a field the import moves out of its section takes the layout along, without a prune",
         %{admin: admin} do
      field!(admin, %{name: "latin", label: "Latin", field_type: :string, section: "Fsync A"})

      CMS.create_field_section!(%{content_type: :post, name: "Fsync A", display: :tab},
        actor: admin
      )

      # The section renamed in the file, on its field and on its layout.
      doc =
        post_doc([string_field("latin", "Fsync B")], [%{"name" => "Fsync B", "display" => "tab"}])

      assert {:ok, report} = FieldSync.import_doc(doc, actor: admin)
      assert report.dry_run?
      assert [%{name: "Fsync A"}] = sections(admin)

      assert {:ok, _} = apply!(doc, admin)
      assert [%{name: "Fsync B", display: :tab}] = sections(admin)

      # A file with no "sections" key moves the field the same way: the
      # layout it left goes, and the new section has none.
      field!(admin, %{name: "dose", label: "Dose", field_type: :string, section: "Fsync C"})

      CMS.create_field_section!(%{content_type: :post, name: "Fsync C", display: :tab},
        actor: admin
      )

      doc =
        [string_field("latin", "Fsync B"), string_field("dose", "Fsync D")]
        |> post_doc([])
        |> update_in(["owners", Access.all()], &Map.delete(&1, "sections"))

      assert {:ok, _} = apply!(doc, admin)
      assert [%{name: "Fsync B"}] = sections(admin)
    end

    test "a layout the import leaves with no field is planned as a delete, not kept",
         %{admin: admin} do
      field!(admin, %{name: "latin", label: "Latin", field_type: :string, section: "Fsync A"})
      field!(admin, %{name: "dose", label: "Dose", field_type: :string, section: "Fsync Old"})

      CMS.create_field_section!(%{content_type: :post, name: "Fsync A", display: :tab},
        actor: admin
      )

      # An orphan no write of this import makes: left as it was (S11).
      orphan_layout!(%{content_type: :post, name: "Fsync Orphan", display: :tab})

      # A's row is not in the file, and its last field moves out of it.
      doc =
        post_doc(
          [string_field("latin", "Fsync B"), string_field("dose", "Fsync Old")],
          [%{"name" => "Fsync B", "display" => "tab"}]
        )

      assert {:ok, dry} = FieldSync.import_doc(doc, actor: admin)
      assert %{op: :delete} = Enum.find(dry.ops, &(&1.path == "post/section/Fsync A"))
      refute "post/section/Fsync A" in dry.untouched
      assert "post/section/Fsync Orphan" in dry.untouched
      assert FieldSync.describe(dry) =~ "- post/section/Fsync A"

      assert ["Fsync A", "Fsync Orphan"] ==
               admin |> sections() |> Enum.map(& &1.name) |> Enum.sort()

      assert {:ok, applied} = apply!(doc, admin)
      assert FieldSync.digest(applied) == FieldSync.digest(dry)

      assert ["Fsync B", "Fsync Orphan"] ==
               admin |> sections() |> Enum.map(& &1.name) |> Enum.sort()

      # A file with no "sections" key plans the same delete.
      field!(admin, %{name: "rank", label: "Rank", field_type: :string, section: "Fsync C"})

      CMS.create_field_section!(%{content_type: :post, name: "Fsync C", display: :tab},
        actor: admin
      )

      doc =
        [string_field("latin", "Fsync B"), string_field("rank", nil)]
        |> post_doc([])
        |> update_in(["owners", Access.all()], &Map.delete(&1, "sections"))

      assert {:ok, report} = apply!(doc, admin)
      assert %{op: :delete} = Enum.find(report.ops, &(&1.path == "post/section/Fsync C"))
      refute "Fsync C" in Enum.map(sections(admin), & &1.name)
    end

    test "two fields swapping sections keep both layouts", %{admin: admin} do
      field!(admin, %{name: "latin", label: "Latin", field_type: :string, section: "Fsync A"})
      field!(admin, %{name: "dose", label: "Dose", field_type: :string, section: "Fsync B"})

      CMS.create_field_section!(%{content_type: :post, name: "Fsync A", display: :tab},
        actor: admin
      )

      CMS.create_field_section!(%{content_type: :post, name: "Fsync B", display: :fieldset},
        actor: admin
      )

      # Each write alone leaves its old section empty for a moment; the
      # layouts are reconciled only once both have run.
      doc =
        post_doc(
          [string_field("latin", "Fsync B"), string_field("dose", "Fsync A")],
          [
            %{"name" => "Fsync A", "display" => "tab"},
            %{"name" => "Fsync B", "display" => "fieldset"}
          ]
        )

      assert {:ok, _} = apply!(doc, admin)

      assert [%{name: "Fsync A", display: :tab}, %{name: "Fsync B", display: :fieldset}] =
               admin |> sections() |> Enum.sort_by(& &1.name)
    end

    test "a layout for a section no field carries is refused, in a dry run and an apply",
         %{admin: admin} do
      field!(admin, %{
        name: "rating",
        label: "Rating",
        field_type: :integer,
        section: "Fsync Main"
      })

      doc =
        post_doc(
          [string_field("rating", "Fsync Main") |> Map.put("field_type", "integer")],
          [
            %{"name" => "Fsync Main", "display" => "tab"},
            %{"name" => "Fsync Ghost", "display" => "tab"}
          ]
        )

      for opts <- [[], [apply?: true], [apply?: true, prune?: true]] do
        assert {:error, report} = FieldSync.import_doc(doc, [actor: admin] ++ opts)
        assert [%{path: "post/section/Fsync Ghost", messages: [message]}] = report.errors
        assert message =~ "no field of post is in this section"
        assert FieldSync.describe(report) =~ "ERROR post/section/Fsync Ghost"
        refute report.applied?
        assert sections(admin) == []
      end

      # At the defaults, the entry stores nothing, so it is no ghost.
      doc =
        put_in(doc, ["owners", Access.at(0), "sections", Access.at(1)], %{"name" => "Fsync Ghost"})

      assert {:ok, _} = apply!(doc, admin)
      assert [%{name: "Fsync Main"}] = sections(admin)
    end

    test "a stored field the import keeps carries its section; one it prunes does not",
         %{admin: admin} do
      field!(admin, %{name: "dose", label: "Dose", field_type: :string, section: "Fsync Kept"})
      doc = post_doc([], [%{"name" => "Fsync Kept", "display" => "tab"}])

      assert {:error, %{errors: [%{path: "post/section/Fsync Kept"}]}} =
               apply!(doc, admin, prune?: true)

      assert sections(admin) == []

      assert {:ok, _} = apply!(doc, admin)
      assert [%{name: "Fsync Kept", display: :tab}] = sections(admin)
    end

    test "a field of a type this release does not know carries its section, even when pruning",
         %{admin: admin} do
      KilnCMS.NewerReleaseRows.field_definition!(%{content_type: "post", section: "Fsync Specs"})
      doc = post_doc([], [%{"name" => "Fsync Specs", "display" => "tab"}])

      assert {:ok, _} = apply!(doc, admin, prune?: true)
      assert [%{name: "Fsync Specs", display: :tab}] = sections(admin)
    end

    # `FieldSection`'s create refuses a section no field is in (#3061), so
    # the import writes its fields first: a new section's first field and its
    # layout arrive in the same file.
    test "a new field in a new section and that section's layout import together",
         %{admin: admin} do
      doc =
        post_doc(
          [string_field("fsync_new", "Fsync Fresh")],
          [%{"name" => "Fsync Fresh", "display" => "fieldset", "initially" => "auto"}]
        )

      assert {:ok, dry} = FieldSync.import_doc(doc, actor: admin)
      assert dry.errors == []
      assert %{op: :create} = Enum.find(dry.ops, &(&1.path == "post/section/Fsync Fresh"))
      assert sections(admin) == []

      assert {:ok, applied} = apply!(doc, admin)
      assert FieldSync.digest(applied) == FieldSync.digest(dry)
      assert [%{name: "Fsync Fresh", display: :fieldset}] = sections(admin)
    end

    test "a layout for a section the import moves its only field out of is refused",
         %{admin: admin} do
      field!(admin, %{name: "dose", label: "Dose", field_type: :string, section: "Fsync Was"})

      doc =
        post_doc(
          [string_field("dose", "Fsync Now")],
          [%{"name" => "Fsync Was", "display" => "tab"}]
        )

      for opts <- [[], [apply?: true]] do
        assert {:error, report} = FieldSync.import_doc(doc, [actor: admin] ++ opts)
        assert [%{path: "post/section/Fsync Was", messages: [message]}] = report.errors
        assert message =~ "no field of post is in this section"
      end

      assert sections(admin) == []
      assert [%{section: "Fsync Was"}] = CMS.field_definitions_for!(:post, actor: admin)
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
