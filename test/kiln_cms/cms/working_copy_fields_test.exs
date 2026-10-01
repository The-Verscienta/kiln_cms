defmodule KilnCMS.CMS.WorkingCopyFieldsTest do
  @moduledoc """
  The working copy covers every content field of a live document, not just its
  title and body (#1815).

  A tester edited a published entry's settings, saved, added the entry to a
  release — and the release said "already in that state — will be skipped",
  because the save had already put the settings live. On a published record a
  save must never change what readers get; `:publish_changes` (or a release)
  promotes the whole copy at once.
  """
  use KilnCMS.DataCase, async: true

  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.Releases
  alias KilnCMS.CMS.WorkingCopy

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "wcf-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "wcf-#{System.unique_integer([:positive])}"

  defp heading(text), do: %{"_type" => "heading", "text" => text}

  defp reload(page),
    do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id, load: [:tags])

  defp category!(admin),
    do: CMS.create_category!(%{name: "Cat #{slug()}", slug: slug()}, actor: admin)

  defp tag!(admin), do: CMS.create_tag!(%{name: "Tag #{slug()}", slug: slug()}, actor: admin)

  defp media! do
    Ash.Seed.seed!(KilnCMS.CMS.MediaItem, %{
      filename: "hero-#{System.unique_integer([:positive])}.png",
      url: "/uploads/hero.png",
      alt: "A hero image"
    })
  end

  defp live_page(admin, attrs \\ %{}) do
    page =
      CMS.create_page!(
        Map.merge(
          %{
            title: "Live",
            slug: slug(),
            blocks: [heading("Published body")],
            seo_title: "Live SEO"
          },
          attrs
        ),
        actor: admin
      )

    CMS.publish_page!(page, %{}, actor: admin)
    KilnCMS.DataCase.drain_oban()
    reload(page)
  end

  defp save_fields(record, fields, actor) do
    CMS.save_page_working_copy(record, %{fields: fields}, actor: actor, tenant: record.org_id)
  end

  defp delivered(page), do: CMS.get_published_page_by_slug!(page.slug, page.locale)

  defp tag_ids(record), do: record.tags |> Enum.map(&to_string(&1.id)) |> Enum.sort()

  describe "saving held fields on a live page" do
    test "leaves the public read alone and makes the copy pending" do
      admin = user(:admin)
      cat = category!(admin)
      image = media!()
      tag = tag!(admin)
      page = live_page(admin)

      assert {:ok, saved} =
               save_fields(
                 page,
                 %{
                   "seo_title" => "Held SEO",
                   "seo_description" => "Held description",
                   "category_id" => cat.id,
                   "featured_image_id" => image.id,
                   "add_tag_ids" => [tag.id]
                 },
                 admin
               )

      assert WorkingCopy.pending?(saved)
      # The text did not move: the copy starts from the published text.
      assert saved.working_title == "Live"

      live = delivered(page)
      assert live.seo_title == "Live SEO"
      assert live.seo_description == nil
      assert live.category_id == nil
      assert live.featured_image_id == nil
      assert tag_ids(reload(page)) == []

      # Search and the artifacts saw nothing.
      assert reload(page).search_text == page.search_text
      refute_enqueued(worker: KilnCMS.Firing.FireWorker, args: %{"id" => page.id})

      # The editor's view carries every held value.
      view = WorkingCopy.view(saved)
      assert view.seo_title == "Held SEO"
      assert view.seo_description == "Held description"
      assert view.category_id == cat.id
      assert view.featured_image_id == image.id

      loaded = WorkingCopy.load_view(reload(saved), authorize?: false, tenant: page.org_id)
      assert tag_ids(loaded) == [to_string(tag.id)]
    end

    test "keeps the public page cache: nothing it serves changed" do
      admin = user(:admin)
      page = live_page(admin)
      org = page.org_id

      assert :cached = KilnCMS.Cache.fetch_published(org, "page", page.slug, "en", fn -> :cached end)

      {:ok, saved} = save_fields(page, %{"seo_title" => "Held"}, admin)
      assert :cached = KilnCMS.Cache.fetch_published(org, "page", page.slug, "en", fn -> :fresh end)

      # Publishing the copy is what changes the page, and what busts it.
      {:ok, _} = CMS.publish_page_changes(saved, actor: admin)
      assert :fresh = KilnCMS.Cache.fetch_published(org, "page", page.slug, "en", fn -> :fresh end)
    end

    test "a field set back to its live value leaves the copy; nothing left, no copy" do
      admin = user(:admin)
      page = live_page(admin)

      {:ok, saved} = save_fields(page, %{"seo_title" => "Held"}, admin)
      assert WorkingCopy.pending?(saved)

      {:ok, back} = save_fields(saved, %{"seo_title" => "Live SEO"}, admin)
      refute WorkingCopy.pending?(back)
      assert back.working_fields == %{}
      assert back.working_title == nil
    end

    test "an absent key keeps what the copy held" do
      admin = user(:admin)
      page = live_page(admin)

      {:ok, saved} = save_fields(page, %{"seo_title" => "Held"}, admin)
      {:ok, saved} = save_fields(saved, %{"seo_description" => "Also held"}, admin)

      view = WorkingCopy.view(saved)
      assert view.seo_title == "Held"
      assert view.seo_description == "Also held"
    end

    test "a text autosave keeps the held fields, and the held fields keep the text" do
      admin = user(:admin)
      page = live_page(admin)

      {:ok, saved} = save_fields(page, %{"seo_title" => "Held"}, admin)

      {:ok, saved} =
        CMS.save_page_working_copy(saved, %{working_title: "Edited", working_blocks: page.blocks},
          actor: admin,
          tenant: page.org_id
        )

      assert WorkingCopy.view(saved).seo_title == "Held"

      {:ok, saved} = save_fields(saved, %{"seo_description" => "More"}, admin)
      assert WorkingCopy.view(saved).title == "Edited"
    end

    test "is judged by :update's own checks" do
      admin = user(:admin)
      page = live_page(admin)
      other = live_page(admin)

      assert {:error, error} = save_fields(page, %{"slug" => other.slug}, admin)
      assert Exception.message(error) =~ "slug"
      refute WorkingCopy.pending?(reload(page))

      assert {:error, _} = save_fields(page, %{"canonical_url" => "javascript:alert(1)"}, admin)
    end

    test "refuses operational settings: those still save through :update" do
      admin = user(:admin)
      page = live_page(admin)

      assert {:error, error} = save_fields(page, %{"audience" => "members"}, admin)
      assert Exception.message(error) =~ "save audience through :update"
    end
  end

  describe "publishing the changes" do
    test "Publish changes promotes every held field at once" do
      admin = user(:admin)
      cat = category!(admin)
      image = media!()
      tag = tag!(admin)
      page = live_page(admin)
      old_slug = page.slug
      new_slug = slug()

      {:ok, saved} =
        save_fields(
          page,
          %{
            "seo_title" => "Held SEO",
            "category_id" => cat.id,
            "featured_image_id" => image.id,
            "add_tag_ids" => [tag.id],
            "slug" => new_slug
          },
          admin
        )

      assert {:ok, published} = CMS.publish_page_changes(saved, actor: admin)
      refute WorkingCopy.pending?(published)
      assert published.working_fields == %{}

      live = delivered(%{page | slug: new_slug})
      assert live.seo_title == "Held SEO"
      assert live.category_id == cat.id
      assert live.featured_image_id == image.id
      assert tag_ids(reload(page)) == [to_string(tag.id)]

      # The rename left its 301 when it went live.
      assert [_redirect] =
               CMS.list_redirects!(
                 query: [filter: [target_id: page.id]],
                 authorize?: false,
                 tenant: page.org_id
               )

      assert old_slug != new_slug
    end

    test "a release's publish item applies a settings-only copy" do
      admin = user(:admin)
      page = live_page(admin)
      {:ok, saved} = save_fields(page, %{"seo_title" => "Launch SEO"}, admin)

      release = CMS.create_release!(%{name: "Launch #{slug()}"}, actor: admin)

      {:ok, item} =
        CMS.add_release_item(
          %{release_id: release.id, content_type: "page", content_id: page.id, action: :publish},
          actor: admin
        )

      assert Releases.classify(item, authorize?: false, tenant: page.org_id) == :apply
      # The console's batched readiness agrees with the per-item verdict.
      assert [{_item, :apply}] = Releases.readiness(release, actor: admin)
      assert delivered(saved).seo_title == "Live SEO"

      {:ok, _claimed} = CMS.start_release(release, %{}, actor: admin)
      KilnCMS.DataCase.drain_oban()

      assert delivered(page).seo_title == "Launch SEO"
      refute WorkingCopy.pending?(reload(page))
      assert CMS.get_release_item!(item.id, authorize?: false).status == :applied
    end
  end

  describe "discarding and history" do
    test "Discard drops every held field; restoring its version brings them back" do
      admin = user(:admin)
      tag = tag!(admin)
      page = live_page(admin)

      {:ok, saved} = save_fields(page, %{"seo_title" => "Held", "add_tag_ids" => [tag.id]}, admin)

      {:ok, discarded} = CMS.discard_page_changes(saved, actor: admin)
      refute WorkingCopy.pending?(discarded)
      assert discarded.working_fields == %{}
      assert WorkingCopy.view(discarded).seo_title == "Live SEO"

      held_version =
        CMS.list_page_versions!(authorize?: false, tenant: page.org_id)
        |> Enum.filter(
          &(&1.version_source_id == page.id and &1.version_action_name == :save_working_copy)
        )
        |> Enum.max_by(& &1.version_inserted_at, DateTime)

      {:ok, restored} =
        CMS.restore_page_version(discarded, %{version_id: held_version.id}, actor: admin)

      assert WorkingCopy.pending?(restored)
      assert WorkingCopy.view(restored).seo_title == "Held"
      assert WorkingCopy.held_ids(restored, :tag_ids) == [to_string(tag.id)]
      # Still not live.
      assert delivered(page).seo_title == "Live SEO"
    end

    test "unpublishing folds the held fields into the draft" do
      admin = user(:admin)
      tag = tag!(admin)
      page = live_page(admin)

      {:ok, saved} = save_fields(page, %{"seo_title" => "Held", "add_tag_ids" => [tag.id]}, admin)
      {:ok, _} = CMS.unpublish_page(saved, %{}, actor: admin)

      draft = reload(page)
      assert draft.state == :draft
      assert draft.seo_title == "Held"
      assert draft.working_fields == %{}
      assert tag_ids(draft) == [to_string(tag.id)]
    end
  end

  describe "a dynamic type's custom fields" do
    defp entry_type!(admin) do
      type =
        CMS.create_type_definition!(
          %{name: "dyn#{System.unique_integer([:positive])}", label: "Recipe"},
          actor: admin
        )

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "servings", label: "Servings", field_type: :integer},
        actor: admin
      )

      type
    end

    test "are held until the changes are published" do
      admin = user(:admin)
      type = entry_type!(admin)

      entry =
        ContentTypes.create!(
          type.name,
          %{title: "Pancakes", slug: slug(), custom_fields: %{"servings" => 2}},
          actor: admin
        )

      {:ok, entry} = ContentTypes.transition(type.name, "publish", entry, actor: admin)

      {:ok, saved} =
        CMS.save_entry_working_copy(entry, %{fields: %{"custom_fields" => %{"servings" => "6"}}},
          actor: admin,
          tenant: entry.org_id
        )

      assert WorkingCopy.pending?(saved)
      assert WorkingCopy.view(saved).custom_fields["servings"] == 6

      public = CMS.get_published_entry_by_slug!(entry.slug, entry.locale, type.id)
      assert public.custom_fields["servings"] == 2

      {:ok, _} = ContentTypes.transition(type.name, "publish_changes", saved, actor: admin)

      public = CMS.get_published_entry_by_slug!(entry.slug, entry.locale, type.id)
      assert public.custom_fields["servings"] == 6
    end
  end
end
