defmodule KilnCMS.CMS.FlexibleAuditTest do
  @moduledoc """
  The top-level-predicate audit for the flexible-content model (#2282,
  `docs/flexible-content-plan.md` section 2).

  Every reader of "a type's own fields" used to decide *top level* with its own
  copy of `is_nil(link_of_id) and is_nil(group_of_id)`. An item type
  (`flex_of_id`) has neither, so each copy would have taken it for a field of
  the type. They all go through `FieldDefinition.top_level?/1` now; this runs
  a fixture holding an item-type row — carrying every flag a top-level field
  could set, under the name of a real field — through each reader and asserts
  none of them lets it count.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.FieldAccess
  alias KilnCMS.CMS.FieldDefinition
  alias KilnCMS.CMS.FieldSync
  alias KilnCMS.CMS.FieldWidgets
  alias KilnCMS.CMS.PlainFields
  alias KilnCMS.CMS.PortableFields
  alias KilnCMS.CMS.PrivateFields
  alias KilnCMS.CMS.ReferenceSelection

  # A row owned only by a flexible field, wearing everything a plain top-level
  # text field may set. A real one cannot (the model clears or refuses each
  # flag); a stale or hand-seeded one could, and no reader may take it for the
  # field it shares a name with.
  defp ghost(name, attrs \\ %{}) do
    Map.merge(
      %{
        id: Ash.UUID.generate(),
        name: name,
        label: name,
        field_type: :text,
        format: :rich,
        content_type: nil,
        type_definition_id: nil,
        link_of_id: nil,
        group_of_id: nil,
        flex_of_id: Ash.UUID.generate(),
        private: true,
        deliver_plain: true,
        deliver_portable: true,
        multiple: false,
        options: [],
        allow_custom: false
      },
      attrs
    )
  end

  defp top(name, attrs \\ %{}),
    do: ghost(name, Map.merge(%{flex_of_id: nil, content_type: :post}, attrs))

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "flex-audit-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  describe "readers over a definitions list" do
    test "top_level?/1 is false for an item-type row and for its sub-fields" do
      assert FieldDefinition.top_level?(top("a"))
      refute FieldDefinition.top_level?(ghost("a"))
      refute FieldDefinition.top_level?(ghost("a", %{flex_of_id: nil, group_of_id: "g"}))
      refute FieldDefinition.top_level?(ghost("a", %{flex_of_id: nil, link_of_id: "l"}))
    end

    test "PlainFields and PortableFields deliver only top-level fields" do
      defs = [ghost("body"), top("note", %{private: false})]

      assert PlainFields.names(defs) == ["note"]
      assert PortableFields.names(defs) == ["note"]
    end

    test "FieldAccess neither hides nor names an item-type row" do
      defs = [ghost("shadow"), top("secret"), top("shadow", %{private: false})]

      assert FieldAccess.hidden_names(defs, [], []) == ["secret"]

      # Found first, the ghost would make `shadow` look private.
      refute FieldAccess.valid_read_entry?("custom_fields.shadow", defs)
      assert FieldAccess.valid_read_entry?("custom_fields.secret", defs)
    end

    test "FieldWidgets offers an item-type row no choice of input" do
      ghost_select = ghost("pick", %{field_type: :select, options: ["a", "b"], private: false})
      top_select = top("pick", %{field_type: :select, options: ["a", "b"], private: false})

      assert FieldWidgets.allowed(ghost_select) == []
      assert FieldWidgets.allowed(top_select) != []
    end

    test "a reference selection may not filter on an item-type row" do
      ghost_field = ghost("rating", %{field_type: :integer, private: false})
      top_field = top("rating", %{field_type: :integer, private: false})

      refute ReferenceSelection.equality_field?(ghost_field)
      assert ReferenceSelection.equality_field?(top_field)
    end
  end

  describe "readers over the stored rows" do
    setup do
      admin = user(:admin)

      flexible =
        CMS.create_field_definition!(
          %{content_type: :post, name: "sections", label: "Sections", field_type: :flexible},
          actor: admin
        )

      item =
        CMS.create_field_definition!(
          %{name: "hero", label: "Hero", field_type: :group, flex_of_id: flexible.id},
          actor: admin
        )

      sub =
        CMS.create_field_definition!(
          %{name: "headline", label: "Headline", field_type: :string, group_of_id: item.id},
          actor: admin
        )

      %{admin: admin, flexible: flexible, item: item, sub: sub}
    end

    test "PrivateFields lists no item-type row, even a seeded private one", ctx do
      %{flexible: flexible} = ctx

      Ash.Seed.seed!(FieldDefinition, %{
        name: "ghost_secret",
        label: "Ghost",
        field_type: :string,
        private: true,
        flex_of_id: flexible.id,
        org_id: KilnCMS.Accounts.default_org_id()
      })

      # Filed under no owner at all if it slipped through, so look at every key.
      assert PrivateFields.all(KilnCMS.Accounts.default_org_id())
             |> Map.values()
             |> List.flatten() ==
               []
    end

    test "FieldSync exports a flexible field with its item types and their sub-fields", ctx do
      assert {:ok, doc} = FieldSync.export(actor: ctx.admin)
      names = names_in(doc)

      assert "sections" in names
      assert "hero" in names
      assert "headline" in names
    end

    test "a pruning import of the site's own export changes nothing", ctx do
      %{admin: admin, flexible: flexible, item: item, sub: sub} = ctx
      {:ok, doc} = FieldSync.export(actor: admin)

      assert {:ok, report} =
               FieldSync.import_doc(doc, actor: admin, apply?: true, prune?: true)

      assert Map.keys(report.counts) == [:unchanged]
      assert report.untouched == []

      for id <- [flexible.id, item.id, sub.id],
          do: assert({:ok, _} = CMS.get_field_definition(id, actor: admin))
    end

    test "a pruning import that drops a flexible field takes its item types with it", ctx do
      %{admin: admin, item: item} = ctx
      {:ok, doc} = FieldSync.export(actor: admin)

      stripped =
        update_in(doc, ["owners", Access.all(), "fields"], fn fields ->
          Enum.reject(fields || [], &(&1["name"] == "sections"))
        end)

      assert {:ok, _report} =
               FieldSync.import_doc(stripped, actor: admin, apply?: true, prune?: true)

      assert {:error, _} = CMS.get_field_definition(item.id, actor: admin)
    end

    test "the schema export's custom fields list neither", ctx do
      properties =
        KilnCMS.SchemaExport.json_schema()["$defs"][KilnCMS.SchemaExport.content_def_name(:post)][
          "properties"
        ]["custom_fields"]["properties"]

      assert Map.has_key?(properties, ctx.flexible.name)
      refute Map.has_key?(properties, "hero")
      refute Map.has_key?(properties, "headline")
    end
  end

  defp names_in(%{} = doc), do: doc |> collect([]) |> Enum.uniq()

  defp collect(%{"name" => name} = map, acc) when is_binary(name),
    do: map |> Map.values() |> Enum.reduce([name | acc], &collect/2)

  defp collect(%{} = map, acc), do: map |> Map.values() |> Enum.reduce(acc, &collect/2)
  defp collect(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect/2)
  defp collect(_other, acc), do: acc
end
