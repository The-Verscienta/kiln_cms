defmodule KilnCMSWeb.ReferencePickerFiltersTest do
  @moduledoc """
  The reference picker's filters while picking (#3224): a type select on a
  field with several target types, category and tag selects when the field's
  `selection.filters` turns them on. A choice is AND-ed onto the field's own
  selection and the read still runs as the editor, so a filter only narrows;
  a value the picker didn't offer is no filter, never an error; and a change
  never touches the document.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS

  @password "password123456"

  defp authed_user(role, attrs \\ %{}) do
    email = "ref-flt-#{System.unique_integer([:positive])}@example.com"

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

  defp page!(title, actor, attrs, opts \\ []) do
    page =
      CMS.create_page!(Map.merge(%{title: title, slug: "rpf-#{uniq()}"}, attrs), actor: actor)

    if opts[:publish], do: CMS.publish_page!(page, %{}, actor: actor), else: page
  end

  defp post!(title, actor, attrs \\ %{}) do
    post =
      CMS.create_post!(Map.merge(%{title: title, slug: "rpf-#{uniq()}"}, attrs), actor: actor)

    CMS.publish_post!(post, %{}, actor: actor)
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
          multiple: true,
          selection: selection
        },
        extra
      ),
      actor: admin
    )
  end

  defp several(extra \\ %{}),
    do: Map.merge(%{target_type: nil, target_types: ["page", "post"]}, extra)

  defp open_editor(conn, user, post) do
    {:ok, lv, _html} = conn |> log_in(user) |> live(~p"/editor/content/post/#{post.id}")
    lv
  end

  defp focus(lv, field), do: lv |> element("#custom-field-#{field}-search") |> render_focus()

  defp search(lv, field, query) do
    lv
    |> element("#custom-field-#{field}-search")
    |> render_change(%{"_kiln_ref_q" => %{field => query}})
  end

  defp filter(lv, field, select, value) do
    lv
    |> element("#custom-field-#{field}-filter-#{select}")
    |> render_change(%{"_kiln_ref_f" => %{field => %{select => value}}})
  end

  # A hand-sent event, as a forged client would send it.
  defp forge(lv, field, params),
    do: lv |> element("#custom-field-#{field}") |> render_hook("ref_filter", params)

  defp option_ids(lv, field) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#custom-field-#{field}-listbox [role=option][phx-value-id]")
    |> LazyHTML.attribute("phx-value-id")
  end

  defp select_options(lv, field, select) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#custom-field-#{field}-filter-#{select} option")
    |> LazyHTML.attribute("value")
  end

  setup do
    admin = authed_user(:admin)
    word = "Medlar#{uniq()}"

    soups = CMS.create_category!(%{name: "Soups #{uniq()}", slug: "rpf-#{uniq()}"}, actor: admin)

    salads =
      CMS.create_category!(%{name: "Salads #{uniq()}", slug: "rpf-#{uniq()}"}, actor: admin)

    group =
      CMS.create_tag_group!(%{name: "Diet #{uniq()}", slug: "rpf-#{uniq()}"}, actor: admin)

    vegan =
      CMS.create_tag!(
        %{name: "vegan #{uniq()}", slug: "rpf-#{uniq()}", tag_group_id: group.id},
        actor: admin
      )

    quick = CMS.create_tag!(%{name: "quick #{uniq()}", slug: "rpf-#{uniq()}"}, actor: admin)
    idle = CMS.create_tag!(%{name: "idle #{uniq()}", slug: "rpf-#{uniq()}"}, actor: admin)

    soup =
      page!("#{word} Soup", admin, %{category_id: soups.id, tag_ids: [vegan.id]}, publish: true)

    salad =
      page!("#{word} Salad", admin, %{category_id: salads.id, tag_ids: [quick.id]}, publish: true)

    draft = page!("#{word} Draft soup", admin, %{category_id: soups.id, tag_ids: [vegan.id]})

    %{
      admin: admin,
      word: word,
      soups: soups,
      salads: salads,
      group: group,
      vegan: vegan,
      quick: quick,
      idle: idle,
      soup: soup,
      salad: salad,
      draft: draft,
      post: CMS.create_post!(%{title: "Host", slug: "rpf-#{uniq()}"}, actor: admin)
    }
  end

  describe "the type filter" do
    test "a field with several types offers it; a type narrows and keeps type:id tokens", ctx do
      story = post!("#{ctx.word} Story", ctx.admin)
      field!(ctx.admin, "mixed", nil, several())
      lv = open_editor(build_conn(), ctx.admin, ctx.post)

      # It needs no read, so it shows before the list is ever opened.
      assert has_element?(lv, "#custom-field-mixed-filter-type option[value='']", "All types")
      assert select_options(lv, "mixed", "type") == ["", "page", "post"]

      search(lv, "mixed", ctx.word)
      assert "post:#{story.id}" in option_ids(lv, "mixed")
      assert "page:#{ctx.soup.id}" in option_ids(lv, "mixed")

      filter(lv, "mixed", "type", "page")
      ids = option_ids(lv, "mixed")
      assert "page:#{ctx.soup.id}" in ids
      assert Enum.all?(ids, &String.starts_with?(&1, "page:"))

      # A pick from the one-type path still carries its type.
      lv |> element("#custom-field-mixed-opt-page-#{ctx.soup.id}") |> render_click()

      assert has_element?(
               lv,
               ~s(#custom-field-mixed-items input[value="page:#{ctx.soup.id}"])
             )

      filter(lv, "mixed", "type", "")
      assert "post:#{story.id}" in option_ids(lv, "mixed")
    end

    test "a field of one type has no type select, and no filter row without filters", ctx do
      field!(ctx.admin, "single", nil)
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      focus(lv, "single")

      refute has_element?(lv, "#custom-field-single-filter-type")
      refute has_element?(lv, "#custom-field-single-filters")
    end

    test "a forged type outside the field's targets is no filter", ctx do
      story = post!("#{ctx.word} Tale", ctx.admin)
      field!(ctx.admin, "forged_type", nil, several())
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      search(lv, "forged_type", ctx.word)

      forge(lv, "forged_type", %{"_kiln_ref_f" => %{"forged_type" => %{"type" => "media"}}})
      ids = option_ids(lv, "forged_type")
      assert "post:#{story.id}" in ids
      assert "page:#{ctx.soup.id}" in ids
    end
  end

  describe "category and tag filters" do
    test "are read on the first open, then narrow the results", ctx do
      field!(ctx.admin, "cooked", %{"filters" => ["category", "tag"]})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)

      refute has_element?(lv, "#custom-field-cooked-filter-category")
      search(lv, "cooked", ctx.word)

      assert ctx.soups.id in select_options(lv, "cooked", "category")

      assert has_element?(
               lv,
               "#custom-field-cooked-filter-category option[value='']",
               "Any category"
             )

      # Tags are grouped by their tag group, the ungrouped last.
      assert has_element?(
               lv,
               ~s(#custom-field-cooked-filter-tag optgroup[label="#{ctx.group.name}"] option[value="#{ctx.vegan.id}"])
             )

      assert has_element?(
               lv,
               ~s(#custom-field-cooked-filter-tag optgroup[label="Ungrouped"] option[value="#{ctx.quick.id}"])
             )

      filter(lv, "cooked", "category", ctx.soups.id)
      ids = option_ids(lv, "cooked")
      assert ctx.soup.id in ids
      assert ctx.draft.id in ids
      refute ctx.salad.id in ids

      filter(lv, "cooked", "tag", ctx.quick.id)
      assert option_ids(lv, "cooked") == []

      filter(lv, "cooked", "category", "")
      assert option_ids(lv, "cooked") == [ctx.salad.id]
    end

    test "each select carries its own phx-change, targeted at the picker", ctx do
      field!(ctx.admin, "wired", %{"filters" => ["category", "tag"]}, several())
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      focus(lv, "wired")

      for select <- ~w(type category tag) do
        [node] =
          lv
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("#custom-field-wired-filter-#{select}")
          |> Enum.to_list()

        assert LazyHTML.attribute(node, "phx-change") == ["ref_filter"]
        assert [target] = LazyHTML.attribute(node, "phx-target")
        assert target != ""
        assert LazyHTML.attribute(node, "name") == ["_kiln_ref_f[wired][#{select}]"]
      end
    end

    test "are not shown when the field doesn't turn them on", ctx do
      field!(ctx.admin, "plain", %{"states" => ["published"]})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      search(lv, "plain", ctx.word)

      refute has_element?(lv, "#custom-field-plain-filter-category")
      refute has_element?(lv, "#custom-field-plain-filter-tag")

      # Nor does a hand-sent category narrow anything.
      forge(lv, "plain", %{"_kiln_ref_f" => %{"plain" => %{"category" => ctx.salads.id}}})
      assert ctx.soup.id in option_ids(lv, "plain")
    end

    test "a category every target pins leaves the category select out", ctx do
      field!(ctx.admin, "pinned", %{
        "filters" => ["category", "tag"],
        "by_type" => %{"page" => %{"category" => ctx.soups.id}}
      })

      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      focus(lv, "pinned")

      refute has_element?(lv, "#custom-field-pinned-filter-category")
      assert has_element?(lv, "#custom-field-pinned-filter-tag")
    end

    test "tags every target names are the only tag options", ctx do
      field!(ctx.admin, "vegan_only", %{
        "filters" => ["tag"],
        "by_type" => %{"page" => %{"tags_any" => [ctx.vegan.id]}}
      })

      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      focus(lv, "vegan_only")

      assert select_options(lv, "vegan_only", "tag") == ["", ctx.vegan.id]
    end

    test "a forged id — random, or another org's category — is no filter, never an error", ctx do
      other_org =
        KilnCMS.Accounts.create_organization!(
          %{name: "Other", slug: "rpf-other-#{uniq()}"},
          authorize?: false
        )

      foreign =
        CMS.create_category!(%{name: "Theirs", slug: "rpf-#{uniq()}"},
          authorize?: false,
          tenant: other_org.id
        )

      field!(ctx.admin, "forged", %{"filters" => ["category", "tag"]})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      search(lv, "forged", ctx.word)

      for params <- [
            %{"category" => foreign.id},
            %{"category" => Ecto.UUID.generate()},
            %{"tag" => "not-a-uuid"},
            %{"category" => ["a", "list"]}
          ] do
        forge(lv, "forged", %{"_kiln_ref_f" => %{"forged" => params}})
        ids = option_ids(lv, "forged")
        assert ctx.soup.id in ids
        assert ctx.salad.id in ids
        refute has_element?(lv, "#custom-field-forged-filters-empty")
      end

      # A payload without this picker's key, or none at all, changes nothing.
      filter(lv, "forged", "category", ctx.soups.id)
      forge(lv, "forged", %{"_kiln_ref_f" => %{"other" => %{"category" => ctx.salads.id}}})
      forge(lv, "forged", %{})
      refute ctx.salad.id in option_ids(lv, "forged")
    end
  end

  describe "a filter only narrows" do
    test "it can't reach past the field's selection", ctx do
      field!(ctx.admin, "live_only", %{"states" => ["published"], "filters" => ["category"]})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      search(lv, "live_only", ctx.word)

      filter(lv, "live_only", "category", ctx.soups.id)
      assert option_ids(lv, "live_only") == [ctx.soup.id]

      field!(ctx.admin, "vegan_cat", %{
        "filters" => ["category"],
        "by_type" => %{"page" => %{"tags_any" => [ctx.vegan.id]}}
      })

      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      search(lv, "vegan_cat", ctx.word)
      filter(lv, "vegan_cat", "category", ctx.salads.id)
      assert option_ids(lv, "vegan_cat") == []
    end

    test "it can't reach past what the editor may read", ctx do
      field!(ctx.admin, "scoped", %{"filters" => ["category"]})
      # Pages outside this editor's read scope read as the public's: published only.
      restricted = authed_user(:editor, %{readable_types: ["post"]})
      lv = open_editor(build_conn(), restricted, ctx.post)
      search(lv, "scoped", ctx.word)

      filter(lv, "scoped", "category", ctx.soups.id)
      assert option_ids(lv, "scoped") == [ctx.soup.id]
      refute ctx.draft.id in option_ids(lv, "scoped")
    end
  end

  describe "the empty state" do
    test "says the filters found nothing, ahead of the selection's own text; Clear restores",
         ctx do
      field!(ctx.admin, "empty", %{"states" => ["published"], "filters" => ["tag"]})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      focus(lv, "empty")

      # A blank search, where without a filter the selection's text explains.
      filter(lv, "empty", "tag", ctx.idle.id)

      assert has_element?(
               lv,
               "#custom-field-empty-filters-empty",
               "No matches with these filters."
             )

      refute has_element?(lv, "#custom-field-empty-filter-empty")
      # The selection still shows, in the footer.
      assert has_element?(lv, "#custom-field-empty-filter", "Only offering: State: Published")

      # With search text too.
      search(lv, "empty", "#{ctx.word} Soup")
      filter(lv, "empty", "tag", ctx.quick.id)
      assert has_element?(lv, "#custom-field-empty-filters-empty")

      lv |> element("#custom-field-empty-filters-clear") |> render_click()
      refute has_element?(lv, "#custom-field-empty-filters-empty")
      assert option_ids(lv, "empty") == [ctx.soup.id]
      refute has_element?(lv, "#custom-field-empty-filter-tag option[selected]")
    end
  end

  describe "paging" do
    test "pages exactly across types under a filter; a change starts over", ctx do
      field!(ctx.admin, "lots", %{"filters" => ["category"], "sort" => "title"}, several())

      outside =
        for n <- 1..12 do
          suffix = String.pad_leading("#{n}", 2, "0")
          page!("#{ctx.word} Zp#{suffix}", ctx.admin, %{category_id: ctx.soups.id}, publish: true)
          post!("#{ctx.word} Zq#{suffix}", ctx.admin, %{category_id: ctx.soups.id})
          # Outside the category: never listed once it is chosen.
          "post:" <> post!("#{ctx.word} Zr#{suffix}", ctx.admin, %{category_id: ctx.salads.id}).id
        end

      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      search(lv, "lots", "#{ctx.word} Z")
      lv |> element("#custom-field-lots-more") |> render_click()
      assert length(option_ids(lv, "lots")) == 36

      # The filter starts over at page one.
      filter(lv, "lots", "category", ctx.soups.id)
      first = option_ids(lv, "lots")
      assert length(first) == 20
      assert has_element?(lv, "#custom-field-lots-more")

      lv |> element("#custom-field-lots-more") |> render_click()
      ids = option_ids(lv, "lots")
      assert length(ids) == 24
      assert ids == Enum.uniq(ids)
      assert Enum.take(ids, 20) == first
      refute has_element?(lv, "#custom-field-lots-more")
      assert MapSet.disjoint?(MapSet.new(ids), MapSet.new(outside))

      # So does a type: 12 pages, one page, nothing more.
      filter(lv, "lots", "type", "page")
      assert length(option_ids(lv, "lots")) == 12
      refute has_element?(lv, "#custom-field-lots-more")
    end
  end

  describe "the document" do
    test "a filter change neither dirties the form nor changes the value", ctx do
      field!(ctx.admin, "quiet", %{"filters" => ["category"]})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      search(lv, "quiet", ctx.word)

      assert has_element?(lv, ~s{form#post-editor[data-dirty="false"]})
      filter(lv, "quiet", "category", ctx.soups.id)
      assert has_element?(lv, ~s{form#post-editor[data-dirty="false"]})
      refute has_element?(lv, "#custom-field-quiet-items")
    end

    test "create-on-type is hidden while a filter is set", ctx do
      field!(ctx.admin, "maker", %{"filters" => ["category"], "create" => %{"type" => "page"}})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      name = "Brand new #{uniq()}"
      search(lv, "maker", name)
      assert has_element?(lv, "#custom-field-maker-create-typed")

      filter(lv, "maker", "category", ctx.soups.id)
      refute has_element?(lv, "#custom-field-maker-create-typed")

      # A hand-sent create while filtered makes nothing.
      lv |> element("#custom-field-maker") |> render_hook("ref_create_typed", %{})

      assert KilnCMS.CMS.ContentTypes.list!("page",
               actor: ctx.admin,
               tenant: ctx.post.org_id,
               query: [filter: [title: name]]
             ) == []

      filter(lv, "maker", "category", "")
      assert has_element?(lv, "#custom-field-maker-create-typed")
    end

    test "a single reference that holds a record ignores a filter", ctx do
      field!(ctx.admin, "one", %{"filters" => ["category"]}, %{multiple: false})
      lv = open_editor(build_conn(), ctx.admin, ctx.post)
      search(lv, "one", ctx.word)
      lv |> element("#custom-field-one-opt-#{ctx.soup.id}") |> render_click()
      refute has_element?(lv, "#custom-field-one-search")

      forge(lv, "one", %{"_kiln_ref_f" => %{"one" => %{"category" => ctx.soups.id}}})
      refute has_element?(lv, "#custom-field-one-listbox")
      refute has_element?(lv, "#custom-field-one-filters")
    end

    test "a locked field ignores a filter", ctx do
      CMS.create_field_definition!(
        %{
          content_type: :page,
          name: "locked_ref",
          label: "Locked",
          field_type: :reference,
          target_type: "page",
          multiple: true,
          localization: :shared,
          selection: %{"filters" => ["category"]}
        },
        actor: ctx.admin
      )

      en = page!("#{ctx.word} Source", ctx.admin, %{locale: "en"}, publish: true)
      fr = KilnCMS.CMS.Translations.create_translation!(:page, en, "fr", actor: ctx.admin)

      {:ok, lv, _html} =
        build_conn() |> log_in(ctx.admin) |> live(~p"/editor/content/page/#{fr.id}")

      refute has_element?(lv, "#custom-field-locked_ref-search")

      lv
      |> element("#custom-field-locked_ref")
      |> render_hook("ref_filter", %{
        "_kiln_ref_f" => %{"locked_ref" => %{"category" => ctx.soups.id}}
      })

      refute has_element?(lv, "#custom-field-locked_ref-listbox")
      refute has_element?(lv, "#custom-field-locked_ref-filters")
    end
  end
end
