defmodule KilnCMS.CMS.PrivateFieldsTest do
  @moduledoc """
  Private custom fields and `:user` fields (#2044, `KilnCMS.CMS.PrivateFields`):
  a private value reaches the site's editors and admins and nobody else —
  not the fired artifacts, not a read below editor, not a filter, not
  anything derived from it for the public.
  """
  use KilnCMSWeb.ConnCase, async: true

  alias KilnCMS.CMS

  @accept "application/vnd.api+json"
  @password "password123456"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "private-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp token(user) do
    strategy = AshAuthentication.Info.strategy!(KilnCMS.Accounts.User, :password)

    {:ok, signed_in} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => user.email,
        "password" => @password
      })

    signed_in.__metadata__.token
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "private-#{uniq()}"

  defp field!(admin, type, attrs) do
    CMS.create_field_definition!(
      Map.merge(%{type_definition_id: type.id, label: "Field", field_type: :string}, attrs),
      actor: admin
    )
  end

  defp field_error(admin, type, attrs) do
    assert {:error, %Ash.Error.Invalid{} = error} =
             CMS.create_field_definition(
               Map.merge(
                 %{type_definition_id: type.id, name: "f#{uniq()}", label: "F"},
                 attrs
               ),
               actor: admin
             )

    Exception.message(error)
  end

  defp entry!(admin, type, custom_fields, attrs \\ %{}) do
    admin
    |> then(
      &CMS.create_entry!(
        Map.merge(
          %{title: "Profile #{uniq()}", slug: slug(), type_definition_id: type.id},
          Map.put(attrs, :custom_fields, custom_fields)
        ),
        actor: &1
      )
    )
    |> CMS.publish_entry!(actor: admin)
  end

  defp artifact(conn, type, entry) do
    conn |> get("/api/content/#{type.name}/#{entry.slug}") |> json_response(200)
  end

  defp api_get(path, token \\ nil) do
    conn = put_req_header(build_conn(), "accept", @accept)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    conn = get(conn, path)
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  setup do
    admin = user(:admin)

    type =
      CMS.create_type_definition!(%{name: "profile#{uniq()}", label: "Profile"}, actor: admin)

    secret = field!(admin, type, %{name: "secret", label: "Secret", private: true})
    public = field!(admin, type, %{name: "motto", label: "Motto"})
    %{admin: admin, type: type, secret: secret, public: public}
  end

  describe "the definition" do
    test "only a plain top-level type can be private", %{admin: admin, type: type} do
      assert field_error(admin, type, %{field_type: :media, private: true}) =~
               "is not available for a media field"

      assert field_error(admin, type, %{
               field_type: :reference,
               target_type: "page",
               private: true
             }) =~ "is not available for a reference field"

      reference =
        field!(admin, type, %{
          name: "links",
          field_type: :reference,
          target_type: "page",
          multiple: true
        })

      assert {:error, error} =
               CMS.create_field_definition(
                 %{link_of_id: reference.id, name: "role", label: "Role", private: true},
                 actor: admin
               )

      assert Exception.message(error) =~ "only for a top-level field"
    end

    test "nothing that copies the value somewhere public goes with it",
         %{admin: admin, type: type} do
      assert field_error(admin, type, %{private: true, searchable: true}) =~ "can't be searchable"

      assert field_error(admin, type, %{private: true, names_record: true}) =~
               "can't be a name of the record"

      assert field_error(admin, type, %{field_type: :text, private: true, deliver_plain: true}) =~
               "can't be delivered as plain text"

      assert field_error(admin, type, %{private: true, localization: :fallback}) =~
               "can't inherit from another locale"
    end

    test "a :user field is always private", %{admin: admin, type: type} do
      field = field!(admin, type, %{name: "owner", field_type: :user, private: false})
      assert field.private == true
    end
  end

  describe "delivery" do
    test "the fired artifact leaves a private value out", ctx do
      entry = entry!(ctx.admin, ctx.type, %{"secret" => "hidden", "motto" => "shown"})
      KilnCMS.DataCase.drain_oban()

      fields = artifact(ctx.conn, ctx.type, entry)["custom_fields"]
      assert fields == %{"motto" => "shown"}

      # Stored whole: only what is delivered changes.
      assert CMS.get_entry!(entry.id, actor: ctx.admin).custom_fields["secret"] == "hidden"
    end

    test "a computed field cannot read a private value", ctx do
      field!(ctx.admin, ctx.type, %{
        name: "echo",
        label: "Echo",
        field_type: :computed,
        compute: "[{{ secret }}]"
      })

      entry = entry!(ctx.admin, ctx.type, %{"secret" => "hidden"})
      KilnCMS.DataCase.drain_oban()

      refute inspect(artifact(ctx.conn, ctx.type, entry)) =~ "hidden"
      refute inspect(CMS.get_entry!(entry.id, actor: ctx.admin).custom_fields["echo"]) =~ "hidden"
    end

    test "making a field private re-fires its type", ctx do
      entry = entry!(ctx.admin, ctx.type, %{"motto" => "shown"})
      KilnCMS.DataCase.drain_oban()
      assert artifact(ctx.conn, ctx.type, entry)["custom_fields"]["motto"] == "shown"

      CMS.update_field_definition!(ctx.public, %{private: true}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()

      refute Map.has_key?(artifact(build_conn(), ctx.type, entry)["custom_fields"], "motto")
    end

    test "SEO and slug patterns read a private field as empty", ctx do
      CMS.update_type_definition!(
        ctx.type,
        %{seo_title_pattern: "X [title] [field:secret]", slug_pattern: "[title]-[field:secret]"},
        actor: ctx.admin
      )

      entry =
        ctx.admin
        |> then(
          &CMS.create_entry!(
            %{
              title: "Ada",
              type_definition_id: ctx.type.id,
              custom_fields: %{"secret" => "hidden"}
            },
            actor: &1
          )
        )

      refute entry.slug =~ "hidden"
      refute KilnCMS.Seo.Patterns.effective(entry, :seo_title) =~ "hidden"
    end

    test "the schema export does not describe a private field", ctx do
      fields =
        KilnCMS.SchemaExport.json_schema(org_id: KilnCMS.Accounts.default_org_id())
        |> get_in(["$defs", KilnCMS.SchemaExport.content_def_name(ctx.type.name)])
        |> get_in(["properties", "custom_fields", "properties"])

      assert Map.has_key?(fields, "motto")
      refute Map.has_key?(fields, "secret")
    end
  end

  describe "reads" do
    setup ctx do
      %{entry: entry!(ctx.admin, ctx.type, %{"secret" => "hidden", "motto" => "shown"})}
    end

    defp entry_fields({200, %{"data" => [%{"attributes" => %{"custom_fields" => fields}}]}}),
      do: fields

    test "JSON:API leaves it out below editor, and keeps it for an editor", ctx do
      path =
        "/api/json/entries/published?filter[type_name]=#{ctx.type.name}&fields[entry]=custom_fields"

      assert entry_fields(api_get(path)) == %{"motto" => "shown"}
      assert entry_fields(api_get(path, token(user(:viewer)))) == %{"motto" => "shown"}

      assert entry_fields(api_get(path, token(user(:editor)))) == %{
               "motto" => "shown",
               "secret" => "hidden"
             }
    end

    test "GraphQL leaves it out below editor", ctx do
      query = """
      query ($slug: String!, $type: ID!) {
        entryBySlug(slug: $slug, locale: "en", typeDefinitionId: $type) { customFields }
      }
      """

      run = fn actor ->
        {:ok, %{data: %{"entryBySlug" => %{"customFields" => json}}}} =
          Absinthe.run(query, KilnCMSWeb.GraphqlSchema,
            variables: %{"slug" => ctx.entry.slug, "type" => ctx.type.id},
            context: %{actor: actor}
          )

        Jason.decode!(json)
      end

      assert run.(nil) == %{"motto" => "shown"}
      assert run.(user(:editor))["secret"] == "hidden"
    end

    test "custom_filter and custom_sort cannot probe it below editor", ctx do
      base = "/api/json/entries/published?filter[type_name]=#{ctx.type.name}"

      assert {400, _} = api_get(base <> "&custom_filter[secret]=hidden")
      assert {400, _} = api_get(base <> "&custom_sort=secret")

      assert {200, %{"data" => [_]}} =
               api_get(base <> "&custom_filter[secret]=hidden", token(user(:editor)))
    end
  end

  describe "a :user field" do
    setup ctx do
      %{owner: field!(ctx.admin, ctx.type, %{name: "owner", label: "Owner", field_type: :user})}
    end

    test "names one of the site's people, by id", ctx do
      editor = user(:editor)

      entry = entry!(ctx.admin, ctx.type, %{"owner" => editor.id})
      assert entry.custom_fields["owner"] == editor.id

      assert {:error, error} =
               CMS.create_entry(
                 %{
                   title: "Nobody",
                   slug: slug(),
                   type_definition_id: ctx.type.id,
                   custom_fields: %{"owner" => Ash.UUID.generate()}
                 },
                 actor: ctx.admin
               )

      assert Exception.message(error) =~ "must be a person on this site"
    end

    test "is never delivered", ctx do
      entry = entry!(ctx.admin, ctx.type, %{"owner" => ctx.admin.id})
      KilnCMS.DataCase.drain_oban()

      refute Map.has_key?(artifact(ctx.conn, ctx.type, entry)["custom_fields"], "owner")
    end
  end
end
