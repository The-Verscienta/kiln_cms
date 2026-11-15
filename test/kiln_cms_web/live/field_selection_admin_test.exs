defmodule KilnCMSWeb.FieldSelectionAdminTest do
  @moduledoc """
  The fields admin's "Which records can be picked" step (#2285, part 3): the
  inputs build the field's `selection`, the resource's own refusals show under
  the step, a stored selection round-trips untouched, and a sentence reads the
  setting back.
  """
  use KilnCMSWeb.ConnCase, async: true

  @moduletag :capture_log

  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMSWeb.FieldSelection

  @password "password123456"

  defp authed_user(role) do
    email = "sel-admin-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: role
    })

    strategy = AshAuthentication.Info.strategy!(User, :password)

    {:ok, user} =
      AshAuthentication.Strategy.action(
        strategy,
        :sign_in,
        %{"email" => email, "password" => @password},
        []
      )

    user
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp uniq, do: System.unique_integer([:positive])

  defp reference!(admin, attrs \\ %{}) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: "rel_#{uniq()}",
          label: "Related",
          field_type: :reference,
          target_type: "page"
        },
        attrs
      ),
      actor: admin
    )
  end

  defp open_edit(conn, admin, field) do
    {:ok, lv, _html} = conn |> log_in(admin) |> live(~p"/editor/fields")
    lv |> element("#field-#{field.id} button[phx-click=edit]") |> render_click()
    lv
  end

  defp stored(field), do: CMS.get_field_definition!(field.id, authorize?: false).selection

  setup do
    admin = authed_user(:admin)

    CMS.create_field_definition!(
      %{content_type: :page, name: "level", label: "Level", field_type: :integer},
      actor: admin
    )

    CMS.create_field_definition!(
      %{content_type: :page, name: "featured", label: "Featured", field_type: :boolean},
      actor: admin
    )

    CMS.create_field_definition!(
      %{content_type: :page, name: "secret", label: "Secret", field_type: :string, private: true},
      actor: admin
    )

    %{admin: admin, tag: CMS.create_tag!(%{name: "vegan", slug: "vegan-#{uniq()}"}, actor: admin)}
  end

  describe "editing a field" do
    test "builds the selection from the inputs and reads it back as a sentence", ctx do
      field = reference!(ctx.admin)
      lv = open_edit(build_conn(), ctx.admin, field)
      id = field.id

      html =
        lv
        |> form("#edit-field-#{id}",
          field_definition: %{
            sel: %{
              states: ["published"],
              owner: "self",
              sort: "title",
              by_type: %{"page" => %{tags_any: [ctx.tag.id]}}
            }
          }
        )
        |> render_change()

      assert html =~ "Published Page records, tagged vegan, created by the editor, by title."

      lv |> form("#edit-field-#{id}") |> render_submit()

      assert stored(field) == %{
               "states" => ["published"],
               "owner" => "self",
               "sort" => "title",
               "by_type" => %{"page" => %{"tags_any" => [ctx.tag.id]}}
             }
    end

    test "a field condition is cast to the field's type and offered only for plain fields", ctx do
      field = reference!(ctx.admin)
      lv = open_edit(build_conn(), ctx.admin, field)
      id = field.id
      step = "#edit-field-rules-#{id}-selection"

      assert has_element?(lv, "#{step}-type-page label", "Level")
      assert has_element?(lv, "#{step}-type-page label", "Featured")
      refute has_element?(lv, "#{step}-type-page label", "Secret")

      lv
      |> form("#edit-field-#{id}",
        field_definition: %{
          sel: %{
            by_type: %{
              "page" => %{
                fields: %{
                  "level" => %{op: "in", value: "1, 2"},
                  "featured" => %{op: "eq", value: "true"}
                }
              }
            }
          }
        }
      )
      |> render_submit()

      assert stored(field) == %{
               "by_type" => %{
                 "page" => %{"fields" => %{"level" => %{"in" => [1, 2]}, "featured" => true}}
               }
             }
    end

    test "a stored selection the inputs can express saves back unchanged", ctx do
      selection = %{
        "states" => ["draft", "published"],
        "by_type" => %{
          "page" => %{
            "tags_any" => [ctx.tag.id],
            "fields" => %{"level" => %{"not_eq" => 3}, "featured" => false}
          }
        }
      }

      field = reference!(ctx.admin, %{selection: selection})
      lv = open_edit(build_conn(), ctx.admin, field)
      lv |> form("#edit-field-#{field.id}") |> render_submit()

      assert stored(field) == selection
    end

    test "clearing every input clears the selection", ctx do
      field = reference!(ctx.admin, %{selection: %{"states" => ["published"]}})
      lv = open_edit(build_conn(), ctx.admin, field)

      lv
      |> form("#edit-field-#{field.id}", field_definition: %{sel: %{states: []}})
      |> render_submit()

      assert stored(field) == nil
    end

    test "turning the relationship into a plain value clears its selection", ctx do
      field = reference!(ctx.admin, %{selection: %{"states" => ["published"]}})
      lv = open_edit(build_conn(), ctx.admin, field)

      lv
      |> form("#edit-field-#{field.id}", field_definition: %{kind: "value"})
      |> render_change()

      lv |> form("#edit-field-#{field.id}") |> render_submit()

      saved = CMS.get_field_definition!(field.id, authorize?: false)
      assert {saved.field_type, saved.selection} == {:string, nil}
    end

    test "the resource's refusal shows under the step and saves nothing", ctx do
      field = reference!(ctx.admin)
      lv = open_edit(build_conn(), ctx.admin, field)
      id = field.id

      html =
        lv
        |> form("#edit-field-#{id}",
          field_definition: %{
            sel: %{by_type: %{"page" => %{fields: %{"level" => %{op: "eq", value: "high"}}}}}
          }
        )
        |> render_submit()

      assert html =~ "must be a whole number"
      assert has_element?(lv, "#edit-field-rules-#{id}-selection p.text-error", "level")
      assert stored(field) == nil
    end

    test "a condition on a tag that is gone is kept and flagged, not dropped", ctx do
      gone = CMS.create_tag!(%{name: "gone", slug: "gone-#{uniq()}"}, actor: ctx.admin)

      field =
        reference!(ctx.admin, %{
          selection: %{"by_type" => %{"page" => %{"tags_any" => [gone.id]}}}
        })

      CMS.destroy_tag!(gone, actor: ctx.admin)
      lv = open_edit(build_conn(), ctx.admin, field)

      assert render(lv) =~ "(not found)"
    end

    test "ticking a second target type adds its block; unticking drops its conditions", ctx do
      field = reference!(ctx.admin)
      lv = open_edit(build_conn(), ctx.admin, field)
      id = field.id
      block = "#edit-field-rules-#{id}-selection-type-post"

      refute has_element?(lv, block)

      lv
      |> form("#edit-field-#{id}",
        field_definition: %{target_types: ["page", "post"]}
      )
      |> render_change()

      assert has_element?(lv, block)

      lv
      |> form("#edit-field-#{id}",
        field_definition: %{
          target_types: ["page", "post"],
          sel: %{by_type: %{"post" => %{tags_any: [ctx.tag.id]}}}
        }
      )
      |> render_change()

      lv
      |> form("#edit-field-#{id}", field_definition: %{target_types: ["page"]})
      |> render_submit()

      assert stored(field) == nil
    end
  end

  describe "adding a field" do
    test "a new relationship can carry a selection", ctx do
      {:ok, lv, _html} = build_conn() |> log_in(ctx.admin) |> live(~p"/editor/fields")
      name = "new_rel_#{uniq()}"

      lv
      |> form("#new-field-form", field_definition: %{kind: "relationship"})
      |> render_change()

      lv
      |> form("#new-field-form",
        field_definition: %{
          label: "New rel",
          name: name,
          scopes: ["post"],
          target_types: ["page"],
          sel: %{states: ["published"]}
        }
      )
      |> render_submit()

      field =
        CMS.list_field_definitions!(actor: ctx.admin)
        |> Enum.find(&(&1.name == name))

      assert field.selection == %{"states" => ["published"]}
    end
  end

  describe "FieldSelection.unpack/3" do
    @catalog %{"page" => [%{name: "level", field_type: :integer}]}

    test "leaves params without the step alone" do
      assert FieldSelection.unpack(%{"label" => "x"}, ["page"], @catalog) == %{"label" => "x"}
    end

    test "drops the rows of a non-relationship and clears the selection" do
      params = %{"field_type" => "string", "sel" => %{"states" => ["draft"]}}

      assert FieldSelection.unpack(params, [], @catalog) == %{
               "field_type" => "string",
               "selection" => nil
             }
    end

    test "drops types that are not targets and blank rows" do
      params = %{
        "field_type" => "reference",
        "sel" => %{
          "_" => "1",
          "by_type" => %{
            "post" => %{"tags_any" => ["x"]},
            "page" => %{"fields" => %{"level" => %{"op" => "eq", "value" => " "}}}
          }
        }
      }

      assert %{"selection" => nil} = FieldSelection.unpack(params, ["page"], @catalog)
    end
  end
end
