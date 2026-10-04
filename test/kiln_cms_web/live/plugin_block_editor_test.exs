defmodule KilnCMSWeb.PluginBlockEditorTest do
  @moduledoc """
  The authoring seams a plugin block gets without a core edit, via the
  fixture plugin's `checklist` block:

    * the inserter shows its own `label/0`, `icon/0` and `description/0`;
    * a field's `description:` is the input's hint;
    * an `{:array, :map}` field declaring `item_keys:` is edited as rows —
      one input per key — through the same add/remove events and param
      normalization as the core faq/how_to/accordion rows;
    * live delivery and previews render it with its own `:web` serializer
      instead of an empty paragraph.
  """
  use KilnCMSWeb.ConnCase, async: true
  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.Page
  alias KilnCMSWeb.BlockComponents
  alias KilnCMSWeb.ContentEditor.BlockParams

  @password "password123456"

  defp editor do
    email = "pbe-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :editor
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(strategy, :sign_in, %{
        "email" => email,
        "password" => @password
      })

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp draft_page(attrs) do
    Ash.Seed.seed!(
      Page,
      Map.merge(
        %{title: "A page", slug: "pbe-#{System.unique_integer([:positive])}", state: :draft},
        attrs
      )
    )
  end

  describe "editor metadata" do
    test "the inserter uses the block's own label, icon and description", %{conn: conn} do
      page = draft_page(%{blocks: []})
      {:ok, lv, _html} = conn |> log_in(editor()) |> live(~p"/editor/content/page/#{page.id}")

      item = element(lv, "#block-inserter button[data-inserter-item][phx-value-type='checklist']")
      html = render(item)

      assert html =~ "Checklist"
      assert html =~ "Tasks with an owner each"
      assert html =~ "hero-check-circle"
    end

    test "a block without metadata keeps the defaults" do
      assert KilnCMS.Blocks.editor_meta("callout", :label) == nil
      assert KilnCMSWeb.ContentEditorLive.block_description("callout") == "Insert a block"
      assert KilnCMS.Blocks.editor_meta("no_such_block", :label) == nil
    end
  end

  describe "declared rows (item_keys:)" do
    test "declared_row_fields/1 reads item_keys, and never shadows a core row editor" do
      assert BlockParams.declared_row_fields("checklist") == [{"items", ["task", "owner"]}]
      assert BlockParams.declared_row_fields("faq") == []
      assert BlockParams.declared_row_fields("callout") == []
      assert BlockParams.row_field?("checklist", "items")
      refute BlockParams.row_field?("checklist", "title")
      refute BlockParams.row_field?("callout", "items")
    end

    test "rows add, edit and persist through save; the field hint shows", %{conn: conn} do
      page = draft_page(%{blocks: []})
      {:ok, lv, _html} = conn |> log_in(editor()) |> live(~p"/editor/content/page/#{page.id}")

      lv
      |> element("#block-inserter button[data-inserter-item][phx-value-type='checklist']")
      |> render_click()

      assert render(lv) =~ "Shown above the list."

      lv
      |> element("button[phx-click='item_row_add'][phx-value-index='0'][phx-value-field='items']")
      |> render_click()

      assert has_element?(
               lv,
               ~s(fieldset[data-row-field="items"] input[name$="[items][0][task]"])
             )

      assert has_element?(
               lv,
               ~s(fieldset[data-row-field="items"] input[name$="[items][0][owner]"])
             )

      lv
      |> form("#page-editor")
      |> render_change(%{
        "form" => %{
          "blocks" => %{
            "0" => %{
              "title" => "Launch",
              "items" => %{"0" => %{"task" => "Write copy", "owner" => "Ana"}}
            }
          }
        }
      })

      lv |> form("#page-editor") |> render_submit()

      assert [%Ash.Union{type: :checklist, value: block}] =
               CMS.get_page!(page.id, authorize?: false).blocks

      assert block.title == "Launch"
      assert block.items == [%{"task" => "Write copy", "owner" => "Ana"}]
    end

    test "a row event naming a field the block does not edit as rows is ignored", %{conn: conn} do
      page = draft_page(%{blocks: [%{"_type" => "checklist", "title" => "T", "items" => []}]})
      {:ok, lv, _html} = conn |> log_in(editor()) |> live(~p"/editor/content/page/#{page.id}")

      render_hook(lv, "item_row_add", %{"index" => "0", "field" => "title"})
      lv |> form("#page-editor") |> render_submit()

      assert [%Ash.Union{value: %{title: "T"}}] = CMS.get_page!(page.id, authorize?: false).blocks
    end
  end

  describe "schema" do
    test "item_keys derive an item object schema" do
      schema = Kiln.Block.JsonSchema.for_module(KilnCMS.FixturePlugin.ChecklistBlock)
      items = schema["properties"]["items"]

      assert items["items"]["properties"] == %{
               "task" => %{"type" => "string"},
               "owner" => %{"type" => "string"}
             }

      assert items["items"]["additionalProperties"] == false

      assert Kiln.Block.Info.item_keys(KilnCMS.FixturePlugin.ChecklistBlock) == [
               items: [:task, :owner]
             ]
    end

    test "item_keys on anything but an {:array, :map} field is a compile error" do
      source = """
      defmodule KilnCMSWeb.PluginBlockEditorTest.BadItemKeys do
        use Kiln.Block

        block :bad_item_keys do
          field :title, :string, item_keys: [:a]
        end
      end
      """

      error = assert_raise RuntimeError, fn -> Code.compile_string(source) end
      assert Exception.message(error) =~ "only a non-empty list on an {:array, :map} field"
    end
  end

  describe "live delivery" do
    test "a plugin block renders with its own :web serializer, not an empty paragraph" do
      [view] =
        BlockComponents.view_blocks([
          %{"_type" => "checklist", "items" => [%{"task" => "A & B"}]}
        ])

      html = render_component(&BlockComponents.render_block/1, block: view)

      assert html =~ ~s(<ul class="checklist"><li>A &amp; B</li></ul>)
      refute html =~ "<p></p>"
    end
  end
end
