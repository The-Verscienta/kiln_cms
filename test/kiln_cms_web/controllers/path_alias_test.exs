defmodule KilnCMSWeb.PathAliasTest do
  @moduledoc """
  Multi-segment path aliases (#485): the alias serves as the canonical URL
  (any depth, via the delivery fallback), the flat slug URL 301s to it, alias
  changes/removals on published content leave redirects, the resolve endpoint
  mirrors delivery, and the `path` calculation + sitemap prefer the alias.
  Validation rejects malformed, reserved, and colliding aliases.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page

  defp uniq, do: System.unique_integer([:positive])

  defp published_page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{
          title: "Aliased page",
          slug: "pa-#{uniq()}",
          state: :published,
          blocks: [%{type: :heading, content: "Alias Body Heading", order: 0}]
        },
        attrs
      )
    )
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "alias-admin-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  test "a deep alias serves the record and the flat URL 301s to it", %{conn: conn} do
    n = uniq()
    alias_path = "/acupuncture/needle/size/#{n}mm"
    page = published_page(%{path_alias: alias_path})

    html = conn |> get(alias_path) |> html_response(200)
    assert html =~ "Alias Body Heading"

    assert redirected_to(get(conn, "/#{page.slug}"), 301) == alias_path
  end

  test "the flat URL's 301 to the alias keeps the request's locale prefix", %{conn: conn} do
    n = uniq()
    alias_path = "/acupuncture/aiguille/#{n}mm"
    page = published_page(%{path_alias: alias_path, locale: "fr"})

    assert redirected_to(get(conn, "/fr/#{page.slug}"), 301) == "/fr" <> alias_path
  end

  test "a two-segment alias works through the generic route's fallback", %{conn: conn} do
    n = uniq()
    alias_path = "/kiln/care-#{n}"
    published_page(%{path_alias: alias_path})

    assert conn |> get(alias_path) |> html_response(200) =~ "Alias Body Heading"
  end

  test "changing a published alias leaves a 301; removing it restores the flat URL",
       %{conn: conn} do
    n = uniq()
    old_alias = "/guides/old-#{n}"
    new_alias = "/guides/new-#{n}"
    page = published_page(%{path_alias: old_alias})

    CMS.update_page!(page, %{path_alias: new_alias}, authorize?: false)
    assert redirected_to(get(conn, old_alias), 301) == new_alias

    CMS.update_page!(
      CMS.get_page!(page.id, authorize?: false),
      %{path_alias: nil},
      authorize?: false
    )

    assert redirected_to(get(conn, new_alias), 301) == "/#{page.slug}"
    assert conn |> get("/#{page.slug}") |> html_response(200)
  end

  test "the resolve endpoint mirrors delivery", %{conn: conn} do
    n = uniq()
    alias_path = "/catalog/deep/item-#{n}"
    page = published_page(%{path_alias: alias_path})

    flat =
      conn
      |> get("/api/resolve?path=#{URI.encode_www_form("/" <> page.slug)}")
      |> json_response(200)

    assert %{"status" => "moved", "to" => ^alias_path} = flat

    aliased =
      conn |> get("/api/resolve?path=#{URI.encode_www_form(alias_path)}") |> json_response(200)

    assert %{"status" => "ok", "slug" => slug} = aliased
    assert slug == page.slug
  end

  # The sitemap's alias handling lives in sitemap_controller_test (async:
  # false — the sitemap XML is served from the shared cache).
  test "the path calculation prefers the alias" do
    n = uniq()
    alias_path = "/library/shelf/book-#{n}"
    page = published_page(%{path_alias: alias_path})

    assert CMS.get_page!(page.id, load: [:path], authorize?: false).path == alias_path
  end

  describe "pattern-generated aliases (#485 follow-up)" do
    defp needle_type(actor, attrs \\ %{}) do
      type =
        CMS.create_type_definition!(
          Map.merge(
            %{
              name: "needle#{uniq()}",
              label: "Needle",
              alias_pattern: "/acupuncture/needle/size/[field:size]"
            },
            attrs
          ),
          actor: actor
        )

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "size", label: "Size", field_type: :string},
        actor: actor
      )

      type
    end

    test "a custom-field token auto-fills the alias and serves the deep URL", %{conn: conn} do
      actor = admin()
      type = needle_type(actor)

      entry =
        KilnCMS.CMS.ContentTypes.create!(
          type.name,
          %{title: "Fine Needle #{uniq()}", custom_fields: %{"size" => "14mm"}},
          actor: actor
        )

      assert entry.path_alias == "/acupuncture/needle/size/14mm"

      {:ok, _published} =
        KilnCMS.CMS.ContentTypes.transition(type.name, "publish", entry, actor: actor)

      assert conn |> get("/acupuncture/needle/size/14mm") |> html_response(200)

      assert redirected_to(get(conn, "/#{type.path_segment}/#{entry.slug}"), 301) ==
               "/acupuncture/needle/size/14mm"
    end

    test "duplicate expansions dedupe with a numeric suffix" do
      actor = admin()
      type = needle_type(actor)
      fields = %{custom_fields: %{"size" => "20mm"}}

      first =
        KilnCMS.CMS.ContentTypes.create!(
          type.name,
          Map.put(fields, :title, "First #{uniq()}"),
          actor: actor
        )

      second =
        KilnCMS.CMS.ContentTypes.create!(
          type.name,
          Map.put(fields, :title, "Second #{uniq()}"),
          actor: actor
        )

      assert first.path_alias == "/acupuncture/needle/size/20mm"
      assert second.path_alias == "/acupuncture/needle/size/20mm-2"
    end

    test "an explicit alias beats the pattern; clearing it regenerates" do
      actor = admin()
      type = needle_type(actor)
      custom = "/hand/picked-#{uniq()}"

      entry =
        KilnCMS.CMS.ContentTypes.create!(
          type.name,
          %{title: "Manual #{uniq()}", path_alias: custom, custom_fields: %{"size" => "9mm"}},
          actor: actor
        )

      assert entry.path_alias == custom

      regenerated =
        KilnCMS.CMS.ContentTypes.update(type.name, entry, %{path_alias: ""}, actor: actor)

      assert {:ok, %{path_alias: "/acupuncture/needle/size/9mm"}} = regenerated
    end

    test "types without an alias pattern get no alias" do
      actor = admin()

      type =
        CMS.create_type_definition!(
          %{name: "plain#{uniq()}", label: "Plain"},
          actor: actor
        )

      entry =
        KilnCMS.CMS.ContentTypes.create!(type.name, %{title: "Flat #{uniq()}"}, actor: actor)

      assert entry.path_alias == nil
    end
  end

  # A `[field:<name>]` token that points at a `:computed` field (#616). The
  # value is derived by `ApplyCustomFields`, which runs AFTER alias derivation,
  # so before the fix the token read the empty (create) or stale (update) value:
  # the alias collapsed to `/` on create and lagged one save behind on update.
  describe "computed custom-field tokens (#616)" do
    defp url_key_type(actor) do
      type =
        CMS.create_type_definition!(
          %{
            name: "keyed#{uniq()}",
            label: "Keyed",
            alias_pattern: "/library/[field:url_key]"
          },
          actor: actor
        )

      CMS.create_field_definition!(
        %{
          type_definition_id: type.id,
          name: "url_key",
          label: "URL key",
          field_type: :computed,
          compute: "{{ slugify(title) }}"
        },
        actor: actor
      )

      type
    end

    test "resolves to the derived value on create, with the key absent from the payload" do
      actor = admin()
      type = url_key_type(actor)

      # No `custom_fields` key at all — a computed field takes none, which is
      # exactly the create-via-API shape the token used to expand to "".
      entry =
        KilnCMS.CMS.ContentTypes.create!(type.name, %{title: "Fine Bindings"}, actor: actor)

      assert entry.path_alias == "/library/fine-bindings"
    end

    test "follows the title on update rather than lagging one save behind" do
      actor = admin()
      type = url_key_type(actor)

      entry =
        KilnCMS.CMS.ContentTypes.create!(type.name, %{title: "First Title"}, actor: actor)

      assert entry.path_alias == "/library/first-title"

      # Clear the alias so it re-derives, and rename in the same write: the token
      # must see the NEW title's computed value, not the stored one.
      {:ok, updated} =
        KilnCMS.CMS.ContentTypes.update(
          type.name,
          entry,
          %{title: "Second Title", path_alias: ""},
          actor: actor
        )

      assert updated.path_alias == "/library/second-title"
    end

    test "a computed field that turns blank on update reads absent, not the stale value" do
      actor = admin()

      type =
        CMS.create_type_definition!(
          %{name: "keyed#{uniq()}", label: "Keyed", alias_pattern: "/library/[field:key]"},
          actor: actor
        )

      CMS.create_field_definition!(
        %{
          type_definition_id: type.id,
          name: "key",
          label: "Key",
          field_type: :computed,
          compute: "{{ slugify(seo_title) }}"
        },
        actor: actor
      )

      entry =
        KilnCMS.CMS.ContentTypes.create!(
          type.name,
          %{title: "T #{uniq()}", seo_title: "Alpha Beta"},
          actor: actor
        )

      assert entry.path_alias == "/library/alpha-beta"

      # Clear the field the formula reads, and re-derive the alias — WITHOUT
      # sending `custom_fields`, so the raw map the token would read is the
      # STORED one, still carrying the stale computed `key` ("alpha-beta"). It
      # must not leak into the token now that the derivation is blank.
      {:ok, updated} =
        KilnCMS.CMS.ContentTypes.update(
          type.name,
          entry,
          %{seo_title: "", path_alias: ""},
          actor: actor
        )

      assert updated.path_alias == "/library"
    end
  end

  test "validation rejects malformed, reserved, and colliding aliases" do
    actor = admin()
    page = CMS.create_page!(%{title: "Alias Valid #{uniq()}"}, actor: actor)

    for bad <- ["no-slash", "/Upper/Case", "/trailing/", "/editor/hidden"] do
      assert {:error, _} = CMS.update_page(page, %{path_alias: bad}, actor: actor)
    end

    taken = "/taken/spot-#{uniq()}"
    published_page(%{path_alias: taken})
    assert {:error, _} = CMS.update_page(page, %{path_alias: taken}, actor: actor)

    ok = "/fine/place-#{uniq()}"
    assert CMS.update_page!(page, %{path_alias: ok}, actor: actor).path_alias == ok
  end
end
