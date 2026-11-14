defmodule KilnCMS.CMS.ReferenceSelectionTest do
  @moduledoc """
  The evaluator and the definition-side rules of a reference field's
  `selection` (#2285, `docs/plans/reference-selection-plan.md`): what a
  selection turns into for a read, what the definition save refuses, and what
  drift leaves inert.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.CMS.ReferenceSelection

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "rs-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "rs-#{System.unique_integer([:positive])}"
  defp name, do: "ref_#{System.unique_integer([:positive])}"

  defp tag!(admin) do
    n = System.unique_integer([:positive])
    CMS.create_tag!(%{name: "Tag #{n}", slug: "t-#{n}"}, actor: admin)
  end

  defp category!(admin) do
    n = System.unique_integer([:positive])
    CMS.create_category!(%{name: "Cat #{n}", slug: "c-#{n}"}, actor: admin)
  end

  defp field!(admin, attrs) do
    CMS.create_field_definition!(
      Map.merge(
        %{
          content_type: :post,
          name: name(),
          label: "Linked",
          field_type: :reference,
          target_type: "page"
        },
        attrs
      ),
      actor: admin
    )
  end

  defp page_field!(admin, attrs) do
    CMS.create_field_definition!(
      Map.merge(%{content_type: :page, name: "diet", label: "Diet", field_type: :string}, attrs),
      actor: admin
    )
  end

  defp refusal(fun) do
    assert {:error, error} = fun.()
    Exception.message(error)
  end

  setup do
    %{admin: user(:admin)}
  end

  describe "query_for/5" do
    test "no selection, or nothing that filters, is unfiltered", %{admin: admin} do
      assert {:ok, :unfiltered} = ReferenceSelection.query_for(nil, "page", admin, nil)
      assert {:ok, :unfiltered} = ReferenceSelection.query_for(%{}, "page", admin, nil)

      # `sort` shapes the picker's order, never the result set.
      assert {:ok, :unfiltered} =
               ReferenceSelection.query_for(%{"sort" => "title"}, "page", admin, nil)
    end

    test "states become a state filter, keyed by atoms", %{admin: admin} do
      assert {:ok, [filter: [[state: [in: [:published, :draft]]]], arguments: %{}]} =
               ReferenceSelection.query_for(
                 %{"states" => ["published", "draft"]},
                 "page",
                 admin,
                 nil
               )
    end

    test "owner self is the writing user, and nothing for anyone else", %{admin: admin} do
      editor = user(:editor)
      selection = %{"owner" => "self"}

      assert {:ok, [filter: [[author_id: id]], arguments: %{}]} =
               ReferenceSelection.query_for(selection, "page", editor, nil)

      assert id == editor.id

      for actor <- [nil, %{id: editor.id}] do
        assert {:ok, [filter: [match_nothing], arguments: %{}]} =
                 ReferenceSelection.query_for(selection, "page", actor, nil)

        assert inspect(match_nothing) =~ "false"
      end

      # An admin is a user like any other: the filter binds them too.
      assert {:ok, [filter: [[author_id: _]], arguments: %{}]} =
               ReferenceSelection.query_for(selection, "page", admin, nil)
    end

    test "tags_any and category are native filters; fields go in custom_filter", %{admin: admin} do
      tag = tag!(admin)
      category = category!(admin)
      page_field!(admin, %{})

      selection = %{
        "by_type" => %{
          "page" => %{
            "tags_any" => [tag.id],
            "category" => category.id,
            "fields" => %{"diet" => "vegan"}
          }
        }
      }

      assert {:ok, [filter: [_tags, [category_id: category_id]], arguments: arguments]} =
               ReferenceSelection.query_for(selection, "page", admin, nil)

      assert category_id == category.id
      assert arguments == %{custom_filter: %{"diet" => "vegan"}}
    end

    test "a type with no entry is unfiltered, an entry applies to its own type only",
         %{admin: admin} do
      category = category!(admin)
      selection = %{"by_type" => %{"post" => %{"category" => category.id}}}

      assert {:ok, :unfiltered} = ReferenceSelection.query_for(selection, "page", admin, nil)

      assert {:ok, [filter: [[category_id: _]], arguments: %{}]} =
               ReferenceSelection.query_for(selection, "post", admin, nil)
    end

    test "conditions AND: top-level and typed ones are all present", %{admin: admin} do
      category = category!(admin)

      selection = %{
        "states" => ["published"],
        "owner" => "self",
        "by_type" => %{"page" => %{"category" => category.id}}
      }

      assert {:ok, [filter: filters, arguments: %{}]} =
               ReferenceSelection.query_for(selection, "page", admin, nil)

      assert length(filters) == 3
    end

    test "dead entries are dropped, not turned into match-nothing", %{admin: admin} do
      tag = tag!(admin)
      category = category!(admin)
      page_field!(admin, %{})
      ghost = Ecto.UUID.generate()

      selection = %{
        "by_type" => %{
          "page" => %{
            "tags_any" => [tag.id, ghost],
            "category" => ghost,
            "fields" => %{"diet" => "vegan", "gone" => "x"}
          },
          "no_such_type" => %{"category" => category.id}
        }
      }

      assert {:ok, [filter: [_tags], arguments: %{custom_filter: %{"diet" => "vegan"}}]} =
               ReferenceSelection.query_for(selection, "page", admin, nil)

      assert {:ok, :unfiltered} =
               ReferenceSelection.query_for(selection, "no_such_type", admin, nil)

      all_dead = %{"by_type" => %{"page" => %{"category" => ghost, "fields" => %{"gone" => 1}}}}
      assert {:ok, :unfiltered} = ReferenceSelection.query_for(all_dead, "page", admin, nil)
    end

    test "a private field's condition is inert", %{admin: admin} do
      page_field!(admin, %{name: "secret", private: true})
      selection = %{"by_type" => %{"page" => %{"fields" => %{"secret" => "x"}}}}
      assert {:ok, :unfiltered} = ReferenceSelection.query_for(selection, "page", admin, nil)
    end

    test "a system actor and authorize?: false are not bound, a nil actor is", %{admin: admin} do
      selection = %{"owner" => "self", "states" => ["published"]}

      assert {:ok, :unfiltered} =
               ReferenceSelection.query_for(
                 selection,
                 "page",
                 KilnCMS.CMS.Housekeeping.system(:cms_registry),
                 nil
               )

      assert {:ok, :unfiltered} =
               ReferenceSelection.query_for(selection, "page", admin, nil,
                 read_opts: [authorize?: false]
               )

      assert {:ok, [filter: _, arguments: _]} =
               ReferenceSelection.query_for(selection, "page", nil, nil,
                 read_opts: [authorize?: true]
               )
    end

    test "read_opts/2 puts each term in the query and merges the arguments", %{admin: admin} do
      page_field!(admin, %{})

      selection = %{
        "states" => ["draft"],
        "by_type" => %{"page" => %{"fields" => %{"diet" => "a"}}}
      }

      {:ok, plan} = ReferenceSelection.query_for(selection, "page", admin, nil)

      opts = ReferenceSelection.read_opts([actor: admin, arguments: %{x: 1}], plan)
      assert Keyword.fetch!(opts, :arguments) == %{x: 1, custom_filter: %{"diet" => "a"}}
      assert [{:filter, [state: _]}] = Keyword.fetch!(opts, :query)
      assert ReferenceSelection.read_opts([a: 1], :unfiltered) == [a: 1]
    end

    test "the filter runs through the type's own read", %{admin: admin} do
      page_field!(admin, %{})
      tag = tag!(admin)
      category = category!(admin)

      keep =
        CMS.create_page!(
          %{
            title: "Keep",
            slug: slug(),
            tag_ids: [tag.id],
            category_id: category.id,
            custom_fields: %{"diet" => "vegan"}
          },
          actor: admin
        )

      _wrong_diet =
        CMS.create_page!(
          %{
            title: "Wrong diet",
            slug: slug(),
            tag_ids: [tag.id],
            category_id: category.id,
            custom_fields: %{"diet" => "meat"}
          },
          actor: admin
        )

      _untagged =
        CMS.create_page!(
          %{
            title: "Untagged",
            slug: slug(),
            category_id: category.id,
            custom_fields: %{"diet" => "vegan"}
          },
          actor: admin
        )

      selection = %{
        "states" => ["draft"],
        "by_type" => %{
          "page" => %{
            "tags_any" => [tag.id],
            "category" => category.id,
            "fields" => %{"diet" => %{"in" => ["vegan", "raw"]}}
          }
        }
      }

      {:ok, plan} = ReferenceSelection.query_for(selection, "page", admin, nil)
      opts = ReferenceSelection.read_opts([actor: admin], plan)

      assert [found] = ContentTypes.list!("page", opts)
      assert found.id == keep.id

      {:ok, not_eq} =
        ReferenceSelection.query_for(
          %{"by_type" => %{"page" => %{"fields" => %{"diet" => %{"not_eq" => "meat"}}}}},
          "page",
          admin,
          nil
        )

      titles =
        "page"
        |> ContentTypes.list!(ReferenceSelection.read_opts([actor: admin], not_eq))
        |> Enum.map(& &1.title)

      refute "Wrong diet" in titles
      assert "Keep" in titles
    end
  end

  describe "the definition" do
    test "a selection is stored with string keys, and cleared on a non-reference", %{admin: admin} do
      field = field!(admin, %{selection: %{states: [:published], owner: :self}})
      assert field.selection == %{"states" => ["published"], "owner" => "self"}

      empty = field!(admin, %{selection: %{}})
      assert empty.selection == nil

      retyped = CMS.update_field_definition!(field, %{field_type: :string}, actor: admin)
      assert retyped.selection == nil
    end

    test "unknown keys, states, owner and sort are refused", %{admin: admin} do
      for {selection, fragment} <- [
            {%{"surprise" => 1}, "unknown key"},
            {%{"states" => ["gone"]}, "states must be among"},
            {%{"states" => "published"}, "states must be a list"},
            {%{"owner" => "anyone"}, "owner can only be"},
            {%{"sort" => "random"}, "sort must be one of"},
            {%{"by_type" => %{"page" => %{"oops" => 1}}}, "unknown key"}
          ] do
        message =
          refusal(fn ->
            CMS.create_field_definition(
              %{
                content_type: :post,
                name: name(),
                label: "L",
                field_type: :reference,
                target_type: "page",
                selection: selection
              },
              actor: admin
            )
          end)

        assert message =~ fragment, "#{inspect(selection)}: #{message}"
      end
    end

    test "create is refused until a later release", %{admin: admin} do
      message =
        refusal(fn ->
          CMS.create_field_definition(
            %{
              content_type: :post,
              name: name(),
              label: "L",
              field_type: :reference,
              target_type: "page",
              selection: %{"create" => %{"type" => "page"}}
            },
            actor: admin
          )
        end)

      assert message =~ "coming in a later release"
    end

    test "a by_type key must be one of the field's target types", %{admin: admin} do
      category = category!(admin)

      message =
        refusal(fn ->
          CMS.create_field_definition(
            %{
              content_type: :post,
              name: name(),
              label: "L",
              field_type: :reference,
              target_type: "page",
              selection: %{"by_type" => %{"post" => %{"category" => category.id}}}
            },
            actor: admin
          )
        end)

      assert message =~ "names post, which is not one of this field's target types"

      # Narrowing the targets under a condition is refused too.
      field =
        field!(admin, %{
          target_type: nil,
          target_types: ["page", "post"],
          selection: %{"by_type" => %{"post" => %{"category" => category.id}}}
        })

      assert message =
               refusal(fn ->
                 CMS.update_field_definition(field, %{target_types: ["page"]}, actor: admin)
               end)

      assert message =~ "not one of this field's target types"
    end

    test "fields must be non-private equality-capable custom fields of the type",
         %{admin: admin} do
      page_field!(admin, %{})
      page_field!(admin, %{name: "secret", label: "Secret", private: true})
      page_field!(admin, %{name: "body_text", label: "Body", field_type: :text})
      page_field!(admin, %{name: "pic", label: "Pic", field_type: :media})

      page_field!(admin, %{name: "rel", label: "Rel", field_type: :reference, target_type: "post"})

      page_field!(admin, %{name: "where_at", label: "Where", field_type: :geolocation})
      page_field!(admin, %{name: "rank", label: "Rank", field_type: :integer})

      attempt = fn fields ->
        refusal(fn ->
          CMS.create_field_definition(
            %{
              content_type: :post,
              name: name(),
              label: "L",
              field_type: :reference,
              target_type: "page",
              selection: %{"by_type" => %{"page" => %{"fields" => fields}}}
            },
            actor: admin
          )
        end)
      end

      assert attempt.(%{"missing" => "x"}) =~ "which is not a field of page"
      assert attempt.(%{"secret" => "x"}) =~ "a private field"

      for kind <- ~w(body_text pic rel where_at) do
        assert attempt.(%{kind => "x"}) =~ "has no plain value to match"
      end

      assert attempt.(%{"rank" => "many"}) =~ "must be a whole number"
      assert attempt.(%{"rank" => %{"in" => [1, "x"]}}) =~ "must be a whole number"

      ok =
        field!(admin, %{
          selection: %{
            "by_type" => %{
              "page" => %{"fields" => %{"diet" => "vegan", "rank" => %{"in" => [1, 2]}}}
            }
          }
        })

      assert ok.selection["by_type"]["page"]["fields"]["rank"] == %{"in" => [1, 2]}
    end

    test "tag and category ids must exist in the org", %{admin: admin} do
      ghost = Ecto.UUID.generate()

      for {entry, fragment} <- [
            {%{"tags_any" => [ghost]}, "a tag for page that does not exist"},
            {%{"category" => ghost}, "a category for page that does not exist"},
            {%{"tags_any" => ["nope"]}, "tags_any must be a list of ids"}
          ] do
        message =
          refusal(fn ->
            CMS.create_field_definition(
              %{
                content_type: :post,
                name: name(),
                label: "L",
                field_type: :reference,
                target_type: "page",
                selection: %{"by_type" => %{"page" => entry}}
              },
              actor: admin
            )
          end)

        assert message =~ fragment, message
      end
    end

    test "owner and states are for a reference only: anything else drops them", %{admin: admin} do
      parent = field!(admin, %{})

      plain =
        CMS.create_field_definition!(
          %{
            content_type: :post,
            name: name(),
            label: "Plain",
            field_type: :string,
            selection: %{"owner" => "self"}
          },
          actor: admin
        )

      assert plain.selection == nil

      link =
        CMS.create_field_definition!(
          %{
            link_of_id: parent.id,
            name: name(),
            label: "Role",
            field_type: :string,
            selection: %{"states" => ["published"]}
          },
          actor: admin
        )

      assert link.selection == nil
    end

    test "a dynamic type is a valid target, with tags and category", %{admin: admin} do
      dynamic =
        CMS.create_type_definition!(
          %{name: "rs#{System.unique_integer([:positive])}", label: "Product"},
          actor: admin
        )

      tag = tag!(admin)
      category = category!(admin)

      field =
        field!(admin, %{
          target_type: dynamic.name,
          selection: %{
            "by_type" => %{dynamic.name => %{"tags_any" => [tag.id], "category" => category.id}}
          }
        })

      assert field.selection["by_type"][dynamic.name]["category"] == category.id
    end
  end

  describe "drift" do
    test "a named field cannot turn private or lose its equality", %{admin: admin} do
      diet = page_field!(admin, %{})

      field =
        field!(admin, %{
          label: "Pick a dish",
          selection: %{"by_type" => %{"page" => %{"fields" => %{"diet" => "vegan"}}}}
        })

      message =
        refusal(fn -> CMS.update_field_definition(diet, %{private: true}, actor: admin) end)

      assert message =~ "is used by the selection of Pick a dish"

      message =
        refusal(fn -> CMS.update_field_definition(diet, %{field_type: :media}, actor: admin) end)

      assert message =~ "is used by the selection of Pick a dish"

      # Another equality type is fine, so is an unrelated edit.
      assert CMS.update_field_definition!(diet, %{field_type: :url}, actor: admin).field_type ==
               :url

      assert CMS.update_field_definition!(diet, %{label: "Diet kind"}, actor: admin).label ==
               "Diet kind"

      # Once the selection is gone nothing guards it.
      CMS.update_field_definition!(field, %{selection: nil}, actor: admin)
      assert CMS.update_field_definition!(diet, %{private: true}, actor: admin).private
    end

    test "drift never blocks an unrelated edit of the definition", %{admin: admin} do
      gone_tag = tag!(admin)
      diet = page_field!(admin, %{})

      field =
        field!(admin, %{
          selection: %{
            "by_type" => %{
              "page" => %{"tags_any" => [gone_tag.id], "fields" => %{"diet" => "vegan"}}
            }
          }
        })

      CMS.destroy_tag!(gone_tag, actor: admin)
      CMS.destroy_field_definition!(diet, actor: admin)

      assert CMS.update_field_definition!(field, %{label: "Relabeled"}, actor: admin).label ==
               "Relabeled"

      # Rewriting the selection is judged again.
      message =
        refusal(fn ->
          CMS.update_field_definition(
            field,
            %{selection: Map.put(field.selection, "states", ["published"])},
            actor: admin
          )
        end)

      assert message =~ "does not exist on this site"

      # Moving the targets under a condition still is.
      assert refusal(fn ->
               CMS.update_field_definition(field, %{target_type: "post"}, actor: admin)
             end) =~ "not one of this field's target types"
    end

    test "destroying a named field leaves the condition inert", %{admin: admin} do
      diet = page_field!(admin, %{})

      field =
        field!(admin, %{
          selection: %{"by_type" => %{"page" => %{"fields" => %{"diet" => "vegan"}}}}
        })

      CMS.destroy_field_definition!(diet, actor: admin)

      assert {:ok, :unfiltered} =
               ReferenceSelection.query_for(field.selection, "page", admin, nil)

      assert ReferenceSelection.live(field.selection, ["page"], nil) == nil
    end

    test "a deleted tag or category is dropped from the live view", %{admin: admin} do
      keep = tag!(admin)
      gone = tag!(admin)
      category = category!(admin)

      field =
        field!(admin, %{
          selection: %{
            "states" => ["published"],
            "by_type" => %{
              "page" => %{"tags_any" => [keep.id, gone.id], "category" => category.id}
            }
          }
        })

      CMS.destroy_tag!(gone, actor: admin)
      CMS.destroy_category!(category, actor: admin)

      assert ReferenceSelection.live(field.selection, ["page"], nil) == %{
               "states" => ["published"],
               "by_type" => %{"page" => %{"tags_any" => [keep.id]}}
             }

      assert {:ok, [filter: [[state: _], _tags], arguments: %{}]} =
               ReferenceSelection.query_for(field.selection, "page", admin, nil)
    end
  end
end
