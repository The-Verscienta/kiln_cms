defmodule KilnCMSWeb.DynamicDeliveryTest do
  @moduledoc """
  Phase 3 acceptance (decision D17): a published dynamic entry is served on the
  public site at `/<path_segment>/<slug>`, through the fired-artifact API with
  its dynamic type name, and in the sitemap — and archiving its type stops
  public resolution immediately (registry cache bust).
  """
  # async: false — delivery is served through the shared content cache (and the
  # cached dynamic-type registry), which other tests may bust concurrently.
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Cache
  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes

  setup do
    Cache.bust_published()
    :ok
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "dyndel-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp define_type!(actor) do
    CMS.create_type_definition!(
      %{name: "recipe#{System.unique_integer([:positive])}", label: "Recipe"},
      actor: actor
    )
  end

  defp published_entry! do
    actor = admin()
    definition = define_type!(actor)

    entry =
      ContentTypes.create!(
        definition.name,
        %{
          title: "Pancakes",
          slug: "pancakes-#{System.unique_integer([:positive])}",
          blocks: [%{type: :heading, content: "Fluffy stack", data: %{"level" => 1}, order: 0}]
        },
        actor: actor
      )

    {:ok, entry} = ContentTypes.transition(definition.name, "publish", entry, actor: actor)
    {definition, entry, actor}
  end

  test "a published entry is served on the public site at /<segment>/<slug>", %{conn: conn} do
    {definition, entry, _actor} = published_entry!()

    conn = get(conn, "/#{definition.path_segment}/#{entry.slug}")
    body = html_response(conn, 200)
    assert body =~ "Pancakes"
    assert body =~ "Fluffy stack"
  end

  test "drafts and unknown segments 404", %{conn: conn} do
    actor = admin()
    definition = define_type!(actor)

    draft =
      ContentTypes.create!(
        definition.name,
        %{title: "Secret", slug: "secret-#{System.unique_integer([:positive])}"},
        actor: actor
      )

    assert conn |> get("/#{definition.path_segment}/#{draft.slug}") |> response(404)
    assert conn |> get("/no-such-type/anything") |> response(404)
  end

  test "the artifact API serves fired surfaces under the dynamic type name", %{conn: conn} do
    {definition, entry, _actor} = published_entry!()
    # Firing is async (#201): run the enqueued FireWorker so the artifact exists.
    KilnCMS.DataCase.drain_oban()

    body = conn |> get("/api/content/#{definition.name}/#{entry.slug}") |> json_response(200)

    # The consumer-facing type is the dynamic type's name, not the `:entry`
    # storage key.
    assert body["type"] == definition.name
    assert body["title"] == "Pancakes"
    assert [%{"_type" => "heading"} | _] = body["blocks"]

    web =
      conn
      |> get("/api/content/#{definition.name}/#{entry.slug}?surface=web")
      |> json_response(200)

    assert web["html"] =~ "Fluffy stack"
  end

  test "on-site search finds published entries and labels them by type", %{conn: conn} do
    {definition, entry, _actor} = published_entry!()

    body = conn |> get("/search?q=Pancakes") |> html_response(200)
    assert body =~ entry.slug
    assert body =~ definition.label
    assert body =~ "/#{definition.path_segment}/#{entry.slug}"
  end

  test "the sitemap lists published entries at their public URL", %{conn: conn} do
    {definition, entry, _actor} = published_entry!()

    body = conn |> get(~p"/sitemap.xml") |> response(200)
    assert body =~ "<loc>http://localhost:4000/#{definition.path_segment}/#{entry.slug}</loc>"
  end

  test "TypeDefinition writes bust the cached registry (prod cache path)" do
    # The registry cache is off in test config (global key vs per-test
    # sandboxes) — turn it on for this sync test to exercise the bust path.
    Application.put_env(:kiln_cms, ContentTypes, cache_registry?: true)

    org_id = KilnCMS.Accounts.default_org_id()

    on_exit(fn ->
      Application.put_env(:kiln_cms, ContentTypes, cache_registry?: false)
      Cache.bust_type_registry(org_id)
    end)

    # Start clean of anything a previous test may have cached.
    Cache.bust_type_registry(org_id)

    actor = admin()
    definition = define_type!(actor)
    # Cached read includes the new type (create busted any stale registry).
    assert Enum.any?(ContentTypes.dynamic_all(), &(&1.type == definition.name))

    # Archiving busts again — the cached registry doesn't serve the ghost.
    :ok = CMS.destroy_type_definition(definition, actor: actor)
    refute Enum.any?(ContentTypes.dynamic_all(), &(&1.type == definition.name))
  end

  test "archiving the type stops public resolution immediately", %{conn: conn} do
    {definition, entry, actor} = published_entry!()

    # Served (and cached) while the type exists…
    assert conn |> get("/#{definition.path_segment}/#{entry.slug}") |> response(200)

    # …archiving the TypeDefinition busts the cached registry, so the very next
    # request no longer resolves the path segment — even with warm payloads.
    :ok = CMS.destroy_type_definition(definition, actor: actor)

    assert conn |> get("/#{definition.path_segment}/#{entry.slug}") |> response(404)
  end
end
