defmodule KilnCMS.CMS.BlockFieldPolicyTest do
  @moduledoc """
  Server-side enforcement of `Kiln.Block` `editable_by` field policies (#51).

  `KilnCMS.Blocks.Quote` declares `field :featured, editable_by: [:admin]`. The
  rule used to be enforced only by the content editor filtering the fields it
  renders, so these tests drive the *resource*, which is the boundary every
  non-form write path (write API `block_tree`, MCP, GraphQL) shares.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "block-policy-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp slug, do: "block-policy-#{System.unique_integer([:positive])}"

  defp quote_block(attrs), do: Map.merge(%{"_type" => "quote", "text" => "body"}, attrs)

  defp create_page(actor, blocks) do
    CMS.create_page(%{title: "Blocks", slug: slug(), block_tree: blocks}, actor: actor)
  end

  # The stored block with its id, so an update can address the same block.
  defp stored_block(page) do
    [%Ash.Union{value: block}] = page.blocks
    block
  end

  # Every nested child map in a stored page, flattened, at any depth (#865), so
  # a test can assert on what a write actually stored.
  defp stored_children(page) do
    page.blocks
    |> Enum.flat_map(fn %Ash.Union{value: block} -> Map.get(block, :columns, []) end)
    |> Enum.flat_map(&child_maps/1)
  end

  defp child_maps(%{"blocks" => blocks}) when is_list(blocks),
    do: Enum.flat_map(blocks, &[&1 | nested_of(&1)])

  defp child_maps(_other), do: []

  defp nested_of(%{"columns" => cols}) when is_list(cols), do: Enum.flat_map(cols, &child_maps/1)
  defp nested_of(_other), do: []

  describe "create" do
    test "an editor cannot create a block with an admin-only field set" do
      assert {:error, error} =
               create_page(user(:editor), [quote_block(%{"featured" => true})])

      assert Exception.message(error) =~ "featured"
    end

    test "an editor can create a block that leaves the admin-only field at its default" do
      assert {:ok, page} = create_page(user(:editor), [quote_block(%{})])
      assert stored_block(page).featured == false
    end

    test "an admin can create a block with the admin-only field set" do
      assert {:ok, page} = create_page(user(:admin), [quote_block(%{"featured" => true})])
      assert stored_block(page).featured == true
    end
  end

  describe "update" do
    setup do
      admin = user(:admin)
      {:ok, page} = create_page(admin, [quote_block(%{"featured" => true})])
      %{admin: admin, page: page, block: stored_block(page)}
    end

    test "an editor cannot flip an admin-only field on an existing block", %{
      page: page,
      block: block
    } do
      assert {:error, error} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     quote_block(%{"id" => block.id, "text" => "edited", "featured" => false})
                   ]
                 },
                 actor: user(:editor)
               )

      assert Exception.message(error) =~ "featured"
    end

    test "an editor may edit other fields while resubmitting the unchanged admin-only value",
         %{page: page, block: block} do
      assert {:ok, updated} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     quote_block(%{"id" => block.id, "text" => "edited", "featured" => true})
                   ]
                 },
                 actor: user(:editor)
               )

      assert stored_block(updated).text == "edited"
      assert stored_block(updated).featured == true
    end

    test "an admin may flip the admin-only field", %{page: page, block: block, admin: admin} do
      assert {:ok, updated} =
               CMS.update_page(
                 page,
                 %{block_tree: [quote_block(%{"id" => block.id, "featured" => false})]},
                 actor: admin
               )

      assert stored_block(updated).featured == false
    end

    test "a metadata-only update is untouched by the check", %{page: page} do
      assert {:ok, updated} = CMS.update_page(page, %{title: "Renamed"}, actor: user(:editor))
      assert updated.title == "Renamed"
      assert stored_block(updated).featured == true
    end
  end

  describe "nesting" do
    test "an editor cannot smuggle an admin-only field through a columns child" do
      nested = [
        %{
          "_type" => "columns",
          "columns" => [%{"blocks" => [quote_block(%{"featured" => true})]}]
        }
      ]

      assert {:error, error} = create_page(user(:editor), nested)
      assert Exception.message(error) =~ "featured"
    end

    test "an editor may nest a block that leaves the admin-only field alone" do
      nested = [
        %{
          "_type" => "columns",
          "columns" => [%{"blocks" => [quote_block(%{})]}]
        }
      ]

      assert {:ok, _page} = create_page(user(:editor), nested)
    end
  end

  describe "nested clear by omission (#774)" do
    defp columns_with(child), do: %{"_type" => "columns", "columns" => [%{"blocks" => [child]}]}

    defp nested_child(page) do
      [%Ash.Union{value: columns}] = page.blocks
      [%{"blocks" => [child | _]} | _] = columns.columns
      child
    end

    setup do
      admin = user(:admin)

      {:ok, page} =
        create_page(admin, [
          columns_with(quote_block(%{"featured" => true, "text" => "featured"}))
        ])

      %{page: page, admin: admin, editor: user(:editor)}
    end

    test "an editor cannot clear a nested admin-set field by omitting it", %{
      page: page,
      editor: editor
    } do
      # The #774 reproduction: nest a featured quote in a column (as admin), then
      # resubmit the column with the child's `featured` gone. The old per-child
      # rule only checked PRESENT values, so an omitted one sailed through and the
      # stored child lost `featured`.
      assert {:error, error} =
               CMS.update_page(
                 page,
                 %{block_tree: [columns_with(quote_block(%{"text" => "edited"}))]},
                 actor: editor
               )

      assert Exception.message(error) =~ "featured"
    end

    test "an editor may resubmit the column preserving the admin value, editing around it", %{
      page: page,
      editor: editor
    } do
      # Acceptance #2: the old per-child default rule refused this outright (any
      # non-default nested restricted value was a violation). The multiset rule
      # allows it — the admin value is preserved, only the permitted `text` moved.
      #
      # No child id anywhere: the STORED children carry none (this page was
      # authored id-less), so there is no identity to bind and the multiset
      # governs. Once the stored tree carries ids, an id-less write is refused
      # instead (#954) — see "a wholly id-less re-target against stamped
      # children is refused".
      assert {:ok, updated} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     columns_with(quote_block(%{"featured" => true, "text" => "edited"}))
                   ]
                 },
                 actor: editor
               )

      assert nested_child(updated)["featured"] == true
      assert nested_child(updated)["text"] == "edited"
    end

    test "an editor cannot set a nested admin-only field the stored tree didn't have", %{
      editor: editor
    } do
      # A fresh page with an unfeatured nested quote; the editor then tries to
      # turn on `featured` — introducing a value, refused like the smuggle case.
      {:ok, plain} = create_page(editor, [columns_with(quote_block(%{}))])

      assert {:error, error} =
               CMS.update_page(
                 plain,
                 %{block_tree: [columns_with(quote_block(%{"featured" => true}))]},
                 actor: editor
               )

      assert Exception.message(error) =~ "featured"
    end

    test "an admin may clear the nested field", %{page: page, admin: admin} do
      assert {:ok, updated} =
               CMS.update_page(
                 page,
                 %{block_tree: [columns_with(quote_block(%{"text" => "edited"}))]},
                 actor: admin
               )

      assert nested_child(updated)["featured"] in [false, nil]
    end
  end

  describe "nested multiset — boundaries of the whole-tree rule (#774)" do
    defp columns_children(children),
      do: %{"_type" => "columns", "columns" => [%{"blocks" => children}]}

    test "an admin value nested two columns deep is still caught on omission" do
      admin = user(:admin)

      inner = columns_children([quote_block(%{"featured" => true})])
      {:ok, page} = create_page(admin, [columns_children([inner])])

      inner_omit = columns_children([quote_block(%{})])

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [columns_children([inner_omit])]},
                 actor: user(:editor)
               )

      assert Exception.message(error) =~ "featured"
    end

    test "dropping one of two admin-featured children is refused (multiset shrinks)" do
      admin = user(:admin)

      two =
        columns_children([
          quote_block(%{"featured" => true, "text" => "A"}),
          quote_block(%{"featured" => true, "text" => "B"})
        ])

      {:ok, page} = create_page(admin, [two])

      one =
        columns_children([
          quote_block(%{"featured" => true, "text" => "A"}),
          quote_block(%{"featured" => false, "text" => "B"})
        ])

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [one]}, actor: user(:editor))

      assert Exception.message(error) =~ "featured"
    end

    test "a decoy _type in an unrendered slot cannot rebalance the multiset" do
      # The bypass this whole comparison exists to stop, dressed as a rebalance:
      # the editor removes a real admin-set `featured`, then re-adds the same
      # value as a SIBLING KEY on the column wrapper. Nothing renders that slot —
      # `Columns.raw_blocks/1` reads only `col["blocks"]` — but a traversal that
      # collected any map carrying a `_type` counted it, so the two multisets
      # compared equal and the removal went through silently.
      admin = user(:admin)

      {:ok, page} = create_page(admin, [columns_children([quote_block(%{"featured" => true})])])

      decoy = %{
        "_type" => "columns",
        "columns" => [
          Map.merge(
            %{"blocks" => [quote_block(%{})]},
            %{"_type" => "quote", "featured" => true}
          )
        ]
      }

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [decoy]}, actor: user(:editor))

      assert Exception.message(error) =~ "featured"
    end

    test "a value parked under a non-rendered key cannot offset a removal (#956)" do
      # The traversal used to hunt for maps carrying a `"blocks"` key, anywhere
      # in the term. `field :columns, {:array, :map}` has no `fields`
      # constraint, so an attacker could park a whole child list under a key of
      # their choosing: the check counted it, the renderer never showed it, and
      # it offset the removal of a real admin-set value.
      admin = user(:admin)

      {:ok, page} =
        create_page(admin, [columns_children([quote_block(%{"featured" => true, "text" => "A"})])])

      parked = %{
        "_type" => "columns",
        "columns" => [
          %{
            # What renders: the featured value is gone.
            "blocks" => [quote_block(%{"text" => "editor content"})],
            # What does not render, carrying the value to balance the books.
            "trash" => [%{"blocks" => [quote_block(%{"featured" => true, "text" => "A"})]}]
          }
        ]
      }

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [parked]}, actor: user(:editor))

      assert Exception.message(error) =~ "featured"
    end

    test "the parking slot does not have to be a columns block (#956)" do
      # `gallery.images` is `{:array, :map}` too, and unknown keys survive its
      # sanitizer. So the old traversal could be satisfied without a `columns`
      # block anywhere in the submission — the attacker deletes every one.
      admin = user(:admin)

      {:ok, page} =
        create_page(admin, [columns_children([quote_block(%{"featured" => true, "text" => "A"})])])

      gallery_park = %{
        "_type" => "gallery",
        "title" => "g",
        "images" => [
          %{
            "url" => "https://example.com/a.png",
            "blocks" => [quote_block(%{"featured" => true, "text" => "A"})]
          }
        ]
      }

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [gallery_park]}, actor: user(:editor))

      assert Exception.message(error) =~ "featured"
    end

    test "an admin may still write a value in an unrendered slot without it counting" do
      # The mirror of the test above, so the fix can't be "reject anything with a
      # stray key": an admin write carrying the same decoy is accepted, and the
      # decoy simply contributes nothing to either side of the comparison.
      admin = user(:admin)

      {:ok, page} = create_page(admin, [columns_children([quote_block(%{"featured" => true})])])

      same_tree_plus_junk = %{
        "_type" => "columns",
        "columns" => [
          Map.merge(
            %{"blocks" => [quote_block(%{"featured" => true})]},
            %{"_type" => "quote", "featured" => true}
          )
        ]
      }

      assert {:ok, _updated} =
               CMS.update_page(page, %{block_tree: [same_tree_plus_junk]}, actor: user(:editor))
    end

    test "re-targeting an admin value between same-type children is refused (#865)" do
      # The accepted residual of #774: the count is preserved and only which
      # child holds `featured` moves, so the multiset compared equal. Where the
      # children have ids — editor-authored content does — the value is bound to
      # the child that held it and moving it is a change to both.
      admin = user(:admin)
      {a, b} = {Ash.UUID.generate(), Ash.UUID.generate()}

      before =
        columns_children([
          quote_block(%{"id" => a, "featured" => true, "text" => "A"}),
          quote_block(%{"id" => b, "featured" => false, "text" => "B"})
        ])

      {:ok, page} = create_page(admin, [before])

      swapped =
        columns_children([
          quote_block(%{"id" => a, "featured" => false, "text" => "A"}),
          quote_block(%{"id" => b, "featured" => true, "text" => "B"})
        ])

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [swapped]}, actor: user(:editor))

      # Pinned to the rule that catches it, not merely to the field name — every
      # violation message in this module mentions `featured`, so `=~ "featured"`
      # would still pass if the multiset started firing instead.
      assert Exception.message(error) =~ "cannot move or clear"
    end

    test "clearing an identified child by omitting the field is refused (#865)" do
      # The #774 omission, this time named at the child rather than the tree:
      # the child comes back under its own id with `featured` simply gone, which
      # the cast reads as the default.
      admin = user(:admin)
      a = Ash.UUID.generate()

      {:ok, page} =
        create_page(admin, [
          columns_children([quote_block(%{"id" => a, "featured" => true, "text" => "A"})])
        ])

      assert {:error, error} =
               CMS.update_page(
                 page,
                 %{block_tree: [columns_children([quote_block(%{"id" => a, "text" => "A"})])]},
                 actor: user(:editor)
               )

      assert Exception.message(error) =~ "cannot move or clear"
    end

    test "two children submitted under one id are refused (#865)" do
      # The collision that made the binding refuse LESS: indexed by id, the last
      # one wins, so submitting the real child cleared plus a decoy of the same
      # id carrying the value satisfied the binding — it read the decoy — while
      # the content that actually renders quietly lost `featured`.
      #
      # Unlike the two rules above this one is not gated on round-tripping: an
      # id naming two children is incoherent whoever sent it.
      admin = user(:admin)
      a = Ash.UUID.generate()

      {:ok, page} =
        create_page(admin, [
          columns_children([quote_block(%{"id" => a, "featured" => true, "text" => "A"})])
        ])

      collided =
        columns_children([
          quote_block(%{"id" => a, "text" => "A", "featured" => false}),
          quote_block(%{"id" => a, "text" => "", "featured" => true})
        ])

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [collided]}, actor: user(:editor))

      assert Exception.message(error) =~ "same id"
    end

    test "a client that round-trips the artifact gets the binding (#954)" do
      # The point of accepting `_id`: the fired `:json` artifact is the only
      # surface a headless client can read a nested child's id from, so "read
      # the artifact, send it back" is the only way it can round-trip ids — and
      # doing so must actually engage #865's binding rather than looking id-less.
      admin = user(:admin)
      a = Ash.UUID.generate()

      {:ok, page} =
        create_page(admin, [
          columns_children([
            quote_block(%{"id" => a, "featured" => true, "text" => "A"}),
            quote_block(%{"id" => Ash.UUID.generate(), "text" => "B"})
          ])
        ])

      # Exactly what the artifact hands back — `_id`, not `id`.
      as_artifact =
        columns_children([
          %{"_type" => "quote", "_id" => a, "featured" => false, "text" => "A"},
          %{"_type" => "quote", "_id" => Ash.UUID.generate(), "featured" => true, "text" => "B"}
        ])

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [as_artifact]}, actor: user(:editor))

      # Bound, not merely counted: the count is unchanged, so only the binding
      # sees this.
      assert Exception.message(error) =~ "cannot move or clear"
    end

    test "a wholly id-less re-target against stamped children is refused (#954)" do
      # The residual #954 was filed about, inverted. The stored children carry
      # ids, the submission carries none, and the count is unchanged — so only
      # the binding sees this, and the binding is now required rather than
      # gated: ids are readable (`block_ids` on drafts, the artifact's `_id`
      # once published), so stripping them is a refusal, not a downgrade to the
      # count-only multiset.
      admin = user(:admin)
      {a, b} = {Ash.UUID.generate(), Ash.UUID.generate()}

      before =
        columns_children([
          quote_block(%{"id" => a, "featured" => true, "text" => "A"}),
          quote_block(%{"id" => b, "featured" => false, "text" => "B"})
        ])

      {:ok, page} = create_page(admin, [before])

      swapped =
        columns_children([
          quote_block(%{"featured" => false, "text" => "A"}),
          quote_block(%{"featured" => true, "text" => "B"})
        ])

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [swapped]}, actor: user(:editor))

      # Bound, not merely counted — and the message names the surface the ids
      # can be read from, because a client that dropped every id has no other
      # way to learn one exists.
      assert Exception.message(error) =~ "cannot move or clear"
      assert Exception.message(error) =~ "block_ids"
    end

    test "a re-target on a stored tree whose children carry no ids is still allowed " <>
           "(narrowed residual, #954)" do
      # What remains open, pinned so the limit stays deliberate. A restricted
      # value stored on an id-less child (a page authored by an id-less headless
      # admin client — the editor always stamps) has no identity to bind, and
      # the policy's strictness is keyed on ids that are actually STORED: a
      # demand for ids nothing ever stored would brick the row for every
      # non-admin, with no surface able to answer it. Such a document becomes
      # strict the first time an id-stamping client saves it.
      admin = user(:admin)

      before =
        columns_children([
          quote_block(%{"featured" => true, "text" => "A"}),
          quote_block(%{"featured" => false, "text" => "B"})
        ])

      {:ok, page} = create_page(admin, [before])

      swapped =
        columns_children([
          quote_block(%{"featured" => false, "text" => "A"}),
          quote_block(%{"featured" => true, "text" => "B"})
        ])

      assert {:ok, _updated} =
               CMS.update_page(page, %{block_tree: [swapped]}, actor: user(:editor))
    end

    test "echoing some ids while dropping the featured child's is refused (#954)" do
      # Partial round-tripping is not a loophole: the binding demands the child
      # that HELD the value back under its id, whatever else the submission
      # carries.
      admin = user(:admin)
      {a, b} = {Ash.UUID.generate(), Ash.UUID.generate()}

      {:ok, page} =
        create_page(admin, [
          columns_children([
            quote_block(%{"id" => a, "featured" => true, "text" => "A"}),
            quote_block(%{"id" => b, "featured" => false, "text" => "B"})
          ])
        ])

      kept_b_dropped_a =
        columns_children([
          quote_block(%{"featured" => true, "text" => "A"}),
          quote_block(%{"id" => b, "featured" => false, "text" => "B"})
        ])

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [kept_b_dropped_a]}, actor: user(:editor))

      assert Exception.message(error) =~ "cannot move or clear"
    end

    test "a child may still move between columns, carrying its id and value (#865)" do
      # The binding binds a value to a CHILD, not to a position — otherwise it
      # would refuse the editor's drag-and-drop, which is the ordinary way to
      # move a column's contents and has nothing to do with the field.
      admin = user(:admin)
      a = Ash.UUID.generate()

      {:ok, page} =
        create_page(admin, [
          %{
            "_type" => "columns",
            "columns" => [
              %{"blocks" => [quote_block(%{"id" => a, "featured" => true, "text" => "A"})]},
              %{"blocks" => []}
            ]
          }
        ])

      moved = %{
        "_type" => "columns",
        "columns" => [
          %{"blocks" => []},
          %{"blocks" => [quote_block(%{"id" => a, "featured" => true, "text" => "A"})]}
        ]
      }

      assert {:ok, _updated} =
               CMS.update_page(page, %{block_tree: [moved]}, actor: user(:editor))
    end

    test "an editor may add a plain sibling beside a featured child (#865)" do
      # A new child has an id nothing stored knows, so the binding says nothing
      # about it and the multiset governs — it may be added, just not
      # pre-`featured`.
      admin = user(:admin)
      a = Ash.UUID.generate()

      {:ok, page} =
        create_page(admin, [
          columns_children([quote_block(%{"id" => a, "featured" => true, "text" => "A"})])
        ])

      with_sibling =
        columns_children([
          quote_block(%{"id" => a, "featured" => true, "text" => "A"}),
          quote_block(%{"id" => Ash.UUID.generate(), "text" => "new"})
        ])

      assert {:ok, _updated} =
               CMS.update_page(page, %{block_tree: [with_sibling]}, actor: user(:editor))
    end

    test "a headless client that reads block_ids can edit the page repeatedly (#954)" do
      # The remedy the refusal names has to actually work, or the requirement is
      # a wall (the reason the binding used to be gated at all). The page is
      # authored the way the editor authors one — children carrying ids — and
      # the client does what the error says: read each child's `_id` from the
      # `block_ids` calculation and echo it. Repeatedly, because the earlier
      # server-side stamping attempt (#953, reverted) churned a fresh id per
      # save — so the ids are asserted STABLE across the edits, not merely
      # accepted.
      admin = user(:admin)
      a = Ash.UUID.generate()

      {:ok, page} =
        create_page(admin, [
          columns_children([quote_block(%{"id" => a, "featured" => true, "text" => "A"})])
        ])

      editor = user(:editor)

      page =
        Enum.reduce(1..3, page, fn n, page ->
          # As the client would: a policy-scoped read carrying the projection.
          %{block_ids: [%{"columns" => [%{"blocks" => [%{"_id" => child_id}]}]}]} =
            Ash.load!(page, :block_ids, actor: editor)

          assert child_id == a, "block_ids handed back a churned id on edit #{n}"

          assert {:ok, updated} =
                   CMS.update_page(
                     page,
                     %{
                       block_tree: [
                         columns_children([
                           quote_block(%{
                             "_id" => child_id,
                             "featured" => true,
                             "text" => "edit #{n}"
                           })
                         ])
                       ]
                     },
                     actor: editor
                   ),
                 "headless edit #{n} was refused"

          updated
        end)

      assert [child] = stored_children(page)
      assert child["id"] == a
      assert child["featured"] == true
      assert child["text"] == "edit 3"
    end

    test "an id-less write against a stamped tree holding an admin value is refused, " <>
           "naming the surface (#954)" do
      # The other half of the flow above: the client that did NOT read
      # `block_ids` is told exactly where the ids it dropped can be read from.
      # This is the lockout the old gate existed to avoid, converted into a
      # refusal with a performable remedy.
      admin = user(:admin)
      a = Ash.UUID.generate()

      {:ok, page} =
        create_page(admin, [
          columns_children([quote_block(%{"id" => a, "featured" => true, "text" => "A"})])
        ])

      assert {:error, error} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     columns_children([quote_block(%{"featured" => true, "text" => "edited"})])
                   ]
                 },
                 actor: user(:editor)
               )

      assert Exception.message(error) =~ "cannot move or clear"
      assert Exception.message(error) =~ "block_ids"
    end

    test "a non-admin can restore a version whose children carry no ids (#865)" do
      # `restore_version` accepts nothing but a `version_id`, so it can never
      # supply child ids — and every version captured before children had them
      # restores id-less by construction. A binding that demanded ids back would
      # make those versions unrestorable by an editor, with no remedy: no
      # surface can hand back ids history never stored. Now that the binding is
      # otherwise required (#954), this pins the one deliberate carve-out — the
      # id-less restore fold, whose tree is our own vetted history.
      #
      # v1's children are id-less; the CURRENT row's carry ids. Restoring v1
      # therefore submits an id-less tree against an identified stored one,
      # which is the shape that would be refused.
      admin = user(:admin)

      {:ok, page} =
        create_page(admin, [
          columns_children([quote_block(%{"featured" => true, "text" => "v1"})])
        ])

      {:ok, page} =
        CMS.update_page(
          page,
          %{
            block_tree: [
              columns_children([
                quote_block(%{"id" => Ash.UUID.generate(), "featured" => true, "text" => "v2"})
              ])
            ]
          },
          actor: admin
        )

      assert [%{"id" => _}] = stored_children(page)

      [create_version | _] =
        CMS.list_page_versions!(actor: admin)
        |> Enum.filter(&(&1.version_source_id == page.id))
        |> Enum.sort_by(& &1.version_inserted_at, DateTime)

      assert {:ok, _restored} =
               CMS.restore_page_version(page, %{version_id: create_version.id},
                 actor: user(:editor)
               )
    end

    test "the binding holds two columns deep (#865)" do
      admin = user(:admin)
      a = Ash.UUID.generate()

      inner = columns_children([quote_block(%{"id" => a, "featured" => true, "text" => "deep"})])
      {:ok, page} = create_page(admin, [columns_children([inner])])

      swapped_inner =
        columns_children([
          columns_children([
            quote_block(%{"id" => a, "featured" => false, "text" => "deep"}),
            quote_block(%{"id" => Ash.UUID.generate(), "featured" => true, "text" => "other"})
          ])
        ])

      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [swapped_inner]}, actor: user(:editor))

      assert Exception.message(error) =~ "featured"
    end
  end

  describe "clear by omission (#566)" do
    setup do
      admin = user(:admin)

      {:ok, page} =
        create_page(admin, [quote_block(%{"featured" => true, "text" => "featured"})])

      %{page: page, admin: admin, editor: user(:editor)}
    end

    test "an editor cannot clear an admin-set field by dropping the id and omitting it",
         %{page: page, editor: editor} do
      # The hole. Block ids do not round-trip on the headless path — `blocks` is
      # not `public?`, so a client cannot read the tree it would be preserving —
      # and once the id is gone the block reads as new, where a restricted field
      # must equal its default. Omit the field and the cast supplies exactly
      # that default, so the write looked like a no-op and silently cleared it.
      assert {:error, error} =
               CMS.update_page(page, %{block_tree: [quote_block(%{"text" => "edited"})]},
                 actor: editor
               )

      # And the message names the actual mistake. "cannot change `featured`" is
      # unactionable advice for a client that sent no `featured` at all.
      assert Exception.message(error) =~ "cannot omit `featured`"
    end

    test "an admin may still clear it", %{page: page, admin: admin} do
      assert {:ok, updated} =
               CMS.update_page(page, %{block_tree: [quote_block(%{"text" => "edited"})]},
                 actor: admin
               )

      assert %Ash.Union{value: %{featured: false}} = hd(updated.blocks)
    end

    test "sending the block's id is the way through", %{page: page, editor: editor} do
      # The remedy the error names has to actually work, or the fix is a wall.
      # Note it is the *id*, not the value: resubmitting `featured: true` on an
      # id-less block is still refused by the older rule (a block with no id is
      # new, and a new block must carry the default), so the message must not
      # advise that.
      stored = stored_block(page)

      assert {:ok, updated} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     quote_block(%{"id" => stored.id, "text" => "edited", "featured" => true})
                   ]
                 },
                 actor: editor
               )

      assert %Ash.Union{value: %{text: "edited", featured: true}} = hd(updated.blocks)
    end

    test "the message advises the remedy that works", %{page: page, editor: editor} do
      {:error, error} =
        CMS.update_page(page, %{block_tree: [quote_block(%{"text" => "edited"})]}, actor: editor)

      assert Exception.message(error) =~ "send each block's id"
    end

    test "a page with no admin-set value is untouched", %{editor: editor} do
      # The common case, and why this is narrower than requiring ids everywhere:
      # a headless client writing ordinary content never notices.
      {:ok, plain} = create_page(user(:admin), [quote_block(%{"text" => "plain"})])

      assert {:ok, updated} =
               CMS.update_page(plain, %{block_tree: [quote_block(%{"text" => "edited"})]},
                 actor: editor
               )

      assert %Ash.Union{value: %{text: "edited", featured: false}} = hd(updated.blocks)
    end

    test "the check only ever refuses; it grants nothing", %{page: page, editor: editor} do
      # The design constraint, pinned. An earlier attempt paired id-less blocks
      # with stored ones by POSITION and treated that as identity — which handed
      # the featured slot to whatever new content landed in that position. A
      # block with a fresh id is unambiguously new and must carry the default,
      # before and after.
      assert {:error, error} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     quote_block(%{
                       "id" => Ecto.UUID.generate(),
                       "text" => "editor spam",
                       "featured" => true
                     })
                   ]
                 },
                 actor: editor
               )

      assert Exception.message(error) =~ "cannot change `featured`"
    end

    test "an editor may still insert a block above the featured one",
         %{page: page, editor: editor} do
      # The regression the positional pairing caused: the new block matched no
      # id, paired with the stored featured quote by position, and was refused
      # for not carrying a value it had no business carrying.
      stored = stored_block(page)

      assert {:ok, updated} =
               CMS.update_page(
                 page,
                 %{
                   block_tree: [
                     quote_block(%{"text" => "new intro"}),
                     quote_block(%{
                       "id" => stored.id,
                       "text" => "featured",
                       "featured" => true
                     })
                   ]
                 },
                 actor: editor
               )

      assert [%Ash.Union{value: %{featured: false}}, %Ash.Union{value: %{featured: true}}] =
               updated.blocks
    end

    test "the editor form's own writes are unaffected", %{page: page, editor: editor} do
      # `ContentEditorLive` and the inline-editing bridge set `blocks` directly
      # rather than passing `block_tree`, so there is no raw input and nothing
      # can have been omitted. The editor form does not render `featured` at
      # all, so a rule that fired here would be unactionable.
      stored = stored_block(page)

      assert {:ok, _updated} =
               CMS.update_page(
                 page,
                 %{
                   blocks: [
                     %{
                       "_type" => "quote",
                       "id" => stored.id,
                       "text" => "edited",
                       "featured" => true
                     }
                   ]
                 },
                 actor: editor
               )
    end
  end

  describe "system writes" do
    test "an actor-less write is exempt" do
      assert {:ok, page} =
               CMS.create_page(
                 %{
                   title: "System",
                   slug: slug(),
                   block_tree: [quote_block(%{"featured" => true})]
                 },
                 authorize?: false
               )

      assert stored_block(page).featured == true
    end
  end
end
