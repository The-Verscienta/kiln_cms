defmodule KilnCMSWeb.ReferencePickerSelectionTest do
  @moduledoc """
  The reference picker honors a field's `selection` (#2285, PR 2): search and
  the dropdown list only targets the field accepts, the empty state and a
  footer say why, and the reverse field disables its add control for a target
  the field would refuse. The filter is one more AND on a read the actor's own
  policy gates, and evaluates server-side.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, attrs \\ %{}) do
    email = "ref-sel-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(
      User,
      Map.merge(
        %{
          email: email,
          hashed_password: Bcrypt.hash_pwd_salt(@password),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp uniq, do: System.unique_integer([:positive])

  defp page!(title, actor, opts \\ []) do
    page = CMS.create_page!(%{title: title, slug: "rps-#{uniq()}"}, actor: actor)

    if opts[:publish],
      do: CMS.publish_page!(page, %{}, actor: opts[:publisher] || actor),
      else: page
  end

  defp field!(admin, name, selection, extra \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: name,
          label: "Linked #{name}",
          field_type: :reference,
          target_type: "page",
          selection: selection
        },
        extra
      ),
      actor: admin
    )
  end

  defp open_editor(conn, user, post) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/post/#{post.id}")
    lv
  end

  defp search(lv, field, query) do
    lv
    |> element("#custom-field-#{field}-search")
    |> render_change(%{"_kiln_ref_q" => %{field => query}})
  end

  defp option_ids(lv, field) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#custom-field-#{field}-listbox [role=option][phx-value-id]")
    |> LazyHTML.attribute("phx-value-id")
  end

  defp option_titles(lv, field) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#custom-field-#{field}-listbox [role=option][phx-value-id] span.truncate")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  setup do
    admin = authed_user(:admin)
    editor = authed_user(:editor)
    word = "Quince#{uniq()}"

    %{
      admin: admin,
      editor: editor,
      word: word,
      published: page!("#{word} Pub", admin, publish: true),
      draft: page!("#{word} Draft", admin),
      mine: page!("#{word} Mine", editor, publish: true, publisher: admin),
      post: CMS.create_post!(%{title: "Host", slug: "rps-#{uniq()}"}, actor: admin)
    }
  end

  describe "search" do
    test "lists only the states the field accepts; a hand-picked other is not a result", ctx do
      field!(ctx.admin, "only_live", %{"states" => ["published"]})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)

      search(lv, "only_live", ctx.word)
      ids = option_ids(lv, "only_live")
      assert ctx.published.id in ids
      assert ctx.mine.id in ids
      refute ctx.draft.id in ids

      # A forged pick of a filtered-out record connects nothing.
      lv |> element("#custom-field-only_live") |> render_hook("ref_pick", %{"id" => ctx.draft.id})
      refute has_element?(lv, "#custom-field-only_live-items")
    end

    test "owner: self lists only records the actor created", ctx do
      field!(ctx.admin, "mine_only", %{"owner" => "self"})
      lv = open_editor(build_conn(), ctx.editor, ctx.post)

      search(lv, "mine_only", ctx.word)
      assert option_ids(lv, "mine_only") == [ctx.mine.id]
    end

    test "the filter never widens what the actor can read", ctx do
      field!(ctx.admin, "draftable", %{"states" => ["draft", "published"]})
      # An editor can read drafts; a viewer-scoped actor could not. The filter
      # only ANDs, so the unreadable stay unlisted: check a trashed record.
      CMS.destroy_page!(ctx.draft, actor: ctx.admin)
      lv = open_editor(build_conn(), ctx.editor, ctx.post)

      search(lv, "draftable", ctx.word)
      refute ctx.draft.id in option_ids(lv, "draftable")
    end

    test "a field-equality condition is evaluated on the server", ctx do
      CMS.create_field_definition!(
        %{content_type: :page, name: "diet", label: "Diet", field_type: :string},
        actor: ctx.admin
      )

      vegan =
        CMS.create_page!(
          %{
            title: "#{ctx.word} Vegan",
            slug: "rps-#{uniq()}",
            custom_fields: %{"diet" => "vegan"}
          },
          actor: ctx.admin
        )

      field!(ctx.admin, "vegan_only", %{
        "by_type" => %{"page" => %{"fields" => %{"diet" => "vegan"}}}
      })

      lv = open_editor(build_conn(), ctx.admin, ctx.post)

      search(lv, "vegan_only", ctx.word)
      assert option_ids(lv, "vegan_only") == [vegan.id]
    end

    test "sort: title lists a blank search by title, not newest first", ctx do
      field!(ctx.admin, "by_title", %{"sort" => "title"}, %{multiple: true})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)

      lv |> element("#custom-field-by_title-search") |> render_focus()
      search(lv, "by_title", "")
      titles = option_titles(lv, "by_title")
      assert titles == Enum.sort(titles)
    end

    test "an empty result under a filter says why; a footer names the conditions", ctx do
      field!(ctx.admin, "strict", %{"states" => ["archived"], "owner" => "self"})
      lv = open_editor(build_conn(), ctx.editor, ctx.post)

      lv |> element("#custom-field-strict-search") |> render_focus()
      html = render(lv)

      assert html =~
               "This field only accepts records that match: State: Archived; Created by you."

      # The empty state already names them, so the footer waits.
      refute has_element?(lv, "#custom-field-strict-filter")

      # With search text the plain message stays, and the footer still shows.
      search(lv, "strict", "zzz")
      refute has_element?(lv, "#custom-field-strict-filter-empty")
      assert has_element?(lv, "#custom-field-strict-filter", "Only offering: State: Archived")
    end

    test "a field without a selection shows no footer", ctx do
      field!(ctx.admin, "plain", nil)
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      lv |> element("#custom-field-plain-search") |> render_focus()
      refute has_element?(lv, "#custom-field-plain-filter")
    end

    test "a deleted tag condition is dropped, not shown", ctx do
      tag = CMS.create_tag!(%{name: "gone#{uniq()}", slug: "gone-#{uniq()}"}, actor: ctx.admin)

      field!(ctx.admin, "tagged", %{
        "states" => ["published"],
        "by_type" => %{"page" => %{"tags_any" => [tag.id]}}
      })

      CMS.destroy_tag!(tag, actor: ctx.admin)
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      search(lv, "tagged", ctx.word)

      assert ctx.published.id in option_ids(lv, "tagged")
      refute render(lv) =~ "Tagged"
    end
  end

  describe "several target types and dynamic types" do
    test "a blank search with sort: title pages exactly across types", ctx do
      field!(ctx.admin, "mixed", %{"states" => ["published"], "sort" => "title"}, %{
        target_type: nil,
        target_types: ["page", "post"],
        multiple: true
      })

      for n <- 1..12 do
        page!("Zed #{ctx.word} p#{String.pad_leading("#{n}", 2, "0")}", ctx.admin, publish: true)

        post =
          CMS.create_post!(
            %{
              title: "Zed #{ctx.word} q#{String.pad_leading("#{n}", 2, "0")}",
              slug: "rps-#{uniq()}"
            },
            actor: ctx.admin
          )

        CMS.publish_post!(post, %{}, actor: ctx.admin)
      end

      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      search(lv, "mixed", "Zed #{ctx.word}")
      assert length(option_ids(lv, "mixed")) == 20

      lv |> element("#custom-field-mixed-more") |> render_click()
      ids = option_ids(lv, "mixed")
      assert length(ids) == 24
      assert ids == Enum.uniq(ids)
    end

    test "a dynamic type is filtered by its own fields", ctx do
      type =
        CMS.create_type_definition!(%{name: "ingr#{uniq()}", label: "Ingredient"},
          actor: ctx.admin
        )

      CMS.create_field_definition!(
        %{
          type_definition_id: type.id,
          name: "diet",
          label: "Diet",
          field_type: :string
        },
        actor: ctx.admin
      )

      make = fn title, diet ->
        entry =
          CMS.create_entry!(
            %{
              title: title,
              slug: "rps-#{uniq()}",
              type_definition_id: type.id,
              custom_fields: %{"diet" => diet}
            },
            actor: ctx.admin
          )

        CMS.publish_entry!(entry, %{}, actor: ctx.admin)
      end

      vegan = make.("#{ctx.word} Basil", "vegan")
      _other = make.("#{ctx.word} Beef", "meat")

      field!(
        ctx.admin,
        "ingredient",
        %{"by_type" => %{type.name => %{"fields" => %{"diet" => "vegan"}}}},
        %{
          target_type: type.name
        }
      )

      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      search(lv, "ingredient", ctx.word)
      assert option_ids(lv, "ingredient") == [vegan.id]
    end
  end

  describe "the dropdown widget" do
    test "offers only matching candidates", ctx do
      field!(ctx.admin, "pick_live", %{"states" => ["published"]}, %{widget: "dropdown"})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)

      html = render(lv)
      assert html =~ ctx.published.title
      refute html =~ ctx.draft.title
    end
  end

  describe "the reverse field" do
    setup ctx do
      field =
        field!(ctx.admin, "rev_#{uniq()}", %{"states" => ["published"]}, %{
          multiple: true,
          inverse_label: "Hosts"
        })

      %{field: field}
    end

    test "a target the field accepts offers the add control", ctx do
      {:ok, lv, _html} =
        build_conn() |> log_in(ctx.admin) |> live(~p"/editor/content/page/#{ctx.published.id}")

      assert has_element?(lv, "[data-reverse-field] [data-reference-picker]")
      refute has_element?(lv, "[id$=-not-accepted]")
    end

    test "a target it would refuse disables the control with a reason, and connect is refused",
         ctx do
      {:ok, lv, _html} =
        build_conn() |> log_in(ctx.admin) |> live(~p"/editor/content/page/#{ctx.draft.id}")

      assert has_element?(lv, "[id$=-not-accepted]")
      refute has_element?(lv, "[data-reverse-field] [data-reference-picker]")

      assert {:error, error} =
               KilnCMS.CMS.ReverseFields.connect(
                 ctx.draft,
                 KilnCMS.CMS.ReverseFields.find(:page, "hosts", ctx.post.org_id),
                 ctx.post,
                 actor: ctx.admin
               )

      assert Exception.message(error) =~ "isn't one of the records this field accepts"
    end

    test "owner: self judges the target's author against the reverse editor", ctx do
      CMS.update_field_definition!(ctx.field, %{selection: %{"owner" => "self"}},
        actor: ctx.admin
      )

      {:ok, lv, _} =
        build_conn() |> log_in(ctx.admin) |> live(~p"/editor/content/page/#{ctx.mine.id}")

      assert has_element?(lv, "[id$=-not-accepted]")

      {:ok, lv, _} =
        build_conn() |> log_in(ctx.editor) |> live(~p"/editor/content/page/#{ctx.mine.id}")

      refute has_element?(lv, "[id$=-not-accepted]")
    end
  end

  describe "create-on-type" do
    defp creating_field!(ctx, name, selection, extra \\ %{}) do
      field!(ctx.admin, name, Map.put(selection, "create", %{"type" => "page"}), extra)
    end

    defp row(lv, field), do: has_element?(lv, "#custom-field-#{field}-create-typed")

    defp pages_titled(title, actor, org) do
      KilnCMS.CMS.ContentTypes.list!("page",
        actor: actor,
        tenant: org,
        query: [filter: [title: title]]
      )
    end

    test "offers the row for a name nothing matches, and creates a connected draft", ctx do
      creating_field!(ctx, "quick", %{"owner" => "self", "states" => ["draft"]}, %{
        multiple: true
      })

      lv = open_editor(build_conn(), ctx.editor, ctx.post)
      refute row(lv, "quick")

      lv |> element("#custom-field-quick-search") |> render_focus()
      refute row(lv, "quick")

      name = "Brand new #{uniq()}"
      search(lv, "quick", name)

      assert has_element?(
               lv,
               "#custom-field-quick-create-typed",
               "Create “#{name}” as a new Page"
             )

      lv |> element("#custom-field-quick-create-typed") |> render_click()

      assert [created] = pages_titled(name, ctx.editor, ctx.post.org_id)
      assert created.state == :draft
      assert created.author_id == ctx.editor.id
      assert has_element?(lv, "#custom-field-quick-items", name)
      refute row(lv, "quick")

      # The draft passes the field's own filter at save: nothing refuses it.
      lv |> form("#post-editor") |> render_submit()
      refute render(lv) =~ "isn't one of the records this field accepts"

      saved = CMS.get_post!(ctx.post.id, actor: ctx.admin, tenant: ctx.post.org_id)
      assert [%{"id" => id}] = saved.custom_fields["quick"]
      assert id == created.id
    end

    test "a second click is a no-op: one click, one draft", ctx do
      creating_field!(ctx, "dbl", %{}, %{multiple: true})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      name = "Twice #{uniq()}"
      search(lv, "dbl", name)

      lv |> element("#custom-field-dbl-create-typed") |> render_click()
      lv |> element("#custom-field-dbl") |> render_hook("ref_create_typed", %{})
      assert length(pages_titled(name, ctx.admin, ctx.post.org_id)) == 1
    end

    test "is hidden for an exact title match, in any case", ctx do
      creating_field!(ctx, "exact", %{})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)

      search(lv, "exact", String.upcase(ctx.published.title))
      refute row(lv, "exact")

      search(lv, "exact", "#{ctx.published.title} and more")
      assert row(lv, "exact")
    end

    test "is not offered by a field without it, and a forged event creates nothing", ctx do
      field!(ctx.admin, "plain_sel", %{"states" => ["draft", "published"]})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      name = "Forged #{uniq()}"
      search(lv, "plain_sel", name)
      refute row(lv, "plain_sel")

      lv |> element("#custom-field-plain_sel") |> render_hook("ref_create_typed", %{})
      assert pages_titled(name, ctx.admin, ctx.post.org_id) == []
    end

    test "is not offered to an editor who may not create the type", ctx do
      creating_field!(ctx, "norights", %{})
      scoped = authed_user(:editor, %{editable_types: ["post"]})
      lv = open_editor(build_conn(), scoped, ctx.post)
      search(lv, "norights", "Anything #{uniq()}")
      refute row(lv, "norights")
    end

    test "a single reference that holds a record offers nothing; the dropdown has no row", ctx do
      creating_field!(ctx, "one", %{})
      creating_field!(ctx, "drop", %{}, %{widget: "dropdown"})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      refute has_element?(lv, "#custom-field-drop-search")

      search(lv, "one", ctx.word)
      lv |> element("#custom-field-one-opt-#{ctx.published.id}") |> render_click()
      refute has_element?(lv, "#custom-field-one-search")
    end

    test "equality conditions are written onto the new record", ctx do
      CMS.create_field_definition!(
        %{content_type: :page, name: "level", label: "Level", field_type: :integer},
        actor: ctx.admin
      )

      creating_field!(ctx, "lvl", %{
        "by_type" => %{"page" => %{"fields" => %{"level" => 3}}}
      })

      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      name = "Leveled #{uniq()}"
      search(lv, "lvl", name)
      lv |> element("#custom-field-lvl-create-typed") |> render_click()

      assert [created] = pages_titled(name, ctx.admin, ctx.post.org_id)
      assert created.custom_fields["level"] == 3
    end

    test "is hidden when the actor may not write a field it would fill", ctx do
      CMS.create_field_definition!(
        %{content_type: :page, name: "grade", label: "Grade", field_type: :integer},
        actor: ctx.admin
      )

      creating_field!(ctx, "grd", %{"by_type" => %{"page" => %{"fields" => %{"grade" => 2}}}})

      restricted =
        authed_user(:editor, %{
          field_grants: %{"page" => ["title", "slug", "custom_fields.other"]}
        })

      lv = open_editor(build_conn(), restricted, ctx.post)
      search(lv, "grd", "Grants #{uniq()}")
      refute row(lv, "grd")
    end

    test "a type with required fields opens the Add new form, title prefilled", ctx do
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "blurb",
          label: "Blurb",
          field_type: :string,
          required: true
        },
        actor: ctx.admin
      )

      creating_field!(ctx, "req", %{})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      name = "Needs blurb #{uniq()}"
      search(lv, "req", name)
      lv |> element("#custom-field-req-create-typed") |> render_click()

      assert has_element?(lv, ~s(#custom-field-req input[value="#{name}"]))
      assert pages_titled(name, ctx.admin, ctx.post.org_id) == []
    end

    test "a refusal on the one-click path stays visible and crashes nothing", ctx do
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "tone",
          label: "Tone",
          field_type: :select,
          options: ["warm", "cool"]
        },
        actor: ctx.admin
      )

      creating_field!(ctx, "bad", %{"by_type" => %{"page" => %{"fields" => %{"tone" => "warm"}}}})

      # The option is removed after the selection was written: the prefill is
      # now a value the target refuses.
      tone = CMS.list_field_definitions!(actor: ctx.admin) |> Enum.find(&(&1.name == "tone"))
      CMS.update_field_definition!(tone, %{options: ["cool"]}, actor: ctx.admin)

      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      name = "Refused #{uniq()}"
      search(lv, "bad", name)
      lv |> element("#custom-field-bad-create-typed") |> render_click()

      assert pages_titled(name, ctx.admin, ctx.post.org_id) == []
      assert has_element?(lv, "#custom-field-bad-new-form")
      assert has_element?(lv, "#custom-field-bad-new-form-errors")
    end

    test "the API never creates: an unknown title is a validation error", ctx do
      %{name: field} = creating_field!(ctx, "api", %{})

      assert {:error, error} =
               CMS.update_post(ctx.post, %{custom_fields: %{field => "No such page"}},
                 actor: ctx.admin
               )

      refute Exception.message(error) == ""
      assert pages_titled("No such page", ctx.admin, ctx.post.org_id) == []
    end
  end
end
