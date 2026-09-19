defmodule Mix.Tasks.Kiln.Gen.ContentTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Mix.Tasks.Kiln.Gen.Content

  describe "interfaces/3" do
    test "builds the standard CMS.* interface set" do
      names = Content.interfaces(:product, "products", []) |> Enum.map(&elem(&1, 0))

      assert :list_products in names
      assert :get_product in names
      assert :create_product in names
      assert :publish_product in names
      assert :restore_product_version in names
      assert :purge_product in names
      # No `:published` read unless requested.
      refute :list_published_products in names
    end

    test "adds the published-index interface only with --published" do
      names = Content.interfaces(:post, "posts", published: true) |> Enum.map(&elem(&1, 0))
      assert :list_published_posts in names
    end

    test "uses the plural for collection interfaces" do
      defs = Content.interfaces(:category, "categories", []) |> Map.new()
      assert defs[:list_categories] == "define :list_categories, action: :read"
      assert defs[:get_category] == "define :get_category, action: :read, get_by: [:id]"
    end
  end

  describe "resource_body/3" do
    test "uses the Content base with the requested flags" do
      body = Content.resource_body(KilnCMS.CMS.Product, :product, excerpt: true, published: true)
      assert body =~ "use KilnCMS.CMS.Content, type: :product, excerpt?: true, published?: true"
      assert body =~ "@moduledoc"
    end

    test "omits flags that weren't requested" do
      body = Content.resource_body(KilnCMS.CMS.Page, :page, [])
      assert body =~ "use KilnCMS.CMS.Content, type: :page\n"
      refute body =~ "excerpt?"
    end
  end

  describe "the generator codemod" do
    setup do
      # `Ash.Domain.Igniter.list_domains/1` takes a fast path when the app env
      # answers: `Application.get_env(app, :ash_domains)` plus a scan of the
      # *changed* sources only, and a `test_project/1` fixture counts as
      # neither. Up to igniter 0.8.3 evaluating the fixture's `config.exs`
      # left `config :test, ash_domains:` in the real app env, so the fast
      # path found the domain by accident; 0.8.4 restores the env after
      # evaluating project config (igniter #400), the fast path returns `[]`,
      # and the codemod took the "plain module, upgrade it to a domain" branch
      # — a second `use Ash.Domain` and a second `resources do` block. Give the
      # fast path what production has: the compiled `:ash_domains` config.
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

      {:ok, igniter: igniter}
    end

    test "creates the resource module on the Content base", %{igniter: igniter} do
      igniter
      |> Igniter.compose_task("kiln.gen.content", ["Product", "--excerpt", "--published"])
      |> assert_creates(
        "lib/kiln_cms/cms/product.ex",
        """
        defmodule KilnCMS.CMS.Product do
          @moduledoc \"\"\"
          A Product — a KilnCMS content type. All of its behaviour (block editor,
          publishing workflow, version history, search, SEO, and the standard
          relationships) comes from `KilnCMS.CMS.Content`; add only what is unique to
          a Product below.
          \"\"\"
          use KilnCMS.CMS.Content, type: :product, excerpt?: true, published?: true
        end
        """
      )
    end

    test "registers the resource + interfaces on the domain", %{igniter: igniter} do
      igniter =
        Igniter.compose_task(igniter, "kiln.gen.content", ["Product", "--excerpt", "--published"])

      patch = diff(igniter)

      assert patch =~ "resource(KilnCMS.CMS.Product) do"
      assert patch =~ "define(:create_product, action: :create)"
      assert patch =~ "define(:list_published_products, action: :published)"
      assert patch =~ "resource(KilnCMS.CMS.Product.Version) do"
      assert patch =~ "define(:list_product_versions, action: :read)"
    end
  end
end
