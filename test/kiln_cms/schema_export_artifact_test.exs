defmodule KilnCMS.SchemaExportArtifactTest do
  @moduledoc """
  The closing loop for #430: a **real fired artifact** validated against the
  **real exported schema**.

  Every other test in this area checks one side — that the export derives what
  the DSL declares, or that a render emits what the schema promises. This one
  publishes a document containing the awkward blocks (a nested `columns`, a
  container with normalized item maps, an unfilled placeholder), fires it, and
  runs the resulting `:json` body through the exported document schema. If the
  export is wrong about anything delivery actually serves, this fails.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Firing.Engine
  alias KilnCMS.JsonSchemaValidator
  alias KilnCMS.SchemaExport

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "sxa-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "sxa-#{System.unique_integer([:positive])}"

  # One of nearly every block, including the shapes most likely to drift from
  # their schema: a nested container, the normalized item-map blocks, and a
  # media block with nothing filled in (which takes its `_type`-only branch).
  defp blocks do
    [
      %{"_type" => "heading", "text" => "Welcome", "level" => 1},
      %{"_type" => "rich_text", "legacy_html" => "<p>Body</p>"},
      %{"_type" => "quote", "text" => "Quoted", "citation" => "Someone", "featured" => true},
      %{"_type" => "image", "url" => "/a.png", "alt" => "A", "media_id" => nil},
      %{"_type" => "divider"},
      %{"_type" => "video"},
      %{"_type" => "audio"},
      %{"_type" => "file"},
      %{"_type" => "embed", "url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
      %{
        "_type" => "gallery",
        "title" => "Shots",
        "images" => [%{"url" => "/g.png", "alt" => "G", "caption" => "", "media_id" => ""}]
      },
      %{
        "_type" => "accordion",
        "title" => "Specs",
        "panels" => [%{"title" => "Size", "content" => "Large"}]
      },
      %{"_type" => "faq", "items" => [%{"question" => "Q?", "answer" => "A."}]},
      %{"_type" => "how_to", "name" => "Do it", "steps" => [%{"name" => "One", "text" => "Go"}]},
      %{"_type" => "claim", "text" => "True", "source_url" => "https://example.com"},
      %{"_type" => "custom", "legacy_type" => "old", "content" => "x"},
      %{
        "_type" => "columns",
        "layout" => "1-1",
        "gap" => "md",
        "columns" => [
          %{"blocks" => [%{"_type" => "heading", "text" => "Left", "level" => 3}]},
          %{
            "blocks" => [
              %{
                "_type" => "columns",
                "columns" => [
                  %{"blocks" => [%{"_type" => "quote", "text" => "Deep", "citation" => nil}]}
                ]
              }
            ]
          }
        ]
      }
    ]
  end

  defp published_page(actor, attrs \\ %{}) do
    page =
      CMS.create_page!(
        Map.merge(%{title: "Fired", slug: slug(), blocks: blocks()}, attrs),
        actor: actor
      )

    published = CMS.publish_page!(page, actor: actor)
    # Firing is async (#201) — run the enqueued FireWorker so an artifact exists.
    drain_oban()
    published
  end

  test "a fired :json artifact validates against the exported document schema" do
    actor = admin()
    org_id = KilnCMS.Accounts.default_org_id()
    page = published_page(actor)

    {:ok, body} = Engine.read(org_id, :page, page.id, :json)

    document = SchemaExport.json_schema(org_id: org_id)
    schema = document["$defs"]["content_page"]

    assert JsonSchemaValidator.validate(body, schema, document) == :ok
  end

  test "custom-field values validate against their exported property schemas" do
    actor = admin()
    org_id = KilnCMS.Accounts.default_org_id()

    CMS.create_field_definition!(
      %{content_type: :page, name: "subtitle", label: "Subtitle", field_type: :string},
      actor: actor
    )

    CMS.create_field_definition!(
      %{
        content_type: :page,
        name: "tier",
        label: "Tier",
        field_type: :select,
        options: ["free", "pro"]
      },
      actor: actor
    )

    page =
      published_page(actor, %{custom_fields: %{"subtitle" => "A subtitle", "tier" => "pro"}})

    {:ok, body} = Engine.read(org_id, :page, page.id, :json)
    assert body["custom_fields"]["tier"] == "pro"

    document = SchemaExport.json_schema(org_id: org_id)

    assert JsonSchemaValidator.validate(body, document["$defs"]["content_page"], document) == :ok
  end

  test "the validator is not vacuous — a wrong artifact fails" do
    org_id = KilnCMS.Accounts.default_org_id()
    document = SchemaExport.json_schema(org_id: org_id)
    schema = document["$defs"]["content_page"]

    body = %{
      "id" => Ash.UUID.generate(),
      "type" => "page",
      "title" => "T",
      "slug" => "s",
      "custom_fields" => %{},
      "blocks" => [%{"_type" => "heading", "text" => 7, "level" => "big"}]
    }

    assert {:error, errors} = JsonSchemaValidator.validate(body, schema, document)
    assert Enum.any?(errors, &(&1 =~ "oneOf"))
  end
end
