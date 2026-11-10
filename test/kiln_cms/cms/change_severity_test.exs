defmodule KilnCMS.CMS.ChangeSeverityTest do
  @moduledoc """
  Mandatory change severity per published edit (`KilnCMS.CMS.Severity`): the
  version row of an edit that touches a site-listed safety field carries a
  severity, and no other version does.
  """
  # `async: false`: the safety-field list is one row per organization, cached
  # under a key that is the organization alone, and these tests all use the
  # default org. Run concurrently they would overwrite each other's list.
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sev-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "sev-#{System.unique_integer([:positive])}"
  defp heading(text), do: %{"_type" => "heading", "text" => text}

  defp list_safety(admin, fields) do
    CMS.save_site_safety_fields!(%{fields: fields},
      actor: admin,
      tenant: KilnCMS.Accounts.default_org_id()
    )
  end

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp live_page(admin, attrs \\ %{}) do
    page =
      CMS.create_page!(
        Map.merge(%{title: "Live", slug: slug(), blocks: [heading("Body")]}, attrs),
        actor: admin
      )

    page |> CMS.publish_page!(%{}, actor: admin) |> reload()
  end

  defp versions(page) do
    CMS.list_page_versions!(authorize?: false, tenant: page.org_id)
    |> Enum.filter(&(&1.version_source_id == page.id))
    |> Enum.sort_by(&{DateTime.to_unix(&1.version_inserted_at, :microsecond), &1.id}, :asc)
  end

  # The newest version written by `action`.
  defp last_version(page, action) do
    page |> versions() |> Enum.filter(&(&1.version_action_name == action)) |> List.last()
  end

  defp severity(page, action), do: last_version(page, action).change_severity

  setup do
    %{admin: user(:admin)}
  end

  describe "nil iff no safety field changed" do
    test "an edit that touches only unlisted fields stores no severity", %{admin: admin} do
      list_safety(admin, %{"page" => ["title", "blocks"]})
      page = live_page(admin)

      CMS.update_page!(page, %{seo_title: "A title tag"}, actor: admin)

      assert severity(page, :update) == nil
    end

    test "an edit that resubmits a listed field unchanged stores no severity", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})
      page = live_page(admin)

      CMS.update_page!(page, %{title: page.title, seo_title: "A title tag"}, actor: admin)

      assert severity(page, :update) == nil
    end

    test "a severity sent with an edit that touches no safety field is dropped", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})
      page = live_page(admin)

      CMS.update_page!(page, %{seo_title: "A title tag", change_severity: :critical},
        actor: admin
      )

      assert severity(page, :update) == nil
    end

    test "empty settings: nothing prompts and nothing is recorded", %{admin: admin} do
      page = live_page(admin)

      CMS.update_page!(page, %{title: "Renamed"},
        actor: admin,
        context: %{require_change_severity: true}
      )

      assert severity(page, :update) == nil
    end

    test "a type with no entry is unaffected by another type's list", %{admin: admin} do
      list_safety(admin, %{"post" => ["title"]})
      page = live_page(admin)

      CMS.update_page!(page, %{title: "Renamed"},
        actor: admin,
        context: %{require_change_severity: true}
      )

      assert severity(page, :update) == nil
    end

    test "editing a draft never records one", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})
      page = CMS.create_page!(%{title: "Draft", slug: slug()}, actor: admin)

      CMS.update_page!(page, %{title: "Draft 2"},
        actor: admin,
        context: %{require_change_severity: true}
      )

      assert Enum.all?(versions(page), &is_nil(&1.change_severity))
    end
  end

  describe "an edit that touches a safety field" do
    setup %{admin: admin} do
      list_safety(admin, %{"page" => ["title", "blocks", "seo_description"]})
      %{page: live_page(admin)}
    end

    test "defaults to :notable without a marker (API, MCP, internal writers)", ctx do
      CMS.update_page!(ctx.page, %{title: "Renamed"}, actor: ctx.admin)

      assert severity(ctx.page, :update) == :notable
    end

    test "stores an explicit severity", ctx do
      CMS.update_page!(ctx.page, %{title: "Renamed", change_severity: :critical},
        actor: ctx.admin
      )

      assert severity(ctx.page, :update) == :critical
    end

    test "a block change counts", ctx do
      CMS.update_page!(ctx.page, %{block_tree: [heading("Different body")]}, actor: ctx.admin)

      assert severity(ctx.page, :update) == :notable
    end

    test "the marker without a severity is an error on change_severity", ctx do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               CMS.update_page(ctx.page, %{title: "Renamed"},
                 actor: ctx.admin,
                 context: %{require_change_severity: true}
               )

      assert Enum.any?(errors, &(Map.get(&1, :field) == :change_severity))
      assert reload(ctx.page).title == "Live"
    end

    test "the marker with a severity goes through", ctx do
      CMS.update_page!(ctx.page, %{title: "Renamed", change_severity: :routine},
        actor: ctx.admin,
        context: %{require_change_severity: true}
      )

      assert severity(ctx.page, :update) == :routine
    end

    test "the marker does not ask when no safety field changed", ctx do
      CMS.update_page!(ctx.page, %{seo_title: "A title tag"},
        actor: ctx.admin,
        context: %{require_change_severity: true}
      )

      assert severity(ctx.page, :update) == nil
    end

    test "two consecutive edits each carry their own severity", ctx do
      first =
        CMS.update_page!(ctx.page, %{title: "One", change_severity: :critical}, actor: ctx.admin)

      CMS.update_page!(first, %{title: "Two", change_severity: :routine}, actor: ctx.admin)

      second = reload(first)
      CMS.update_page!(second, %{title: "Three"}, actor: ctx.admin)

      severities =
        ctx.page
        |> versions()
        |> Enum.filter(&(&1.version_action_name == :update))
        |> Enum.map(& &1.change_severity)

      assert severities == [:critical, :routine, :notable]
    end

    test "an edit that touches no safety field after one that did carries nothing", ctx do
      first =
        CMS.update_page!(ctx.page, %{title: "One", change_severity: :critical}, actor: ctx.admin)

      CMS.update_page!(first, %{seo_title: "later tag"}, actor: ctx.admin)

      severities =
        ctx.page
        |> versions()
        |> Enum.filter(&(&1.version_action_name == :update))
        |> Enum.map(& &1.change_severity)

      assert severities == [:critical, nil]
    end

    test "a restore that reverts a safety field is an edit: :notable", ctx do
      original = versions(ctx.page) |> List.last()
      renamed = CMS.update_page!(ctx.page, %{title: "Renamed"}, actor: ctx.admin)

      CMS.restore_page_version!(renamed, %{version_id: original.id}, actor: ctx.admin)

      assert severity(ctx.page, :restore_version) == :notable
    end

    test "a restore may carry an explicit severity", ctx do
      original = versions(ctx.page) |> List.last()
      renamed = CMS.update_page!(ctx.page, %{title: "Renamed"}, actor: ctx.admin)

      CMS.restore_page_version!(renamed, %{version_id: original.id, change_severity: :critical},
        actor: ctx.admin
      )

      assert severity(ctx.page, :restore_version) == :critical
    end

    test "a restore that changes no safety field carries nothing", ctx do
      original = versions(ctx.page) |> List.last()
      tagged = CMS.update_page!(ctx.page, %{seo_title: "A title tag"}, actor: ctx.admin)

      CMS.restore_page_version!(tagged, %{version_id: original.id}, actor: ctx.admin)

      assert reload(ctx.page).seo_title == nil

      assert severity(ctx.page, :restore_version) == nil
    end
  end

  describe "publish changes (the working copy)" do
    setup %{admin: admin} do
      list_safety(admin, %{"page" => ["title", "blocks"]})
      %{page: live_page(admin)}
    end

    defp save_copy(page, attrs, actor) do
      CMS.save_page_working_copy!(page, attrs, actor: actor, tenant: page.org_id)
    end

    test "publish after several autosaves puts the severity on the publish row", ctx do
      copy = save_copy(ctx.page, %{working_title: "Draft 1"}, ctx.admin)

      copy =
        save_copy(copy, %{working_title: "Draft 2", working_blocks: [heading("New")]}, ctx.admin)

      copy = save_copy(reload(copy), %{working_title: "Draft 3"}, ctx.admin)

      CMS.publish_page_changes!(reload(copy), %{change_severity: :critical},
        actor: ctx.admin,
        context: %{require_change_severity: true}
      )

      versions = versions(ctx.page)
      assert last_version(ctx.page, :publish_changes).change_severity == :critical

      assert versions
             |> Enum.filter(&(&1.version_action_name == :save_working_copy))
             |> Enum.all?(&is_nil(&1.change_severity))
    end

    test "working-copy saves never need a severity, even with the marker", ctx do
      assert %{} =
               CMS.save_page_working_copy!(ctx.page, %{working_title: "Held"},
                 actor: ctx.admin,
                 tenant: ctx.page.org_id,
                 context: %{require_change_severity: true}
               )
    end

    test "publishing a held safety change with the marker and no severity is refused", ctx do
      copy = save_copy(ctx.page, %{working_title: "Held title"}, ctx.admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               CMS.publish_page_changes(reload(copy), %{},
                 actor: ctx.admin,
                 context: %{require_change_severity: true}
               )

      assert Enum.any?(errors, &(Map.get(&1, :field) == :change_severity))
      assert reload(copy).title == "Live"
    end

    test "without the marker the publish defaults to :notable", ctx do
      copy = save_copy(ctx.page, %{working_title: "Held title"}, ctx.admin)
      CMS.publish_page_changes!(reload(copy), %{}, actor: ctx.admin)

      assert severity(ctx.page, :publish_changes) == :notable
    end

    test "a held change to an unlisted field needs no severity", ctx do
      copy = save_copy(ctx.page, %{fields: %{"seo_title" => "A title tag"}}, ctx.admin)

      CMS.publish_page_changes!(reload(copy), %{},
        actor: ctx.admin,
        context: %{require_change_severity: true}
      )

      assert severity(ctx.page, :publish_changes) == nil
    end

    test "the second publish does not inherit the first one's severity", ctx do
      copy = save_copy(ctx.page, %{working_title: "One"}, ctx.admin)

      published =
        CMS.publish_page_changes!(reload(copy), %{change_severity: :critical}, actor: ctx.admin)

      copy = save_copy(reload(published), %{working_title: "Two"}, ctx.admin)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.publish_page_changes(reload(copy), %{},
                 actor: ctx.admin,
                 context: %{require_change_severity: true}
               )
    end
  end

  describe "first publish" do
    test "a non-empty listed field counts", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})
      page = CMS.create_page!(%{title: "Fresh", slug: slug()}, actor: admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               CMS.publish_page(page, %{},
                 actor: admin,
                 context: %{require_change_severity: true}
               )

      assert Enum.any?(errors, &(Map.get(&1, :field) == :change_severity))

      CMS.publish_page!(page, %{change_severity: :routine},
        actor: admin,
        context: %{require_change_severity: true}
      )

      assert severity(page, :publish) == :routine
    end

    test "defaults to :notable without a marker", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})
      page = CMS.create_page!(%{title: "Fresh", slug: slug()}, actor: admin)
      CMS.publish_page!(page, %{}, actor: admin)

      assert severity(page, :publish) == :notable
    end

    test "after several autosaves the publish row carries it", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})
      page = CMS.create_page!(%{title: "Fresh", slug: slug()}, actor: admin)
      page = CMS.update_page!(page, %{title: "Fresh 2"}, actor: admin)
      page = CMS.update_page!(page, %{title: "Fresh 3"}, actor: admin)
      CMS.publish_page!(page, %{change_severity: :critical}, actor: admin)

      assert severity(page, :publish) == :critical
      assert Enum.count(versions(page), & &1.change_severity) == 1
    end

    test "an empty listed field does not count", %{admin: admin} do
      list_safety(admin, %{"page" => ["seo_description"]})
      page = CMS.create_page!(%{title: "Fresh", slug: slug()}, actor: admin)

      CMS.publish_page!(page, %{}, actor: admin, context: %{require_change_severity: true})

      assert severity(page, :publish) == nil
    end

    test "a scheduled publish defaults to :notable", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})
      page = CMS.create_page!(%{title: "Later", slug: slug()}, actor: admin)
      CMS.publish_scheduled_page!(page, %{}, authorize?: false)

      assert severity(page, :publish_scheduled) == :notable
    end
  end

  describe "everything listed" do
    test "\"*\" makes every editorial field safety-relevant", %{admin: admin} do
      list_safety(admin, %{"page" => ["*"]})
      page = live_page(admin)

      CMS.update_page!(page, %{seo_title: "A title tag"}, actor: admin)

      assert severity(page, :update) == :notable
    end
  end

  describe "custom fields on a built-in type" do
    defp define_field!(admin, name, attrs \\ %{}) do
      CMS.create_field_definition!(
        Map.merge(%{content_type: :page, name: name, label: String.capitalize(name)}, attrs),
        actor: admin
      )
    end

    test "a listed custom field that changes records a severity", %{admin: admin} do
      define_field!(admin, "price")
      list_safety(admin, %{"page" => ["price"]})
      page = live_page(admin, %{custom_fields: %{"price" => "9"}})

      CMS.update_page!(page, %{custom_fields: %{"price" => "12"}}, actor: admin)

      assert severity(page, :update) == :notable
    end

    test "an unlisted custom key changing alongside a listed one that did not stores none",
         %{admin: admin} do
      define_field!(admin, "price")
      define_field!(admin, "sku")
      list_safety(admin, %{"page" => ["price"]})
      page = live_page(admin, %{custom_fields: %{"price" => "9", "sku" => "a"}})

      CMS.update_page!(page, %{custom_fields: %{"price" => "9", "sku" => "b"}}, actor: admin)

      assert severity(page, :update) == nil
    end

    test "several listed keys: any one changing is enough", %{admin: admin} do
      define_field!(admin, "price")
      define_field!(admin, "sku")
      list_safety(admin, %{"page" => ["price", "sku"]})
      page = live_page(admin, %{custom_fields: %{"price" => "9", "sku" => "a"}})

      CMS.update_page!(page, %{custom_fields: %{"price" => "9", "sku" => "b"}}, actor: admin)

      assert severity(page, :update) == :notable
    end

    test "several listed keys changing at once record one severity", %{admin: admin} do
      define_field!(admin, "price")
      define_field!(admin, "sku")
      list_safety(admin, %{"page" => ["price", "sku"]})
      page = live_page(admin, %{custom_fields: %{"price" => "9", "sku" => "a"}})

      CMS.update_page!(
        page,
        %{custom_fields: %{"price" => "10", "sku" => "b"}, change_severity: :critical},
        actor: admin
      )

      assert severity(page, :update) == :critical
    end

    # Surprise worth pinning: the raw attribute name is read as a custom KEY
    # called "custom_fields" (`field_ref/2`), not as the whole map, so listing
    # it never matches an edit. Only a named key or "*" does.
    test "the raw name custom_fields is not a whole-map alias", %{admin: admin} do
      define_field!(admin, "price")
      list_safety(admin, %{"page" => ["custom_fields"]})
      page = live_page(admin, %{custom_fields: %{"price" => "9"}})

      CMS.update_page!(page, %{custom_fields: %{"price" => "12"}}, actor: admin)

      assert severity(page, :update) == nil
    end

    test "\"*\" counts an edit to any one custom key", %{admin: admin} do
      define_field!(admin, "price")
      list_safety(admin, %{"page" => ["*"]})
      page = live_page(admin, %{custom_fields: %{"price" => "9"}})

      CMS.update_page!(page, %{custom_fields: %{"price" => "12"}}, actor: admin)

      assert severity(page, :update) == :notable
    end

    test "a computed field listed by name records a severity when its value changes",
         %{admin: admin} do
      define_field!(admin, "echo", %{field_type: :computed, compute: "{{ title }}"})
      list_safety(admin, %{"page" => ["echo"]})
      page = live_page(admin)

      CMS.update_page!(page, %{seo_title: "Unrelated"}, actor: admin)
      assert severity(page, :update) == nil

      CMS.update_page!(reload(page), %{title: "Renamed"}, actor: admin)
      assert severity(page, :update) == :notable
    end

    test "the first publish with a listed custom value records a severity", %{admin: admin} do
      define_field!(admin, "price")
      list_safety(admin, %{"page" => ["price"]})

      page =
        CMS.create_page!(
          %{
            title: "Fresh",
            slug: slug(),
            blocks: [heading("Body")],
            custom_fields: %{"price" => "9"}
          },
          actor: admin
        )

      CMS.publish_page!(page, %{}, actor: admin)

      assert severity(page, :publish) == :notable
    end

    test "the first publish without a listed custom value records none", %{admin: admin} do
      define_field!(admin, "price")
      list_safety(admin, %{"page" => ["price"]})
      page = CMS.create_page!(%{title: "Fresh", slug: slug()}, actor: admin)
      CMS.publish_page!(page, %{}, actor: admin)

      assert severity(page, :publish) == nil
    end

    test "a retired key cannot be edited, but clearing it still counts when listed",
         %{admin: admin} do
      definition = define_field!(admin, "price")
      page = live_page(admin, %{custom_fields: %{"price" => "9"}})
      CMS.destroy_field_definition!(definition, actor: admin)
      list_safety(admin, %{"page" => ["price"]})

      # The registry refuses a value for a key with no definition.
      assert {:error, %Ash.Error.Invalid{}} =
               CMS.update_page(page, %{custom_fields: %{"price" => "12"}}, actor: admin)

      assert last_version(page, :update) == nil

      # Dropping the stale key is a change to a listed key.
      CMS.update_page!(page, %{custom_fields: %{}}, actor: admin)

      assert severity(page, :update) == :notable
    end
  end

  describe "dynamic types (Entry)" do
    test "the list is keyed on the record's own type, custom fields included", %{admin: admin} do
      name = "recipe#{System.unique_integer([:positive])}"
      definition = CMS.create_type_definition!(%{name: name, label: "Recipe"}, actor: admin)

      CMS.create_field_definition!(
        %{type_definition_id: definition.id, name: "dose", label: "Dose", field_type: :string},
        actor: admin
      )

      list_safety(admin, %{name => ["dose"], "entry" => ["title"]})

      entry =
        KilnCMS.CMS.ContentTypes.create!(
          name,
          %{title: "Tea", slug: slug(), blocks: [], custom_fields: %{"dose" => "1 g"}},
          actor: admin
        )

      entry = CMS.publish_entry!(entry, %{}, actor: admin)

      # `title` is listed under "entry" only; the record's type is `name`.
      entry = CMS.update_entry!(entry, %{title: "Tea 2"}, actor: admin)

      # The newest version `action` wrote. The read has no ORDER BY, so sort
      # as `versions/1` does: in heap order the older `:update` can come last
      # (#2550).
      version = fn action ->
        CMS.list_entry_versions!(authorize?: false, tenant: entry.org_id)
        |> Enum.filter(&(&1.version_source_id == entry.id and &1.version_action_name == action))
        |> Enum.max_by(&{DateTime.to_unix(&1.version_inserted_at, :microsecond), &1.id})
      end

      assert version.(:update).change_severity == nil

      CMS.update_entry!(
        entry,
        %{custom_fields: %{"dose" => "5 g"}, change_severity: :critical},
        actor: admin
      )

      assert version.(:update).change_severity == :critical
    end
  end

  describe "the settings" do
    test "an admin saves them and an editor reads them", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})
      editor = user(:editor)

      assert [%{fields: %{"page" => ["title"]}}] =
               CMS.list_site_safety_fields!(
                 actor: editor,
                 tenant: KilnCMS.Accounts.default_org_id()
               )
    end

    test "an editor and a viewer cannot change them" do
      for role <- [:editor, :viewer] do
        actor = user(role)

        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.save_site_safety_fields(%{fields: %{"page" => ["title"]}},
                   actor: actor,
                   tenant: KilnCMS.Accounts.default_org_id()
                 )
      end
    end

    test "a viewer cannot read them", %{admin: admin} do
      list_safety(admin, %{"page" => ["title"]})

      assert {:ok, []} =
               CMS.list_site_safety_fields(
                 actor: user(:viewer),
                 tenant: KilnCMS.Accounts.default_org_id()
               )
    end

    test "a malformed value is refused", %{admin: admin} do
      for bad <- [%{"page" => "title"}, %{"page" => [1]}, %{"" => ["title"]}] do
        assert {:error, %Ash.Error.Invalid{}} =
                 CMS.save_site_safety_fields(%{fields: bad},
                   actor: admin,
                   tenant: KilnCMS.Accounts.default_org_id()
                 )
      end
    end

    test "a save applies to the very next edit", %{admin: admin} do
      page = live_page(admin)
      page = CMS.update_page!(page, %{title: "One"}, actor: admin)
      list_safety(admin, %{"page" => ["title"]})
      CMS.update_page!(page, %{title: "Two"}, actor: admin)

      severities =
        page
        |> versions()
        |> Enum.filter(&(&1.version_action_name == :update))
        |> Enum.map(& &1.change_severity)

      assert severities == [nil, :notable]
    end
  end
end
