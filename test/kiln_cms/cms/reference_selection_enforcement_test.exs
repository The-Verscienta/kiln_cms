defmodule KilnCMS.CMS.ReferenceSelectionEnforcementTest do
  @moduledoc """
  The save-time half of a reference field's `selection` (#2285): every target
  a write ADDS must be one the field accepts, enforced in
  `Changes.ApplyCustomFields` so every write path gets it. What it does not
  do — re-judge what is already connected, skip the target's own read policy —
  is pinned here as well.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Duplication
  alias KilnCMS.CMS.ReverseFields
  alias KilnCMS.CMS.Translations

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rse-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "rse-#{uniq()}"

  defp page!(actor, title, opts \\ []) do
    page = CMS.create_page!(%{title: title, slug: slug()}, actor: actor)
    if opts[:publish], do: CMS.publish_page!(page, %{}, actor: actor), else: page
  end

  defp field!(admin, attrs) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: "ref_#{uniq()}",
          label: "Linked",
          field_type: :reference,
          target_type: "page",
          selection: %{"states" => ["published"]}
        },
        attrs
      ),
      actor: admin
    )
  end

  defp post(actor, fields),
    do: CMS.create_post(%{title: "Source", slug: slug(), custom_fields: fields}, actor: actor)

  defp post!(actor, fields) do
    {:ok, post} = post(actor, fields)
    post
  end

  defp put_fields(post, fields, actor),
    do: CMS.update_post(post, %{custom_fields: fields}, actor: actor)

  defp select!(admin, field, selection) do
    definition = CMS.list_field_definitions!(actor: admin) |> Enum.find(&(&1.name == field))
    CMS.update_field_definition!(definition, %{selection: selection}, actor: admin)
  end

  defp message({:error, error}), do: Exception.message(error)

  defp ids(post, field),
    do: post.custom_fields |> Map.get(field) |> List.wrap() |> Enum.map(& &1["id"])

  setup do
    admin = user(:admin)
    editor = user(:editor)

    %{
      admin: admin,
      editor: editor,
      other: user(:editor),
      live: page!(admin, "Live", publish: true),
      draft: page!(admin, "Draft draft")
    }
  end

  describe "a single reference" do
    test "a matching target is added, a filtered-out one refused", ctx do
      %{name: field} = field!(ctx.admin, %{})

      assert {:ok, post} = post(ctx.editor, %{field => ctx.live.id})
      assert ids(post, field) == [ctx.live.id]

      message = message(post(ctx.editor, %{field => ctx.draft.id}))
      assert message =~ "“Draft draft” isn't one of the records this field accepts."
      assert message =~ "Linked (#{field})"
    end

    test "a hand-posted id is judged the same, as a bare id or a snapshot", ctx do
      %{name: field} = field!(ctx.admin, %{})
      post = post!(ctx.editor, %{})

      for value <- [
            ctx.draft.id,
            %{"id" => ctx.draft.id, "type" => "page", "title" => "Anything I like"},
            %{"id" => ctx.draft.id}
          ] do
        assert message(put_fields(post, %{field => value}, ctx.editor)) =~
                 "isn't one of the records this field accepts"
      end
    end

    test "an unchanged non-matching target is kept, even after it is retitled", ctx do
      %{name: field} = field!(ctx.admin, %{selection: nil})
      post = post!(ctx.editor, %{field => ctx.draft.id})
      assert ids(post, field) == [ctx.draft.id]

      # The selection arrives after the connection was made.
      select!(ctx.admin, field, %{"states" => ["published"]})

      CMS.update_page!(ctx.draft, %{title: "Renamed"}, actor: ctx.admin)

      # The form resubmits the stored snapshot (old title) or the bare id.
      stored = post.custom_fields[field]

      for value <- [stored, ctx.draft.id, %{"id" => ctx.draft.id, "type" => "page"}] do
        post = CMS.get_post!(post.id, authorize?: false)
        assert {:ok, saved} = put_fields(post, %{field => value}, ctx.editor)
        assert ids(saved, field) == [ctx.draft.id]
      end

      # An unrelated edit of the record never touches the field.
      post = CMS.get_post!(post.id, authorize?: false)
      assert {:ok, _} = CMS.update_post(post, %{title: "Retitled"}, actor: ctx.editor)

      # Swapping to another non-matching target is an add.
      other = page!(ctx.admin, "Other draft")
      post = CMS.get_post!(post.id, authorize?: false)
      assert message(put_fields(post, %{field => other.id}, ctx.editor)) =~ "isn't one of"
    end

    test "removing is never refused", ctx do
      %{name: field} = field!(ctx.admin, %{selection: nil})
      post = post!(ctx.editor, %{field => ctx.draft.id})
      select!(ctx.admin, field, %{"states" => ["archived"]})

      assert {:ok, saved} = put_fields(post, %{field => nil}, ctx.editor)
      assert ids(saved, field) == []
    end

    test "a plain create is checked, every target being new", ctx do
      %{name: field} = field!(ctx.admin, %{})
      assert message(post(ctx.editor, %{field => ctx.draft.id})) =~ "isn't one of"
    end
  end

  describe "a list of references" do
    test "only the added ids are judged; reorder and remove stay allowed", ctx do
      %{name: field} = field!(ctx.admin, %{selection: nil, multiple: true})
      second = page!(ctx.admin, "Second", publish: true)
      post = post!(ctx.editor, %{field => [ctx.draft.id, ctx.live.id]})
      select!(ctx.admin, field, %{"states" => ["published"]})

      # Reordered, with the held draft first and a matching one added.
      assert {:ok, saved} =
               put_fields(post, %{field => [ctx.live.id, ctx.draft.id, second.id]}, ctx.editor)

      assert ids(saved, field) == [ctx.live.id, ctx.draft.id, second.id]

      # Removing the held draft, keeping the rest.
      assert {:ok, saved} = put_fields(saved, %{field => [ctx.live.id, second.id]}, ctx.editor)
      assert ids(saved, field) == [ctx.live.id, second.id]

      # Adding two non-matching ones names them.
      third = page!(ctx.admin, "Third draft")

      message =
        message(
          put_fields(
            saved,
            %{field => [ctx.live.id, second.id, ctx.draft.id, third.id]},
            ctx.editor
          )
        )

      assert message =~
               "“Draft draft”, “Third draft” aren't among the records this field accepts."
    end

    test "one failing item refuses the whole field", ctx do
      %{name: field} = field!(ctx.admin, %{multiple: true})
      assert message(post(ctx.editor, %{field => [ctx.live.id, ctx.draft.id]})) =~ "isn't one of"
    end
  end

  describe "who the filter binds" do
    test "owner self: another author's record is refused, the editor's own accepted", ctx do
      %{name: field} = field!(ctx.admin, %{selection: %{"owner" => "self"}})
      mine = page!(ctx.editor, "Mine")
      theirs = page!(ctx.other, "Theirs")

      assert {:ok, post} = post(ctx.editor, %{field => mine.id})
      assert ids(post, field) == [mine.id]
      assert message(put_fields(post, %{field => theirs.id}, ctx.editor)) =~ "“Theirs” isn't one"

      # The other editor, writing, is judged against *their* records.
      assert {:ok, _} = put_fields(post!(ctx.other, %{}), %{field => theirs.id}, ctx.other)
    end

    test "an admin is bound by the filter too: it is field config, not policy", ctx do
      %{name: field} = field!(ctx.admin, %{})
      assert message(post(ctx.admin, %{field => ctx.draft.id})) =~ "isn't one of"
      assert {:ok, _} = post(ctx.admin, %{field => ctx.live.id})
    end

    test "a system actor skips the filter but the target must still resolve", ctx do
      %{name: field} = field!(ctx.admin, %{})
      system = KilnCMS.CMS.Housekeeping.system(:cms_registry)

      source = post!(ctx.editor, %{})

      # authorize?: false is the same skip; the draft is not "accepted" by the
      # field, and is connected anyway because this caller is not bound.
      assert {:ok, saved} =
               CMS.update_post(source, %{custom_fields: %{field => ctx.draft.id}},
                 authorize?: false,
                 tenant: source.org_id
               )

      assert ids(saved, field) == [ctx.draft.id]

      # …and a target that does not resolve still fails.
      ghost = Ecto.UUID.generate()

      assert message(
               CMS.update_post(source, %{custom_fields: %{field => ghost}},
                 authorize?: false,
                 tenant: source.org_id
               )
             ) =~ "must be an existing page record"

      assert {:ok, :unfiltered} =
               KilnCMS.CMS.ReferenceSelection.query_for(
                 %{"states" => ["published"]},
                 "page",
                 system,
                 nil
               )
    end

    test "a target that matches but cannot be read is refused as it always was", ctx do
      %{name: field} = field!(ctx.admin, %{selection: %{"states" => ["published", "draft"]}})
      trashed = page!(ctx.admin, "Trashed", publish: true)
      CMS.destroy_page!(trashed, actor: ctx.admin)

      assert message(post(ctx.editor, %{field => trashed.id})) =~ "must be an existing page"
    end

    test "a target in another site does not resolve either", ctx do
      %{name: field} = field!(ctx.admin, %{selection: %{"states" => ["published", "draft"]}})
      org = KilnCMS.OrgFixtures.org("rse-other")

      foreign =
        Ash.Seed.seed!(KilnCMS.CMS.Page, %{
          title: "Foreign",
          slug: slug(),
          state: :published,
          org_id: org.id
        })

      # Written under the site's own tenant, as the editor and the API do.
      assert message(
               CMS.create_post(
                 %{title: "Source", slug: slug(), custom_fields: %{field => foreign.id}},
                 actor: ctx.editor,
                 tenant: KilnCMS.Accounts.default_org_id()
               )
             ) =~ "must be an existing page"
    end
  end

  describe "write paths that carry values the source already holds" do
    setup ctx do
      %{name: field} = field!(ctx.admin, %{selection: nil})
      source = post!(ctx.admin, %{field => ctx.draft.id})
      source = CMS.publish_post!(source, %{}, actor: ctx.admin)
      select!(ctx.admin, field, %{"states" => ["published"]})

      Map.merge(ctx, %{field: field, source: source})
    end

    test "duplicate copies a non-matching held target", ctx do
      copy =
        Duplication.duplicate!(:post, ctx.source, actor: ctx.editor, tenant: ctx.source.org_id)

      assert ids(copy, ctx.field) == [ctx.draft.id]
    end

    test "a translation copies it", ctx do
      fr = Translations.create_translation!(:post, ctx.source, "fr", actor: ctx.editor)
      assert ids(fr, ctx.field) == [ctx.draft.id]
    end

    test "restoring a version brings it back", ctx do
      [version | _] =
        KilnCMS.CMS.ContentTypes.list_versions!(:post,
          authorize?: false,
          query: [filter: [version_source_id: ctx.source.id], sort: [version_inserted_at: :asc]]
        )

      changed = CMS.unpublish_post!(ctx.source, %{}, actor: ctx.admin)
      changed = CMS.update_post!(changed, %{custom_fields: %{ctx.field => nil}}, actor: ctx.admin)
      assert ids(changed, ctx.field) == []

      restored = CMS.restore_post_version!(changed, %{version_id: version.id}, actor: ctx.admin)
      assert ids(restored, ctx.field) == [ctx.draft.id]
    end

    test "publish changes does not re-judge a held target", ctx do
      # The working copy leaves the held draft in place and changes a title;
      # promoting it re-runs the registry pass without the filter.
      CMS.create_field_definition!(
        %{content_type: :post, name: "note", label: "Note", field_type: :string},
        actor: ctx.admin
      )

      {:ok, saved} =
        CMS.save_post_working_copy(
          ctx.source,
          %{fields: %{"custom_fields" => %{"note" => "Held note"}}},
          actor: ctx.editor,
          tenant: ctx.source.org_id
        )

      assert {:ok, live} = CMS.publish_post_changes(saved, %{}, actor: ctx.editor)
      assert ids(live, ctx.field) == [ctx.draft.id]
    end

    test "a working copy adds a target once; publishing it later does not re-judge", ctx do
      %{name: field} = field!(ctx.admin, %{selection: %{"states" => ["published"]}})
      source = post!(ctx.admin, %{})
      source = CMS.publish_post!(source, %{}, actor: ctx.admin)
      second = page!(ctx.admin, "Second", publish: true)

      # Not matching: refused when added to the working copy.
      assert {:error, error} =
               CMS.save_post_working_copy(
                 source,
                 %{fields: %{"custom_fields" => %{field => ctx.draft.id}}},
                 actor: ctx.editor,
                 tenant: source.org_id
               )

      assert Exception.message(error) =~ "isn't one of the records this field accepts"

      # Matching: accepted, held.
      assert {:ok, saved} =
               CMS.save_post_working_copy(
                 source,
                 %{fields: %{"custom_fields" => %{field => second.id}}},
                 actor: ctx.editor,
                 tenant: source.org_id
               )

      # The filter changes while the change is held, so the target no longer matches.
      select!(ctx.admin, field, %{"states" => ["archived"]})

      # Publish changes must NOT re-judge it (S4): do not "fix" promotion.
      assert {:ok, live} = CMS.publish_post_changes(saved, %{}, actor: ctx.editor)
      assert ids(live, field) == [second.id]
    end
  end

  describe "a stale selection" do
    test "a read that fails says so, not a crash", ctx do
      %{name: field} = field!(ctx.admin, %{selection: nil})

      CMS.create_field_definition!(
        %{content_type: :page, name: "rank", label: "Rank", field_type: :integer},
        actor: ctx.admin
      )

      definition = CMS.list_field_definitions!(actor: ctx.admin) |> Enum.find(&(&1.name == field))

      # Written around the definition's validation, as a hand-edit or an older
      # release could leave it: a value the field cannot cast.
      Ash.Seed.update!(definition, %{
        selection: %{"by_type" => %{"page" => %{"fields" => %{"rank" => "not a number"}}}}
      })

      assert message(post(ctx.editor, %{field => ctx.live.id})) =~
               "could not be checked against which records it accepts"
    end
  end

  describe "a restricted editor" do
    test "a condition on a field the editor's read grant hides is dropped, not a lockout",
         ctx do
      secret =
        CMS.create_field_definition!(
          %{content_type: :page, name: "secret", label: "Secret", field_type: :string},
          actor: ctx.admin
        )

      %{name: field} =
        field!(ctx.admin, %{
          selection: %{"by_type" => %{"page" => %{"fields" => %{"secret" => "x"}}}}
        })

      # The field turns private around the guard (an older release, a seed).
      Ash.Seed.update!(secret, %{private: true})

      restricted = user(:editor)
      restricted = Ash.Seed.update!(restricted, %{field_read_grants: %{"page" => []}})

      assert {:ok, saved} = post(restricted, %{field => ctx.live.id})
      assert ids(saved, field) == [ctx.live.id]
    end
  end

  describe "a dynamic type" do
    test "tags, category and fields filter an entry type the same way", ctx do
      type =
        CMS.create_type_definition!(
          %{name: "rse#{uniq()}", label: "Product"},
          actor: ctx.admin
        )

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "diet", label: "Diet", field_type: :string},
        actor: ctx.admin
      )

      n = uniq()
      tag = CMS.create_tag!(%{name: "T#{n}", slug: "t-#{n}"}, actor: ctx.admin)
      category = CMS.create_category!(%{name: "C#{n}", slug: "c-#{n}"}, actor: ctx.admin)

      %{name: field} =
        field!(ctx.admin, %{
          target_type: type.name,
          selection: %{
            "by_type" => %{
              type.name => %{
                "tags_any" => [tag.id],
                "category" => category.id,
                "fields" => %{"diet" => "vegan"}
              }
            }
          }
        })

      entry = fn title, attrs ->
        KilnCMS.CMS.ContentTypes.create!(
          type.name,
          Map.merge(%{title: title, slug: slug()}, attrs),
          actor: ctx.admin
        )
      end

      good =
        entry.("Good", %{
          tag_ids: [tag.id],
          category_id: category.id,
          custom_fields: %{"diet" => "vegan"}
        })

      wrong_diet =
        entry.("Wrong diet", %{
          tag_ids: [tag.id],
          category_id: category.id,
          custom_fields: %{"diet" => "meat"}
        })

      untagged =
        entry.("Untagged", %{category_id: category.id, custom_fields: %{"diet" => "vegan"}})

      assert {:ok, saved} = post(ctx.editor, %{field => %{"id" => good.id, "type" => type.name}})
      assert ids(saved, field) == [good.id]

      for bad <- [wrong_diet, untagged] do
        assert message(post(ctx.editor, %{field => %{"id" => bad.id, "type" => type.name}})) =~
                 "isn't one of the records this field accepts"
      end
    end
  end

  describe "the reverse side" do
    test "connect from the target's page is refused when the target fails the filter", ctx do
      %{name: field} = field!(ctx.admin, %{inverse_label: "Used in", multiple: true})
      [reverse] = ReverseFields.for_type(:page, nil)
      source = post!(ctx.editor, %{})

      assert {:error, error} =
               ReverseFields.connect(ctx.draft, reverse, source, actor: ctx.editor)

      assert Exception.message(error) =~ "isn't one of the records this field accepts"
      assert {:ok, _} = ReverseFields.connect(ctx.live, reverse, source, actor: ctx.editor)
      assert ids(CMS.get_post!(source.id, authorize?: false), field) == [ctx.live.id]
    end

    test "owner self judges the reverse editor, not the source's author", ctx do
      %{name: field} =
        field!(ctx.admin, %{
          inverse_label: "Used in",
          multiple: true,
          selection: %{"owner" => "self"}
        })

      [reverse] = ReverseFields.for_type(:page, nil)
      target = page!(ctx.editor, "Editor's page")
      source = post!(ctx.other, %{})

      # `other` wrote the source but did not write the target: refused for them.
      assert {:error, _} = ReverseFields.connect(target, reverse, source, actor: ctx.other)

      # The target's author, editing the same source, may connect it.
      assert {:ok, _} = ReverseFields.connect(target, reverse, source, actor: ctx.editor)
      assert ids(CMS.get_post!(source.id, authorize?: false), field) == [target.id]
    end
  end
end
