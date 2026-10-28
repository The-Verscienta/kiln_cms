defmodule KilnCMSWeb.PortableFieldsDeliveryTest do
  @moduledoc """
  `deliver_portable` on every delivery surface: the fired artifact
  (`/api/content`, and its `?fields=` sparse fieldset), the delta API
  (`/api/sync`), JSON:API and GraphQL — each carries `custom_fields_portable`
  beside `custom_fields`, which keeps the stored HTML. Flipping the flag, or
  switching the field to plain editing, re-fires the type's published
  documents.

  `async: false`: the delivery caches are per org, and this runs on the
  default org every other delivery test shares.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.Accounts
  alias KilnCMS.CMS

  @schema KilnCMSWeb.GraphqlSchema
  @html "<p>Bitter &amp; <em>cold</em>.</p><p>Clears heat.</p>"

  setup do
    # See `KilnCMSWeb.SyncControllerTest`: every write here has committed (to
    # the sandbox) before the next request.
    previous = Application.get_env(:kiln_cms, KilnCMS.Firing.Sync)
    Application.put_env(:kiln_cms, KilnCMS.Firing.Sync, commit_lag_seconds: 0)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kiln_cms, KilnCMS.Firing.Sync, previous),
        else: Application.delete_env(:kiln_cms, KilnCMS.Firing.Sync)
    end)

    KilnCMS.Cache.bust_published()

    actor =
      Ash.Seed.seed!(KilnCMS.Accounts.User, %{
        email: "portable-web-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    name = "props#{System.unique_integer([:positive])}"

    definition =
      CMS.create_field_definition!(
        %{content_type: :page, name: name, label: "Properties", field_type: :text},
        actor: actor
      )

    page =
      CMS.create_page!(
        %{
          title: "Huang Lian",
          slug: "portable-#{System.unique_integer([:positive])}",
          custom_fields: %{name => @html}
        },
        actor: actor
      )

    page = CMS.publish_page!(page, %{}, actor: actor)
    KilnCMS.DataCase.drain_oban()

    %{actor: actor, definition: definition, name: name, page: page}
  end

  # Flips the flag the way the fields admin does, and runs the re-fire the
  # flip enqueues. Reads the definition fresh: a struct that already holds
  # `value` would make the update a no-op Ash drops.
  defp update(%{actor: actor, definition: definition}, attrs) do
    definition
    |> then(&CMS.get_field_definition!(&1.id, actor: actor))
    |> CMS.update_field_definition!(attrs, actor: actor)

    KilnCMS.DataCase.drain_oban()
    KilnCMS.Cache.bust_published()
  end

  defp deliver_portable(ctx, value), do: update(ctx, %{deliver_portable: value})

  defp artifact(conn, page),
    do: conn |> get(~p"/api/content/page/#{page.slug}") |> json_response(200)

  # Two paragraphs, the second word of the first in italics.
  defp assert_portable(%{} = portable, name) do
    assert [first, second] = portable[name]

    assert Enum.map(first["children"], &{&1["text"], &1["marks"]}) ==
             [{"Bitter & ", []}, {"cold", ["em"]}, {".", []}]

    assert [%{"text" => "Clears heat."}] = second["children"]
    assert first["style"] == "normal" and first["_type"] == "block"
  end

  defp json_api(path),
    do: build_conn() |> put_req_header("accept", "application/vnd.api+json") |> get(path)

  defp gql(query, variables),
    do:
      Absinthe.run(query, @schema,
        variables: variables,
        context: %{tenant: Accounts.default_org_id()}
      )

  describe "with the flag on" do
    setup ctx do
      deliver_portable(ctx, true)
      :ok
    end

    test "the fired artifact carries the Portable Text rendition, and the HTML as stored",
         %{conn: conn, page: page, name: name} do
      body = artifact(conn, page)

      assert body["custom_fields"][name] == @html
      assert_portable(body["custom_fields_portable"], name)
      # The plain rendition is its own opt-in.
      refute Map.has_key?(body, "custom_fields_plain")
    end

    test "?fields= keeps it as a top-level key", %{conn: conn, page: page, name: name} do
      body =
        conn
        |> get(~p"/api/content/page/#{page.slug}?fields=title,custom_fields_portable")
        |> json_response(200)

      assert_portable(body["custom_fields_portable"], name)
      refute Map.has_key?(body, "custom_fields")
    end

    test "/api/sync carries it inside the artifact", %{conn: conn, page: page, name: name} do
      body =
        conn |> get("/api/sync", %{"initial" => "true", "type" => "page"}) |> json_response(200)

      assert %{"artifact" => artifact} = Enum.find(body["items"], &(&1["id"] == page.id))
      assert_portable(artifact["custom_fields_portable"], name)
      assert artifact["custom_fields"][name] == @html
    end

    test "JSON:API serves custom_fields_portable when asked", %{page: page, name: name} do
      conn =
        json_api(
          "/api/json/pages/by-slug/#{page.slug}?locale=en&fields[page]=title,custom_fields,custom_fields_portable"
        )

      assert conn.status == 200
      attributes = Jason.decode!(conn.resp_body)["data"]["attributes"]
      assert_portable(attributes["custom_fields_portable"], name)
      assert attributes["custom_fields"][name] == @html

      default = json_api("/api/json/pages/by-slug/#{page.slug}?locale=en")
      assert default.status == 200

      refute Map.has_key?(
               Jason.decode!(default.resp_body)["data"]["attributes"],
               "custom_fields_portable"
             )
    end

    test "GraphQL serves customFieldsPortable when asked", %{page: page, name: name} do
      query = """
      query ($slug: String!) {
        pageBySlug(slug: $slug, locale: "en") { customFields customFieldsPortable }
      }
      """

      assert {:ok, %{data: %{"pageBySlug" => %{"customFieldsPortable" => portable}}}} =
               gql(query, %{"slug" => page.slug})

      portable = if is_binary(portable), do: Jason.decode!(portable), else: portable
      assert_portable(portable, name)
    end
  end

  describe "with the flag off" do
    test "the artifact is what it always was", %{conn: conn, page: page} do
      refute Map.has_key?(artifact(conn, page), "custom_fields_portable")
    end

    test "the calculation is nil", %{page: page} do
      conn =
        json_api(
          "/api/json/pages/by-slug/#{page.slug}?locale=en&fields[page]=title,custom_fields_portable"
        )

      assert conn.status == 200
      attributes = Jason.decode!(conn.resp_body)["data"]["attributes"]
      assert Map.has_key?(attributes, "custom_fields_portable")
      assert attributes["custom_fields_portable"] == nil
    end

    test "turning it off again re-fires without the key", %{conn: conn, page: page} = ctx do
      deliver_portable(ctx, true)
      assert Map.has_key?(artifact(conn, page), "custom_fields_portable")

      deliver_portable(ctx, false)
      refute Map.has_key?(artifact(conn, page), "custom_fields_portable")
    end

    test "switching the field to plain editing re-fires without the key",
         %{conn: conn, page: page} = ctx do
      deliver_portable(ctx, true)
      assert Map.has_key?(artifact(conn, page), "custom_fields_portable")

      update(ctx, %{format: :plain})
      refute Map.has_key?(artifact(conn, page), "custom_fields_portable")
    end
  end
end
