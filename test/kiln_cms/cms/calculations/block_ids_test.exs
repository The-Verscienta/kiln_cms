defmodule KilnCMS.CMS.Calculations.BlockIdsTest do
  @moduledoc """
  The id-only block-tree projection (#954): the read surface that makes
  `EnforceBlockFieldPolicy`'s required id binding satisfiable on drafts.

  Two properties matter and both are pinned with `==` rather than key probes:
  the projection carries the ids in the positions they render (so a client can
  tell which id names which child), and it carries **nothing else** — no field
  values, or it would widen the deliberately non-`public?` `blocks` boundary.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "block-ids-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "block-ids-#{System.unique_integer([:positive])}"

  test "projects the tree to _id/_type in render positions, nested columns recursed" do
    admin = user(:admin)

    {top, a, b, inner, deep} =
      {Ash.UUID.generate(), Ash.UUID.generate(), Ash.UUID.generate(), Ash.UUID.generate(),
       Ash.UUID.generate()}

    {:ok, page} =
      CMS.create_page(
        %{
          title: "Ids",
          slug: slug(),
          block_tree: [
            %{"_type" => "heading", "id" => top, "text" => "One", "level" => 2},
            %{
              "_type" => "columns",
              "id" => Ash.UUID.generate(),
              "columns" => [
                %{
                  "blocks" => [
                    %{"_type" => "quote", "id" => a, "text" => "A", "featured" => true},
                    %{
                      "_type" => "columns",
                      "id" => inner,
                      "columns" => [
                        %{"blocks" => [%{"_type" => "quote", "id" => deep, "text" => "deep"}]}
                      ]
                    }
                  ]
                },
                %{"blocks" => [%{"_type" => "quote", "id" => b, "text" => "B"}]}
              ]
            }
          ]
        },
        actor: admin
      )

    loaded = Ash.load!(page, :block_ids, actor: admin)
    [_heading, %{"_id" => columns_id}] = loaded.block_ids

    # The WHOLE projection, so a leaked field value fails loudly rather than
    # hiding behind a key-presence probe.
    assert loaded.block_ids == [
             %{"_type" => "heading", "_id" => top},
             %{
               "_type" => "columns",
               "_id" => columns_id,
               "columns" => [
                 %{
                   "blocks" => [
                     %{"_type" => "quote", "_id" => a},
                     %{
                       "_type" => "columns",
                       "_id" => inner,
                       "columns" => [%{"blocks" => [%{"_type" => "quote", "_id" => deep}]}]
                     }
                   ]
                 },
                 %{"blocks" => [%{"_type" => "quote", "_id" => b}]}
               ]
             }
           ]
  end

  test "a stored child with no id contributes no _id key — reads never mint identity" do
    # The policy's strictness is keyed on ids that are actually stored, so the
    # projection must be honest about a child having none (an id invented here
    # would name nothing on the write path, sending the client in circles —
    # and re-minting per read was exactly the churn that got server-side
    # stamping reverted in #953).
    admin = user(:admin)

    {:ok, page} =
      CMS.create_page(
        %{
          title: "Id-less",
          slug: slug(),
          block_tree: [
            %{
              "_type" => "columns",
              "columns" => [%{"blocks" => [%{"_type" => "quote", "text" => "no id"}]}]
            }
          ]
        },
        actor: admin
      )

    %{block_ids: [%{"columns" => [%{"blocks" => [child]}]}]} =
      Ash.load!(page, :block_ids, actor: admin)

    assert child == %{"_type" => "quote"}
  end

  test "an editor can read a draft's ids; a viewer-tier reader cannot reach the draft at all" do
    # The authorization axis, stated: the calculation adds no grant of its own,
    # so a draft's ids are exactly as readable as the draft row — editor tier
    # (`ReadableContentType`) or admin. The viewer is refused the ROW, ids and
    # all, which is what keeps this from being a new surface on unpublished
    # content.
    admin = user(:admin)
    a = Ash.UUID.generate()

    {:ok, page} =
      CMS.create_page(
        %{
          title: "Draft",
          slug: slug(),
          block_tree: [
            %{
              "_type" => "columns",
              "columns" => [
                %{"blocks" => [%{"_type" => "quote", "id" => a, "text" => "A"}]}
              ]
            }
          ]
        },
        actor: admin
      )

    assert page.state == :draft

    assert %{block_ids: [%{"columns" => [%{"blocks" => [%{"_id" => ^a}]}]}]} =
             Ash.load!(page, :block_ids, actor: user(:editor))

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             CMS.get_page(page.id, load: [:block_ids], actor: user(:viewer))
  end

  test "the projection's _id round-trips: what block_ids hands back, the write path accepts" do
    # The two surfaces must agree or the remedy in the policy's error message
    # is a lie. Read the projection, echo `_id` verbatim, and the stored child
    # keeps its identity.
    admin = user(:admin)
    a = Ash.UUID.generate()

    {:ok, page} =
      CMS.create_page(
        %{
          title: "Round trip",
          slug: slug(),
          block_tree: [
            %{
              "_type" => "columns",
              "columns" => [
                %{"blocks" => [%{"_type" => "quote", "id" => a, "text" => "A"}]}
              ]
            }
          ]
        },
        actor: admin
      )

    %{block_ids: [%{"columns" => [%{"blocks" => [%{"_id" => read_id} = projected]}]}]} =
      Ash.load!(page, :block_ids, actor: admin)

    {:ok, updated} =
      CMS.update_page(
        page,
        %{
          block_tree: [
            %{
              "_type" => "columns",
              "columns" => [%{"blocks" => [Map.put(projected, "text", "edited")]}]
            }
          ]
        },
        actor: admin
      )

    assert %{block_ids: [%{"columns" => [%{"blocks" => [%{"_id" => ^read_id}]}]}]} =
             Ash.load!(updated, :block_ids, actor: admin)

    assert read_id == a
  end
end
