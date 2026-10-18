defmodule Mix.Tasks.Kiln.Gen.JoinTest do
  @moduledoc """
  `mix kiln.gen.join` (R10 in `docs/relationships-plan.md`): the typed join
  resource it generates for a `:reference` field, its code interfaces, the
  data migration of its second run, and the fields it refuses.

  Not async: the codemod's `:ash_domains` app-env fixture is VM-global (see
  `Mix.Tasks.Kiln.Gen.ContentTest`).
  """
  use KilnCMS.DataCase, async: false

  import Igniter.Test

  alias KilnCMS.CMS
  alias Mix.Tasks.Kiln.Gen.Join

  setup do
    Application.put_env(:test, :ash_domains, [KilnCMS.CMS])
    on_exit(fn -> Application.delete_env(:test, :ash_domains) end)

    igniter =
      test_project(
        files: %{
          "config/config.exs" => """
          import Config
          config :test, ash_domains: [KilnCMS.CMS]
          """,
          "lib/kiln_cms/cms.ex" => """
          defmodule KilnCMS.CMS do
            use Ash.Domain, otp_app: :test

            resources do
            end
          end
          """
        }
      )

    admin = admin!()
    name = "ingredients#{System.unique_integer([:positive])}"

    field =
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: name,
          label: "Ingredients",
          field_type: :reference,
          target_type: "page",
          multiple: true
        },
        actor: admin
      )

    for {attrs, position} <- [
          {%{name: "quantity", label: "Quantity", field_type: :integer, required: true}, 0},
          {%{
             name: "role",
             label: "Role",
             field_type: :select,
             options: ["main", "garnish"],
             default: "main"
           }, 1},
          {%{name: "added_on", label: "Added on", field_type: :date}, 2}
        ] do
      CMS.create_field_definition!(Map.merge(attrs, %{link_of_id: field.id, position: position}),
        actor: admin
      )
    end

    {:ok, igniter: igniter, admin: admin, name: name}
  end

  defp admin! do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "gen-join-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp module_path(name), do: "lib/kiln_cms/cms/post_#{name}_link.ex"

  # The generated file as written, formatted, without the diff's line gutter.
  defp content(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

  describe "the resource" do
    test "is a typed join resource between the field's two types", ctx do
      igniter = Igniter.compose_task(ctx.igniter, "kiln.gen.join", ["post.#{ctx.name}"])

      assert_creates(igniter, module_path(ctx.name))
      patch = diff(igniter, only: module_path(ctx.name))

      assert patch =~ ~s{table("post_#{ctx.name}_links")}
      assert patch =~ "belongs_to :source, KilnCMS.CMS.Post do"
      assert patch =~ "belongs_to :target, KilnCMS.CMS.Page do"
      assert patch =~ "reference(:source, on_delete: :delete)"
      assert patch =~ "reference(:target, on_delete: :delete)"
      assert patch =~ "index([:target_id])"
      assert patch =~ "identity(:unique_connection, [:source_id, :target_id])"
    end

    test "turns each link field into a typed attribute, required and defaulted as it is", ctx do
      igniter = Igniter.compose_task(ctx.igniter, "kiln.gen.join", ["post.#{ctx.name}"])
      patch = content(igniter, module_path(ctx.name))

      assert patch =~ ~r/attribute :quantity, :integer do\s+allow_nil\?\(false\)/
      assert patch =~ ~r/attribute :role, :string do\s+allow_nil\?\(true\)\s+default\("main"\)/
      assert patch =~ "attribute :added_on, :date do"
      assert patch =~ ~s{validate(one_of(:role, ["main", "garnish"]))}
      assert patch =~ "attribute :position, :integer do"
    end

    test "has the content read rule as policies", ctx do
      patch =
        ctx.igniter
        |> Igniter.compose_task("kiln.gen.join", ["post.#{ctx.name}"])
        |> diff(only: module_path(ctx.name))

      assert patch =~ "authorizers: [Ash.Policy.Authorizer]"
      assert patch =~ "bypass KilnCMS.CMS.Checks.OrgAdmin do"
      assert patch =~ "authorize_if(KilnCMS.CMS.Checks.OrgEditor)"
      assert patch =~ "authorize_if(KilnCMS.CMS.Checks.LinkEndsReadable)"
      assert patch =~ "forbid_if(KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess)"
      assert patch =~ "strategy(:attribute)"
    end

    test "registers the resource and its code interfaces on the domain", ctx do
      igniter = Igniter.compose_task(ctx.igniter, "kiln.gen.join", ["post.#{ctx.name}"])
      patch = diff(igniter, only: "lib/kiln_cms/cms.ex")
      base = "post_#{ctx.name}_link"

      assert patch =~ "resource(KilnCMS.CMS.Post#{Macro.camelize(ctx.name)}Link) do"
      assert patch =~ "define(:list_#{base}s, action: :read)"
      assert patch =~ "define(:list_#{base}s_from, action: :from_source, args: [:source_id])"
      assert patch =~ "define(:list_#{base}s_to, action: :to_target, args: [:target_id])"
      assert patch =~ "define(:create_#{base}, action: :create)"
      assert patch =~ "define(:destroy_#{base}, action: :destroy)"
    end

    test "--module names the resource", ctx do
      ctx.igniter
      |> Igniter.compose_task("kiln.gen.join", [
        "post.#{ctx.name}",
        "--module",
        "KilnCMS.CMS.RecipeIngredient"
      ])
      |> assert_creates("lib/kiln_cms/cms/recipe_ingredient.ex")
    end

    test "points a dynamic type's end at the shared Entry resource", ctx do
      type = "recipe#{System.unique_integer([:positive])}"

      definition =
        CMS.create_type_definition!(%{name: type, label: "Recipe"}, actor: ctx.admin)

      CMS.create_field_definition!(
        %{
          type_definition_id: definition.id,
          name: "pairs_with",
          label: "Pairs with",
          field_type: :reference,
          target_type: "page"
        },
        actor: ctx.admin
      )

      path = "lib/kiln_cms/cms/#{type}_pairs_with_link.ex"

      patch =
        ctx.igniter
        |> Igniter.compose_task("kiln.gen.join", ["#{type}.pairs_with"])
        |> diff(only: path)

      assert patch =~ "belongs_to :source, KilnCMS.CMS.Entry do"
      assert patch =~ "belongs_to :target, KilnCMS.CMS.Page do"
    end

    test "the generated module compiles to an Ash resource with those attributes", ctx do
      {:ok, spec} = KilnCMS.CMS.JoinGraduation.resolve("post.#{ctx.name}")
      module = Module.concat(KilnCMS.CMS, "GenJoinProbe#{System.unique_integer([:positive])}")

      source = "defmodule #{inspect(module)} do\n#{Join.resource_body(spec)}\nend\n"

      {compiled, _warnings} =
        ExUnit.CaptureIO.with_io(:stderr, fn -> Code.compile_string(source) end)

      assert module in Enum.map(compiled, &elem(&1, 0))

      assert Ash.Resource.Info.resource?(module)
      assert Ash.Resource.Info.attribute(module, :quantity).type == Ash.Type.Integer
      refute Ash.Resource.Info.attribute(module, :quantity).allow_nil?
      assert Ash.Resource.Info.attribute(module, :role).default == "main"
      assert Ash.Resource.Info.attribute(module, :added_on).type == Ash.Type.Date

      assert Ash.Resource.Info.identity(module, :unique_connection).keys == [
               :source_id,
               :target_id
             ]

      assert Ash.Resource.Info.relationship(module, :source).destination == KilnCMS.CMS.Post
      assert Ash.DataLayer.data_layer(module) == AshPostgres.DataLayer
    end
  end

  describe "--data-migration" do
    test "is refused until the resource exists", ctx do
      ctx.igniter
      |> Igniter.compose_task("kiln.gen.join", ["post.#{ctx.name}", "--data-migration"])
      |> assert_has_issue(&(&1 =~ "does not exist yet"))
    end

    test "writes a migration that copies the field's edges with their link values", ctx do
      igniter =
        ctx.igniter
        |> Igniter.compose_task("kiln.gen.join", ["post.#{ctx.name}"])
        |> apply_igniter!()
        |> Igniter.compose_task("kiln.gen.join", ["post.#{ctx.name}", "--data-migration"])

      [path] =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.map(& &1.path)
        |> Enum.filter(&String.ends_with?(&1, "_copy_post_#{ctx.name}_links.exs"))

      assert path =~ ~r"^priv/repo/migrations/\d{14}_copy_post_"
      patch = diff(igniter, only: path)

      assert patch =~ "defmodule KilnCMS.Repo.Migrations.CopyPost"
      assert patch =~ ~s(INSERT INTO "post_#{ctx.name}_links")
      assert patch =~ "cl.field = '#{ctx.name}'"
      assert patch =~ "cl.source_type = 'post' AND cl.target_type = 'page'"
      assert patch =~ ~s{COALESCE(CASE WHEN jsonb_typeof(cl.metadata->'role') = 'string'}
      assert patch =~ "ON CONFLICT DO NOTHING"
      assert patch =~ "def down"
    end
  end

  describe "refuses" do
    test "a field that is not a reference", ctx do
      CMS.create_field_definition!(
        %{content_type: :post, name: "subtitle_r10", label: "Subtitle"},
        actor: ctx.admin
      )

      assert_raise Mix.Error, ~r/is a string field; only a reference field/, fn ->
        Igniter.compose_task(ctx.igniter, "kiln.gen.join", ["post.subtitle_r10"])
      end
    end

    test "a reference to several target types", ctx do
      CMS.create_field_definition!(
        %{
          content_type: :post,
          name: "mentions_r10",
          label: "Mentions",
          field_type: :reference,
          target_types: ["page", "post"],
          multiple: true
        },
        actor: ctx.admin
      )

      assert_raise Mix.Error, ~r/links to several types \(page, post\)/, fn ->
        Igniter.compose_task(ctx.igniter, "kiln.gen.join", ["post.mentions_r10"])
      end
    end

    test "an unknown field, an unknown type and a malformed argument", ctx do
      assert_raise Mix.Error, ~r/post has no field named "nope"/, fn ->
        Igniter.compose_task(ctx.igniter, "kiln.gen.join", ["post.nope"])
      end

      assert_raise Mix.Error, ~r/no content type named "nosuchtype"/, fn ->
        Igniter.compose_task(ctx.igniter, "kiln.gen.join", ["nosuchtype.x"])
      end

      assert_raise Mix.Error, ~r/expected <type>.<field>/, fn ->
        Igniter.compose_task(ctx.igniter, "kiln.gen.join", [ctx.name])
      end
    end

    test "an unknown --org", ctx do
      assert_raise Mix.Error, ~r/no organization with slug "no-such-org"/, fn ->
        Igniter.compose_task(ctx.igniter, "kiln.gen.join", [
          "post.#{ctx.name}",
          "--org",
          "no-such-org"
        ])
      end
    end
  end
end
