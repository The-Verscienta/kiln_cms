defmodule KilnCMS.CMS.FieldSyncWorkingCopyTest do
  @moduledoc """
  Renaming, deleting or reshaping a custom field rewrites the values a live
  record's pending working copy holds, not just the live ones (#2744).

  Before, `Changes.SyncFieldValues` rewrote `custom_fields` alone. The held
  map (`working_fields -> 'custom_fields'`) kept the old key and its base
  (`working_base`) the fingerprint of the old live map, so "Publish changes"
  reported a conflict nobody made, a release blocked on it, unpublishing kept
  the live map and dropped the draft's edits, and a rename lost the draft's
  value outright (the old key is undeclared, and promotion drops it).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Releases
  alias KilnCMS.CMS.WorkingCopy

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "fswc-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "fswc-#{System.unique_integer([:positive])}"

  defp field!(admin, attrs),
    do:
      CMS.create_field_definition!(
        Map.merge(%{content_type: :post, label: "Field", field_type: :string}, attrs),
        actor: admin
      )

  defp reload(post), do: CMS.get_post!(post.id, authorize?: false, tenant: post.org_id)

  defp live_post(admin, fields) do
    post =
      CMS.create_post!(%{title: "Live", slug: slug(), custom_fields: fields}, actor: admin)

    CMS.publish_post!(post, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    reload(post)
  end

  defp draft!(post, fields, admin) do
    {:ok, saved} =
      CMS.save_post_working_copy(post, %{fields: %{"custom_fields" => fields}},
        actor: admin,
        tenant: post.org_id
      )

    assert WorkingCopy.pending?(saved)
    saved
  end

  defp held(record), do: record.working_fields["custom_fields"]

  defp rename!(definition, to, admin),
    do: CMS.update_field_definition!(definition, %{name: to}, actor: admin)

  defp publish_changes(record, admin, args \\ %{}),
    do: CMS.publish_post_changes(reload(record), args, actor: admin)

  defp fp(map), do: WorkingCopy.fingerprint(KilnCMS.CMS.Post, "custom_fields", map)

  defp raw(table, id, column) do
    %{rows: [[value]]} =
      KilnCMS.Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [Ecto.UUID.dump!(id)])

    value
  end

  setup do
    admin = user(:admin)
    subtitle = field!(admin, %{name: "subtitle_#{System.unique_integer([:positive])}"})
    summary = field!(admin, %{name: "summary_#{System.unique_integer([:positive])}"})
    %{admin: admin, subtitle: subtitle, summary: summary}
  end

  describe "a top-level rename" do
    setup %{admin: admin, subtitle: subtitle, summary: summary} do
      post = live_post(admin, %{subtitle.name => "Live sub", summary.name => "Live sum"})
      saved = draft!(post, %{subtitle.name => "Held sub", summary.name => "Held sum"}, admin)
      to = "tagline_#{System.unique_integer([:positive])}"
      %{post: post, saved: saved, to: to}
    end

    # T1
    test "publishes the draft's value under the new key, with no conflict", ctx do
      rename!(ctx.subtitle, ctx.to, ctx.admin)
      renamed = reload(ctx.post)

      assert WorkingCopy.reconcile(renamed).conflicts == []
      assert {:ok, published} = publish_changes(renamed, ctx.admin)
      assert published.custom_fields[ctx.to] == "Held sub"
      assert published.custom_fields[ctx.summary.name] == "Held sum"
      refute Map.has_key?(published.custom_fields, ctx.subtitle.name)
    end

    # T2
    test "the copy holds the new key and is re-based on the renamed live map", ctx do
      rename!(ctx.subtitle, ctx.to, ctx.admin)
      renamed = reload(ctx.post)

      view = WorkingCopy.view(renamed)
      assert view.custom_fields[ctx.to] == "Held sub"
      assert view.custom_fields[ctx.summary.name] == "Held sum"
      refute Map.has_key?(held(renamed), ctx.subtitle.name)
      assert renamed.custom_fields[ctx.to] == "Live sub"
      assert renamed.working_base["custom_fields"] == fp(renamed.custom_fields)
    end

    # T3
    test "a real conflict stays one, and both answers keep the renamed value", ctx do
      live =
        CMS.update_post!(reload(ctx.post), %{custom_fields: %{ctx.summary.name => "API"}},
          actor: ctx.admin
        )

      assert WorkingCopy.reconcile(live).conflicts == ["custom_fields"]

      rename!(ctx.subtitle, ctx.to, ctx.admin)
      renamed = reload(ctx.post)
      assert WorkingCopy.reconcile(renamed).conflicts == ["custom_fields"]
      assert {:error, _conflict} = publish_changes(renamed, ctx.admin)

      assert {:ok, mine} =
               publish_changes(renamed, ctx.admin, %{resolve: %{"custom_fields" => "mine"}})

      assert mine.custom_fields[ctx.to] == "Held sub"
    end

    test "answering theirs keeps the live value under the new key", ctx do
      CMS.update_post!(reload(ctx.post), %{custom_fields: %{ctx.summary.name => "API"}},
        actor: ctx.admin
      )

      rename!(ctx.subtitle, ctx.to, ctx.admin)

      assert {:ok, theirs} =
               publish_changes(reload(ctx.post), ctx.admin, %{
                 resolve: %{"custom_fields" => "theirs"}
               })

      assert theirs.custom_fields[ctx.to] == "Live sub"
      assert theirs.custom_fields[ctx.summary.name] == "API"
    end

    # T21
    test "bumps lock_version only, leaving history and updated_at alone", ctx do
      before = reload(ctx.post)
      versions = length(CMS.list_post_versions!(authorize?: false, tenant: before.org_id))

      rename!(ctx.subtitle, ctx.to, ctx.admin)
      renamed = reload(ctx.post)

      assert renamed.lock_version == before.lock_version + 1
      assert renamed.updated_at == before.updated_at
      assert length(CMS.list_post_versions!(authorize?: false, tenant: before.org_id)) == versions
    end

    # T19
    test "a struct read before the rename cannot save or publish over it", ctx do
      stale = reload(ctx.post)
      rename!(ctx.subtitle, ctx.to, ctx.admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               CMS.save_post_working_copy(
                 stale,
                 %{fields: %{"seo_title" => "Stale"}},
                 actor: ctx.admin,
                 tenant: stale.org_id
               )

      assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               CMS.publish_post_changes(stale, %{}, actor: ctx.admin)

      assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
      assert held(reload(ctx.post))[ctx.to] == "Held sub"
    end

    # T15
    test "a release item for the drafted record applies and publishes the new key", ctx do
      rename!(ctx.subtitle, ctx.to, ctx.admin)
      release = CMS.create_release!(%{name: "Launch #{slug()}"}, actor: ctx.admin)

      {:ok, item} =
        CMS.add_release_item(
          %{release_id: release.id, content_type: "post", content_id: ctx.post.id},
          actor: ctx.admin
        )

      assert Releases.classify(item, authorize?: false, tenant: ctx.post.org_id) == :apply
      {:ok, _claimed} = CMS.start_release(release, %{}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()

      assert reload(ctx.post).custom_fields[ctx.to] == "Held sub"
    end

    # T16
    test "unpublishing folds the draft's value in under the new key", ctx do
      rename!(ctx.subtitle, ctx.to, ctx.admin)
      {:ok, _} = CMS.unpublish_post(reload(ctx.post), %{}, actor: ctx.admin)

      draft = reload(ctx.post)
      assert draft.state == :draft
      assert draft.custom_fields[ctx.to] == "Held sub"
      assert draft.custom_fields[ctx.summary.name] == "Held sum"
    end

    # T18
    # Characterization, not the fix: versions are hash-chained (#671) and are
    # not rewritten, so a copy restored from before the rename names the old,
    # now undeclared key, and publishing it drops that value. A rename ledger
    # is the follow-up.
    test "restoring a copy saved before the rename loses the old key (unchanged)", ctx do
      version =
        CMS.list_post_versions!(authorize?: false, tenant: ctx.post.org_id)
        |> Enum.filter(
          &(&1.version_source_id == ctx.post.id and
              &1.version_action_name == :save_working_copy)
        )
        |> Enum.max_by(& &1.version_inserted_at, DateTime)

      rename!(ctx.subtitle, ctx.to, ctx.admin)

      assert {:ok, restored} =
               CMS.restore_post_version(reload(ctx.post), %{version_id: version.id},
                 actor: ctx.admin
               )

      assert held(restored)[ctx.subtitle.name] == "Held sub"
      refute Map.has_key?(held(restored), ctx.to)

      assert {:ok, published} =
               publish_changes(restored, ctx.admin, %{resolve: %{"*" => "mine"}})

      refute Map.has_key?(published.custom_fields, ctx.subtitle.name)
      assert published.custom_fields[ctx.summary.name] == "Held sum"
    end

    # T20
    test "an editor cannot rename the field, and nothing moves", ctx do
      editor = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_field_definition(ctx.subtitle, %{name: ctx.to}, actor: editor)

      untouched = reload(ctx.post)
      assert held(untouched)[ctx.subtitle.name] == "Held sub"
      assert untouched.lock_version == reload(ctx.saved).lock_version
    end

    # T22
    test "a purge inside a transaction that rolls back changes nothing", ctx do
      before = reload(ctx.post)

      assert {:error, :undo} =
               KilnCMS.Repo.transaction(fn ->
                 :ok =
                   CMS.destroy_field_definition!(ctx.subtitle,
                     actor: ctx.admin,
                     context: %{warn_on_transaction_hooks?: false}
                   )

                 assert held(reload(ctx.post))[ctx.subtitle.name] == nil
                 KilnCMS.Repo.rollback(:undo)
               end)

      after_rollback = reload(ctx.post)
      assert after_rollback.custom_fields == before.custom_fields
      assert after_rollback.working_fields == before.working_fields
      assert after_rollback.working_base == before.working_base
    end
  end

  # T4
  test "a key only the draft holds is renamed too", ctx do
    post = live_post(ctx.admin, %{ctx.summary.name => "Live sum"})
    draft!(post, %{ctx.subtitle.name => "Draft only"}, ctx.admin)
    to = "tagline_#{System.unique_integer([:positive])}"

    rename!(ctx.subtitle, to, ctx.admin)

    assert {:ok, published} = publish_changes(post, ctx.admin)
    assert published.custom_fields[to] == "Draft only"
  end

  describe "a top-level purge" do
    # T5
    test "removes the key from the copy and keeps its other edits", ctx do
      post = live_post(ctx.admin, %{ctx.subtitle.name => "Live sub", ctx.summary.name => "Sum"})
      draft!(post, %{ctx.subtitle.name => "Held sub", ctx.summary.name => "Held sum"}, ctx.admin)

      :ok = CMS.destroy_field_definition!(ctx.subtitle, actor: ctx.admin)
      purged = reload(post)

      refute Map.has_key?(held(purged), ctx.subtitle.name)
      assert WorkingCopy.reconcile(purged).conflicts == []
      assert {:ok, published} = publish_changes(purged, ctx.admin)
      assert published.custom_fields[ctx.summary.name] == "Held sum"
    end

    # T6 and the emptied copy (critic 7)
    test "a copy that differed only in the purged key stops holding custom_fields", ctx do
      post = live_post(ctx.admin, %{ctx.subtitle.name => "Live sub", ctx.summary.name => "Sum"})
      draft!(post, %{ctx.subtitle.name => "Held sub"}, ctx.admin)

      :ok = CMS.destroy_field_definition!(ctx.subtitle, actor: ctx.admin)
      purged = reload(post)

      refute Map.has_key?(purged.working_fields, "custom_fields")
      refute Map.has_key?(purged.working_base, "custom_fields")
      # Deliberate: the stamp stays, so the record still reads as pending
      # until it is published or discarded (an empty copy is harmless).
      assert %DateTime{} = purged.working_copy_at
      assert WorkingCopy.pending?(purged)
    end
  end

  # T7
  describe "a group sub-field" do
    setup %{admin: admin} do
      group =
        field!(admin, %{
          name: "dose_#{System.unique_integer([:positive])}",
          field_type: :group,
          multiple: true
        })

      amount = field!(admin, %{content_type: nil, group_of_id: group.id, name: "amount"})
      unit = field!(admin, %{content_type: nil, group_of_id: group.id, name: "unit"})
      %{group: group, amount: amount, unit: unit}
    end

    test "rename moves the key in every held row", ctx do
      post =
        live_post(ctx.admin, %{ctx.group.name => [%{"amount" => "1", "unit" => "g"}]})

      draft!(
        post,
        %{ctx.group.name => [%{"amount" => "2", "unit" => "g"}, %{"amount" => "3"}]},
        ctx.admin
      )

      CMS.update_field_definition!(ctx.amount, %{name: "qty"}, actor: ctx.admin)
      renamed = reload(post)

      assert held(renamed)[ctx.group.name] == [
               %{"qty" => "2", "unit" => "g"},
               %{"qty" => "3"}
             ]

      assert WorkingCopy.reconcile(renamed).conflicts == []
      assert {:ok, published} = publish_changes(renamed, ctx.admin)

      assert published.custom_fields[ctx.group.name] == [
               %{"qty" => "2", "unit" => "g"},
               %{"qty" => "3"}
             ]
    end

    # T8
    test "purge drops a held row it empties", ctx do
      post =
        live_post(ctx.admin, %{ctx.group.name => [%{"amount" => "1", "unit" => "kg"}]})

      draft!(
        post,
        %{ctx.group.name => [%{"amount" => "2", "unit" => "g"}, %{"amount" => "3"}]},
        ctx.admin
      )

      :ok = CMS.destroy_field_definition!(ctx.amount, actor: ctx.admin)
      purged = reload(post)

      assert held(purged)[ctx.group.name] == [%{"unit" => "g"}]
      assert WorkingCopy.reconcile(purged).conflicts == []
    end
  end

  # T7 (single group)
  test "a single group's sub-field rename reaches the held object", ctx do
    group =
      field!(ctx.admin, %{name: "box_#{System.unique_integer([:positive])}", field_type: :group})

    width = field!(ctx.admin, %{content_type: nil, group_of_id: group.id, name: "width"})
    post = live_post(ctx.admin, %{group.name => %{"width" => "1"}})
    draft!(post, %{group.name => %{"width" => "2"}}, ctx.admin)

    CMS.update_field_definition!(width, %{name: "span"}, actor: ctx.admin)
    renamed = reload(post)

    assert held(renamed)[group.name] == %{"span" => "2"}
    assert WorkingCopy.reconcile(renamed).conflicts == []
  end

  # T10
  describe "a link field" do
    setup %{admin: admin} do
      target = CMS.create_page!(%{title: "Flour", slug: slug()}, actor: admin)
      CMS.publish_page!(target, %{}, actor: admin)

      reference =
        field!(admin, %{
          name: "ingredients_#{System.unique_integer([:positive])}",
          field_type: :reference,
          target_type: "page",
          multiple: true
        })

      quantity = field!(admin, %{content_type: nil, link_of_id: reference.id, name: "quantity"})
      %{target: target, reference: reference, quantity: quantity}
    end

    test "rename moves the key inside each held connection's link", ctx do
      post =
        live_post(ctx.admin, %{
          ctx.reference.name => [%{"id" => ctx.target.id, "link" => %{"quantity" => "1"}}]
        })

      draft!(
        post,
        %{ctx.reference.name => [%{"id" => ctx.target.id, "link" => %{"quantity" => "500"}}]},
        ctx.admin
      )

      CMS.update_field_definition!(ctx.quantity, %{name: "amount"}, actor: ctx.admin)
      renamed = reload(post)

      assert [%{"link" => %{"amount" => "500"} = link}] = held(renamed)[ctx.reference.name]
      refute Map.has_key?(link, "quantity")
      assert WorkingCopy.reconcile(renamed).conflicts == []
    end

    test "purge removes the key from each held connection", ctx do
      post =
        live_post(ctx.admin, %{
          ctx.reference.name => [%{"id" => ctx.target.id, "link" => %{"quantity" => "1"}}]
        })

      draft!(
        post,
        %{ctx.reference.name => [%{"id" => ctx.target.id, "link" => %{"quantity" => "500"}}]},
        ctx.admin
      )

      :ok = CMS.destroy_field_definition!(ctx.quantity, actor: ctx.admin)
      purged = reload(post)

      # The two copies now agree, so the draft stops holding the field.
      refute Map.has_key?(purged.working_fields, "custom_fields")
      assert [connection] = WorkingCopy.view(purged).custom_fields[ctx.reference.name]
      refute Map.has_key?(connection, "link")
      assert WorkingCopy.reconcile(purged).conflicts == []
    end
  end

  # T11
  describe "a multiple flip" do
    setup %{admin: admin} do
      terms =
        field!(admin, %{
          name: "tone_#{System.unique_integer([:positive])}",
          field_type: :select,
          options: ["dark", "light", "warm"]
        })

      %{terms: terms}
    end

    test "to a list wraps the held value as it does the live one", ctx do
      post = live_post(ctx.admin, %{ctx.terms.name => "dark"})
      draft!(post, %{ctx.terms.name => "light"}, ctx.admin)

      CMS.update_field_definition!(ctx.terms, %{multiple: true}, actor: ctx.admin)
      reshaped = reload(post)

      assert reshaped.custom_fields[ctx.terms.name] == ["dark"]
      assert held(reshaped)[ctx.terms.name] == ["light"]
      assert WorkingCopy.reconcile(reshaped).conflicts == []
    end

    test "to a single value keeps the held list's first item", ctx do
      CMS.update_field_definition!(ctx.terms, %{multiple: true}, actor: ctx.admin)
      post = live_post(ctx.admin, %{ctx.terms.name => ["dark"]})
      draft!(post, %{ctx.terms.name => ["warm", "light"]}, ctx.admin)

      CMS.update_field_definition!(reload_def(ctx.terms), %{multiple: false}, actor: ctx.admin)
      reshaped = reload(post)

      assert reshaped.custom_fields[ctx.terms.name] == "dark"
      assert held(reshaped)[ctx.terms.name] == "warm"
      assert WorkingCopy.reconcile(reshaped).conflicts == []
    end

    # Critic 7: the base chains through both ops of one update.
    test "a rename and a flip in one update chain the base through both", ctx do
      post = live_post(ctx.admin, %{ctx.terms.name => "dark"})
      draft!(post, %{ctx.terms.name => "light"}, ctx.admin)
      to = "mood_#{System.unique_integer([:positive])}"

      CMS.update_field_definition!(ctx.terms, %{name: to, multiple: true}, actor: ctx.admin)
      reshaped = reload(post)

      assert reshaped.custom_fields[to] == ["dark"]
      assert held(reshaped)[to] == ["light"]
      assert WorkingCopy.reconcile(reshaped).conflicts == []
      assert {:ok, published} = publish_changes(reshaped, ctx.admin)
      assert published.custom_fields[to] == ["light"]
    end
  end

  defp reload_def(definition), do: CMS.get_field_definition!(definition.id, authorize?: false)

  # T12
  test "a retype into a scalar list reshapes neither copy", ctx do
    notes = field!(ctx.admin, %{name: "notes_#{System.unique_integer([:positive])}"})
    post = live_post(ctx.admin, %{notes.name => "dark"})
    saved = draft!(post, %{notes.name => "light"}, ctx.admin)

    CMS.update_field_definition!(
      notes,
      %{field_type: :select, options: ["dark", "light"], multiple: true},
      actor: ctx.admin
    )

    after_retype = reload(post)
    assert after_retype.custom_fields[notes.name] == "dark"
    assert held(after_retype)[notes.name] == "light"
    assert after_retype.working_base == saved.working_base
  end

  # T13
  describe "records the sync does not reach" do
    test "a record with no copy, or a copy holding no custom_fields, keeps its columns", ctx do
      plain = live_post(ctx.admin, %{ctx.subtitle.name => "Plain"})
      seo = live_post(ctx.admin, %{ctx.subtitle.name => "Seo"})

      {:ok, seo} =
        CMS.save_post_working_copy(seo, %{fields: %{"seo_title" => "Held SEO"}},
          actor: ctx.admin,
          tenant: seo.org_id
        )

      rename!(ctx.subtitle, "tagline_#{System.unique_integer([:positive])}", ctx.admin)

      assert reload(plain).working_fields == plain.working_fields
      assert reload(seo).working_fields == seo.working_fields
      assert reload(seo).working_base == seo.working_base
    end

    # T14
    test "another dynamic type with the same field name is untouched", ctx do
      {type_a, field_a} = entry_type!(ctx.admin)
      {type_b, _field_b} = entry_type!(ctx.admin)

      a = live_entry(ctx.admin, type_a, %{"servings" => 2})
      b = live_entry(ctx.admin, type_b, %{"servings" => 2})
      draft_entry!(a, %{"servings" => "4"}, ctx.admin)
      b = draft_entry!(b, %{"servings" => "6"}, ctx.admin)

      CMS.update_field_definition!(field_a, %{name: "portions"}, actor: ctx.admin)

      untouched = reload_entry(b)
      assert untouched.custom_fields == %{"servings" => 2}
      assert held(untouched) == %{"servings" => 6}
      assert untouched.working_base == b.working_base
      assert untouched.lock_version == b.lock_version
    end

    # T23
    test "a dynamic type's entry follows the rename, as a post does", ctx do
      {type_a, field_a} = entry_type!(ctx.admin)
      a = live_entry(ctx.admin, type_a, %{"servings" => 2})
      draft_entry!(a, %{"servings" => "4"}, ctx.admin)

      CMS.update_field_definition!(field_a, %{name: "portions"}, actor: ctx.admin)

      renamed = reload_entry(a)
      assert held(renamed) == %{"portions" => 4}
      assert WorkingCopy.reconcile(renamed).conflicts == []

      {:ok, published} =
        ContentTypes.transition(type_a.name, "publish_changes", renamed, actor: ctx.admin)

      assert published.custom_fields == %{"portions" => 4}
    end
  end

  defp entry_type!(admin) do
    type =
      CMS.create_type_definition!(
        %{name: "fswc#{System.unique_integer([:positive])}", label: "Recipe"},
        actor: admin
      )

    field =
      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "servings", label: "Servings", field_type: :integer},
        actor: admin
      )

    {type, field}
  end

  defp live_entry(admin, type, fields) do
    entry =
      ContentTypes.create!(type.name, %{title: "Dish", slug: slug(), custom_fields: fields},
        actor: admin
      )

    {:ok, entry} = ContentTypes.transition(type.name, "publish", entry, actor: admin)
    reload_entry(entry)
  end

  defp draft_entry!(entry, fields, admin) do
    {:ok, saved} =
      CMS.save_entry_working_copy(entry, %{fields: %{"custom_fields" => fields}},
        actor: admin,
        tenant: entry.org_id
      )

    saved
  end

  defp reload_entry(entry), do: CMS.get_entry!(entry.id, authorize?: false, tenant: entry.org_id)

  # T9
  describe "a flexible field's items" do
    # sections > hero (headline, tone setting, rows > row (label))
    setup %{admin: admin} do
      def! = fn attrs -> field!(admin, Map.merge(%{content_type: nil}, attrs)) end

      sections =
        field!(admin, %{
          name: "fswc_sections_#{System.unique_integer([:positive])}",
          field_type: :flexible
        })

      hero = def!.(%{name: "hero", field_type: :group, flex_of_id: sections.id})
      headline = def!.(%{name: "headline", group_of_id: hero.id})

      tone =
        def!.(%{
          name: "tone",
          group_of_id: hero.id,
          field_type: :select,
          options: ["dark", "light"],
          item_setting: true,
          position: 1
        })

      rows = def!.(%{name: "rows", group_of_id: hero.id, field_type: :flexible, position: 2})
      row = def!.(%{name: "row", field_type: :group, flex_of_id: rows.id})
      label = def!.(%{name: "label", group_of_id: row.id})

      %{sections: sections, hero: hero, headline: headline, tone: tone, row: row, label: label}
    end

    defp hero_item(headline, row_label),
      do: %{
        "_type" => "hero",
        "headline" => headline,
        "_settings" => %{"tone" => "dark"},
        "rows" => [%{"_type" => "row", "label" => row_label}]
      }

    defp drafted_items(ctx) do
      post = live_post(ctx.admin, %{ctx.sections.name => [hero_item("Live", "Live row")]})
      draft!(post, %{ctx.sections.name => [hero_item("Held", "Held row")]}, ctx.admin)
      post
    end

    defp held_hero(post, ctx),
      do: post |> reload() |> held() |> Map.fetch!(ctx.sections.name) |> hd()

    test "a sub-field rename reaches the held items", ctx do
      post = drafted_items(ctx)
      CMS.update_field_definition!(ctx.headline, %{name: "title"}, actor: ctx.admin)

      assert %{"title" => "Held"} = hero = held_hero(post, ctx)
      refute Map.has_key?(hero, "headline")
      assert WorkingCopy.reconcile(reload(post)).conflicts == []
    end

    test "a setting rename reaches the held items' _settings", ctx do
      post = drafted_items(ctx)
      CMS.update_field_definition!(ctx.tone, %{name: "mood"}, actor: ctx.admin)

      assert %{"_settings" => %{"mood" => "dark"}} = held_hero(post, ctx)
      assert WorkingCopy.reconcile(reload(post)).conflicts == []
    end

    test "an item type rename rewrites the held items' _type", ctx do
      post = drafted_items(ctx)
      CMS.update_field_definition!(ctx.hero, %{name: "banner"}, actor: ctx.admin)

      assert %{"_type" => "banner"} = held_hero(post, ctx)
      assert WorkingCopy.reconcile(reload(post)).conflicts == []
    end

    test "a nested sub-field rename reaches the held items two levels down", ctx do
      post = drafted_items(ctx)
      CMS.update_field_definition!(ctx.label, %{name: "caption"}, actor: ctx.admin)

      assert %{"rows" => [%{"caption" => "Held row"} = row]} = held_hero(post, ctx)
      refute Map.has_key?(row, "label")
      assert WorkingCopy.reconcile(reload(post)).conflicts == []
    end

    test "a sub-field purge removes the key from the held items", ctx do
      post = drafted_items(ctx)
      :ok = CMS.destroy_field_definition!(ctx.headline, actor: ctx.admin)

      refute Map.has_key?(held_hero(post, ctx), "headline")
      assert WorkingCopy.reconcile(reload(post)).conflicts == []
    end

    test "destroying the item type with purge_items? removes the held items too", ctx do
      post = drafted_items(ctx)

      :ok =
        CMS.destroy_field_definition!(ctx.row, %{purge_items?: true}, actor: ctx.admin)

      purged = reload(post)
      refute Map.has_key?(hd(purged.custom_fields[ctx.sections.name]), "rows")
      refute Map.has_key?(held_hero(post, ctx), "rows")
      assert WorkingCopy.reconcile(purged).conflicts == []
    end

    # Critic 1: the guard counts held items.
    test "an item type only a draft holds is still refused without purge_items?", ctx do
      post = live_post(ctx.admin, %{})
      draft!(post, %{ctx.sections.name => [hero_item("Held", "Held row")]}, ctx.admin)

      assert {:error, %Ash.Error.Invalid{}} =
               CMS.destroy_field_definition(ctx.row, actor: ctx.admin)

      assert {:ok, 1} = KilnCMS.CMS.FlexiblePath.count_stored(ctx.row, ctx.row.org_id)
    end
  end

  # Critic 1: FieldSync's data-loss report counts held values.
  describe "a field sync import" do
    defp import_doc(ctx, fun, opts \\ []) do
      {:ok, doc} = CMS.FieldSync.export(actor: ctx.admin)

      doc =
        update_in(doc, ["owners", Access.all(), "fields"], fn fields ->
          fields |> Enum.map(&fun.(&1)) |> Enum.reject(&is_nil/1)
        end)

      CMS.FieldSync.import_doc(doc, [actor: ctx.admin, apply?: true] ++ opts)
    end

    test "deleting a field only a draft holds a value of is reported as data loss", ctx do
      post = live_post(ctx.admin, %{})
      draft!(post, %{ctx.subtitle.name => "Draft only"}, ctx.admin)
      name = ctx.subtitle.name

      assert {:error, report} =
               import_doc(
                 ctx,
                 fn
                   %{"name" => ^name} -> nil
                   field -> field
                 end,
                 prune?: true
               )

      assert Enum.any?(report.blocked, &(&1.reason =~ "drops the values"))

      assert {:ok, _report} =
               import_doc(
                 ctx,
                 fn
                   %{"name" => ^name} -> nil
                   field -> field
                 end,
                 prune?: true,
                 allow_data_loss?: true
               )

      refute Map.has_key?(reload(post).working_fields, "custom_fields")
      assert WorkingCopy.pending?(reload(post))
    end

    test "narrowing a list only a draft holds is reported as data loss", ctx do
      terms =
        field!(ctx.admin, %{
          name: "terms_#{System.unique_integer([:positive])}",
          field_type: :select,
          options: ["a", "b"],
          multiple: true
        })

      post = live_post(ctx.admin, %{})
      draft!(post, %{terms.name => ["a", "b"]}, ctx.admin)
      name = terms.name

      assert {:error, report} =
               import_doc(ctx, fn
                 %{"name" => ^name} = field -> Map.put(field, "multiple", false)
                 field -> field
               end)

      assert Enum.any?(report.blocked, &(&1.reason =~ "keeps only its first item"))
    end

    # Critic 3: inside the import's transaction a failed rewrite fails the
    # import, which rolls back whole.
    test "a rewrite that fails inside the import fails the import", ctx do
      post = live_post(ctx.admin, %{ctx.subtitle.name => "Live"})
      corrupt_held!("posts", post.id, ctx.subtitle.name)
      name = ctx.subtitle.name

      assert {:error, %{errors: [_ | _]}} =
               import_doc(
                 ctx,
                 fn
                   %{"name" => ^name} -> nil
                   field -> field
                 end,
                 prune?: true,
                 allow_data_loss?: true
               )

      assert CMS.get_field_definition!(ctx.subtitle.id, authorize?: false)
      assert reload(post).custom_fields[name] == "Live"
    end
  end

  # Critic 2: after the definition committed, a failed held rewrite must not
  # strand the live values: they move as they did before #2744.
  test "a held rewrite that fails after the commit still moves the live values", ctx do
    broken = live_post(ctx.admin, %{ctx.subtitle.name => "Broken"})
    corrupt_held!("posts", broken.id, ctx.subtitle.name)
    other = live_post(ctx.admin, %{ctx.subtitle.name => "Other"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = CMS.destroy_field_definition!(ctx.subtitle, actor: ctx.admin)
      end)

    assert log =~ "could not rewrite pending working copies"
    refute Map.has_key?(reload(broken).custom_fields, ctx.subtitle.name)
    refute Map.has_key?(reload(other).custom_fields, ctx.subtitle.name)
  end

  # A held map that is a JSON string naming the key: `?` matches it, and the
  # purge's `-` then refuses a scalar. Nothing writes this; it stands in for
  # any statement that fails on the held side only.
  defp corrupt_held!(table, id, key) do
    KilnCMS.Repo.query!(
      "UPDATE #{table} SET working_fields = jsonb_build_object('custom_fields', to_jsonb($2::text)), " <>
        "working_base = '{\"custom_fields\": \"x\"}'::jsonb, working_copy_at = now() WHERE id = $1",
      [Ecto.UUID.dump!(id), key]
    )
  end

  # T17
  test "a map decoded by the repo fingerprints as the Ash-loaded one", ctx do
    rich = %{
      ctx.subtitle.name => "Ünïcödé ✓",
      ctx.summary.name => nil,
      "n" => 3,
      "f" => 2.5,
      "whole" => 2.0,
      "list" => [1, [2, %{"x" => "y"}], %{"z" => [true, false, nil]}]
    }

    post = CMS.create_post!(%{title: "Rich", slug: slug()}, actor: ctx.admin)

    KilnCMS.Repo.query!("UPDATE posts SET custom_fields = $1 WHERE id = $2", [
      rich,
      Ecto.UUID.dump!(post.id)
    ])

    loaded = reload(post)
    decoded = raw("posts", post.id, "custom_fields")

    assert WorkingCopy.fingerprint(KilnCMS.CMS.Post, "custom_fields", loaded.custom_fields) ==
             WorkingCopy.fingerprint(
               KilnCMS.CMS.Post,
               "custom_fields",
               WorkingCopy.cast(KilnCMS.CMS.Post, :custom_fields, decoded)
             )
  end
end
