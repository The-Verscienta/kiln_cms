defmodule KilnCMSWeb.ContentETagInputsTest do
  @moduledoc """
  A public HTML 304 validates exactly the page being rendered (#2765).

  Each test below changes one thing a page renders that is not a column on the
  page's own row, so `updated_at` does not move, and asserts that a client
  revalidating with the old ETag gets the new page rather than a 304: a
  fragment, a sibling translation, a byline, a category an SEO pattern names,
  an author's name, a media item's alt text, the type registry, the site's
  locale fallbacks and a menu link. The negatives pin the other direction: a
  rebuilt payload with the same data validates the same ETag, so the digest
  does not turn every cache miss into a 200.
  """
  # async: false — the delivery payloads, generation tokens, branding and menus
  # live in the shared Cachex, and the determinism test turns the cache off
  # with `Application.put_env/3`, which is node-wide.
  use KilnCMSWeb.ConnCase, async: false

  # Publishing logs that it stores unsigned provenance in test.
  @moduletag :capture_log

  import KilnCMS.DataCase, only: [drain_oban: 0]

  alias KilnCMS.Accounts
  alias KilnCMS.Cache
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.CMS.Page
  alias KilnCMS.CMS.Post
  alias KilnCMS.CMS.Translations

  setup do
    Cache.bust_published()
    org_id = Accounts.default_org_id()

    on_exit(fn ->
      Cache.bust_locale_fallbacks(org_id)
      Cache.bust_branding(org_id)
      Cache.bump_menus_generation(org_id)
    end)

    %{admin: user(:admin), org_id: org_id}
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "etag-#{uniq()}"

  defp user(role, attrs \\ %{}) do
    Ash.Seed.seed!(
      Accounts.User,
      Map.merge(
        %{
          email: "etag-inputs-#{uniq()}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("password123456"),
          confirmed_at: DateTime.utc_now(),
          role: role
        },
        attrs
      )
    )
  end

  # A real published page: created and published through the actions, so it
  # has version rows, fires, and is re-fired by a fragment's wave.
  defp real_page(actor, attrs) do
    %{title: "Page", slug: slug()}
    |> Map.merge(attrs)
    |> CMS.create_page!(actor: actor)
    |> CMS.publish_page!(%{}, actor: actor)
  end

  defp seeded_page(attrs) do
    Ash.Seed.seed!(Page, Map.merge(%{title: "Seeded", slug: slug(), state: :published}, attrs))
  end

  defp fragment_block(record),
    do: %{"_type" => "fragment", "ref" => %{"type" => "page", "id" => record.id}}

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp etag(conn), do: conn |> get_resp_header("etag") |> List.first()

  defp fetch(path, etag \\ nil) do
    conn = build_conn()
    conn = if etag, do: put_req_header(conn, "if-none-match", etag), else: conn
    get(conn, path)
  end

  # The ETag `path` serves now, after checking it validates itself.
  defp current_etag(path) do
    tag = path |> fetch() |> etag()
    assert is_binary(tag)
    assert fetch(path, tag).status == 304
    tag
  end

  # A revalidation with `stale` is a full 200 under a new ETag; the body.
  defp assert_moved(path, stale) do
    conn = fetch(path, stale)
    html = html_response(conn, 200)
    refute etag(conn) == stale
    html
  end

  defp title_of(html) do
    [title] = Regex.run(~r{<title[^>]*>(.*?)</title>}s, html, capture: :all_but_first)
    title |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  # A dynamic person type, a published person, and a reference field on
  # `content_type` whose values are the document's public byline (#2044).
  defp byline_setup(admin, content_type, name) do
    n = uniq()

    type =
      CMS.create_type_definition!(
        %{name: "person#{n}", label: "Person", path_segment: "people-#{n}"},
        actor: admin
      )

    person =
      %{title: name, slug: slug(), type_definition_id: type.id}
      |> CMS.create_entry!(actor: admin)
      |> CMS.publish_entry!(actor: admin)

    field =
      CMS.create_field_definition!(
        %{
          content_type: content_type,
          name: "people_#{uniq()}",
          label: "People",
          field_type: :reference,
          target_type: type.name,
          multiple: true,
          schema_org_property: :author
        },
        actor: admin
      )

    {person, field}
  end

  describe "an input off the page's row moves the ETag" do
    test "a fragment the page embeds is republished", %{admin: admin} do
      image = fn url -> [%{"_type" => "image", "url" => url, "alt" => "A kiln"}] end
      shared = real_page(admin, %{blocks: image.("/uploads/before.jpg")})
      host = real_page(admin, %{blocks: [fragment_block(shared)]})
      drain_oban()

      path = "/#{host.slug}"
      e0 = current_etag(path)
      assert fetch(path) |> html_response(200) =~ "/uploads/before.jpg"
      host_updated_at = reload(host).updated_at

      # No words change, so the host's search text and so its row stay as they
      # are: only the fragment's re-fire wave reaches the host.
      CMS.update_page!(shared, %{blocks: image.("/uploads/after.jpg")}, actor: admin)
      drain_oban()

      assert reload(host).updated_at == host_updated_at
      html = assert_moved(path, e0)
      assert html =~ "/uploads/after.jpg"
      refute html =~ "/uploads/before.jpg"
    end

    test "a sibling translation is published", %{admin: admin} do
      en = real_page(admin, %{title: "English", locale: "en"})
      path = "/#{en.slug}"
      e0 = current_etag(path)
      refute fetch(path) |> html_response(200) =~ ~s(rel="alternate" hreflang="fr")

      fr = Translations.create_translation!(:page, en, "fr", actor: admin)
      CMS.publish_page!(fr, %{}, actor: admin)
      drain_oban()

      assert assert_moved(path, e0) =~ ~s(rel="alternate" hreflang="fr")
    end

    test "a person a byline names is renamed", %{admin: admin} do
      {person, field} = byline_setup(admin, :post, "Ada")

      post =
        %{title: "Story", slug: slug(), custom_fields: %{field.name => [%{"id" => person.id}]}}
        |> CMS.create_post!(actor: admin)
        |> CMS.publish_post!(actor: admin)

      drain_oban()

      path = "/blog/#{post.slug}"
      e0 = current_etag(path)
      assert fetch(path) |> html_response(200) =~ "Ada"

      CMS.update_entry!(person, %{title: "Ada Lovelace"}, actor: admin)
      drain_oban()

      assert assert_moved(path, e0) =~ "Ada Lovelace"
    end

    test "the category an SEO pattern names is renamed", %{admin: admin} do
      type =
        CMS.create_type_definition!(
          %{name: "guide#{uniq()}", label: "Guide", seo_title_pattern: "[title] | [category]"},
          actor: admin
        )

      category = CMS.create_category!(%{name: "Kiln Care", slug: slug()}, actor: admin)

      entry =
        ContentTypes.create!(type.name, %{title: "Firing", category_id: category.id},
          actor: admin
        )

      {:ok, entry} = ContentTypes.transition(type.name, "publish", entry, actor: admin)
      drain_oban()

      path = "/#{type.path_segment}/#{entry.slug}"
      e0 = current_etag(path)
      assert fetch(path) |> html_response(200) |> title_of() == "Firing | Kiln Care · KilnCMS"

      # A description renders nowhere: still a 304.
      category =
        CMS.update_category!(category, %{description: "How to look after one"}, actor: admin)

      assert fetch(path, e0).status == 304

      CMS.update_category!(category, %{name: "Kiln Keeping"}, actor: admin)
      drain_oban()

      assert assert_moved(path, e0) |> title_of() == "Firing | Kiln Keeping · KilnCMS"
    end

    test "the console author's display name changes" do
      author = user(:editor, %{name: "Grace"})

      post =
        Ash.Seed.seed!(Post, %{
          title: "Authored",
          slug: slug(),
          state: :published,
          author_id: author.id
        })

      path = "/blog/#{post.slug}"
      e0 = current_etag(path)
      assert fetch(path) |> html_response(200) =~ "Grace"

      Accounts.update_profile!(author, %{name: "Grace Hopper"}, actor: author)

      assert assert_moved(path, e0) =~ "Grace Hopper"
    end

    # The block's own alt is empty, so the library's alt is what renders (#2765).
    test "an image's library alt text is edited", %{admin: admin} do
      media =
        Ash.Seed.seed!(MediaItem, %{
          filename: "p.jpg",
          url: "/uploads/orig",
          content_type: "image/jpeg",
          width: 1600,
          height: 1067,
          alt: "A kiln at dusk"
        })

      page =
        seeded_page(%{
          blocks:
            KilnCMS.TypedFixtures.typed_blocks([
              %{
                type: :image,
                content: "/uploads/orig",
                data: %{"media_id" => media.id, "alt" => ""},
                order: 0
              }
            ])
        })

      path = "/#{page.slug}"
      e0 = current_etag(path)
      assert fetch(path) |> html_response(200) =~ ~s(alt="A kiln at dusk")

      CMS.update_media_item!(media, %{alt: "A kiln at dawn"}, actor: admin)

      html = assert_moved(path, e0)
      assert html =~ ~s(alt="A kiln at dawn")
      refute html =~ ~s(alt="A kiln at dusk")
    end

    test "the page's type starts syndicating", %{admin: admin} do
      type =
        CMS.create_type_definition!(%{name: "recipe#{uniq()}", label: "Recipe"}, actor: admin)

      entry = ContentTypes.create!(type.name, %{title: "Bread"}, actor: admin)
      {:ok, entry} = ContentTypes.transition(type.name, "publish", entry, actor: admin)
      drain_oban()

      path = "/#{type.path_segment}/#{entry.slug}"
      e0 = current_etag(path)

      CMS.update_type_definition!(type, %{has_published_feed: true}, actor: admin)

      assert_moved(path, e0)
    end

    # The switcher is built from the chains at render time: `/fr/x` gains a
    # Spanish link once Spanish falls back to French, with no payload change.
    test "the site's locale fallbacks are saved", %{admin: admin, org_id: org_id} do
      fr = real_page(admin, %{title: "Seulement", locale: "fr"})
      path = "/fr/#{fr.slug}"
      e0 = current_etag(path)
      refute fetch(path) |> html_response(200) =~ "/es/#{fr.slug}"

      CMS.save_site_locale_settings!(%{fallbacks: %{"es" => ["fr"]}},
        actor: admin,
        tenant: org_id
      )

      assert assert_moved(path, e0) =~ "/es/#{fr.slug}"
    end

    # A menu `:content` item's URL is its target's current path, so a target's
    # slug change moves every page's header with nothing on those pages' rows.
    # The menu cache is expired explicitly, as its TTL would.
    test "a header menu link's target moves", %{admin: admin, org_id: org_id} do
      target = real_page(admin, %{title: "Target"})
      page = seeded_page(%{title: "Has a menu"})

      menu = CMS.create_menu!(%{key: "main", name: "Main", locale: "en"}, actor: admin)

      CMS.create_menu_item!(
        %{
          menu_id: menu.id,
          label: "Go",
          position: 0,
          link_type: :content,
          target_type: "page",
          target_id: target.id
        },
        actor: admin
      )

      CMS.save_site_branding!(%{header_menu_key: "main"}, actor: admin, tenant: org_id)
      Cache.bump_menus_generation(org_id)

      path = "/#{page.slug}"
      e0 = current_etag(path)
      assert fetch(path) |> html_response(200) =~ ~s(href="/#{target.slug}")

      moved = "moved-#{uniq()}"
      CMS.update_page!(target, %{slug: moved}, actor: admin)
      drain_oban()
      Cache.bump_menus_generation(org_id)

      assert assert_moved(path, e0) =~ ~s(href="/#{moved}")
    end
  end

  describe "nothing changed, nothing moves" do
    test "a repeat request, a rebuilt payload and another page's publish keep the 304",
         %{admin: admin} do
      page = seeded_page(%{title: "Steady"})
      path = "/#{page.slug}"
      e0 = current_etag(path)

      assert fetch(path, e0).status == 304

      # The payload is rebuilt from the same rows: the same digest.
      Cache.bust_published()
      assert fetch(path, e0).status == 304

      real_page(admin, %{title: "Someone else"})
      drain_oban()
      assert fetch(path, e0).status == 304
    end

    # Every input the digest hashes, on one page, built twice: through the
    # cache after a full clear, and with the cache off, where every request
    # builds its own payload. An input whose term is not stable across builds
    # (an unordered read, a fresh id, a timestamp) fails one of the two.
    test "a page carrying every payload input validates the same ETag across builds",
         %{admin: admin} do
      shared = real_page(admin, %{blocks: [%{"_type" => "heading", "text" => "From a fragment"}]})

      media =
        Ash.Seed.seed!(MediaItem, %{
          filename: "d.jpg",
          url: "/uploads/det",
          content_type: "image/jpeg",
          width: 800,
          height: 600,
          alt: "Library alt"
        })

      form = KilnCMS.FormFixtures.form!(%{}, actor: admin)
      {person, people} = byline_setup(admin, :page, "Ada")

      tagline =
        CMS.create_field_definition!(
          %{
            content_type: :page,
            name: "tagline_#{uniq()}",
            label: "Tagline",
            localization: :fallback
          },
          actor: admin
        )

      en =
        real_page(admin, %{
          title: "Everything",
          locale: "en",
          custom_fields: %{tagline.name => "Made by hand", people.name => [%{"id" => person.id}]},
          blocks: [
            fragment_block(shared),
            %{"_type" => "image", "url" => "/uploads/det", "media_id" => media.id, "alt" => ""},
            %{"_type" => "form", "form_slug" => form.slug},
            # A nested child carries an id only when its writer gives one.
            %{
              "_type" => "columns",
              "columns" => [%{"blocks" => [%{"_type" => "heading", "text" => "Nested"}]}]
            }
          ]
        })

      for locale <- ["fr", "es"] do
        variant = Translations.create_translation!(:page, en, locale, actor: admin)
        variant = CMS.update_page!(variant, %{custom_fields: %{tagline.name => ""}}, actor: admin)
        CMS.publish_page!(variant, %{}, actor: admin)
      end

      drain_oban()

      # The French variant inherits the tagline along its chain.
      path = "/fr/#{en.slug}"
      e0 = current_etag(path)
      html = fetch(path) |> html_response(200)
      assert html =~ "From a fragment"
      # Published en, fr, es; listed by locale, not in the order the rows came
      # back, so the hreflang links and the digest are stable.
      assert Regex.scan(~r/rel="alternate" hreflang="([^"]+)"/, html, capture: :all_but_first) ==
               [["en"], ["es"], ["fr"], ["x-default"]]

      Cache.bust_published()
      assert fetch(path, e0).status == 304

      original = Application.get_env(:kiln_cms, Cache, [])
      on_exit(fn -> Application.put_env(:kiln_cms, Cache, original) end)
      Application.put_env(:kiln_cms, Cache, Keyword.put(original, :enabled, false))

      # With the cache off the head generation reads "0", so the tag differs
      # from `e0`; what matters is that two uncached builds agree.
      uncached = current_etag(path)
      assert fetch(path, uncached).status == 304
    end
  end
end
