defmodule KilnCMS.Firing.DeliverLlmTest do
  @moduledoc """
  `FieldDefinition.deliver_llm` (#2282, ADR 0082) end to end: the flag is
  cleared where it means nothing and refused on a private field, a fired
  `:llm` artifact carries the opted-in text as `##` sections and the
  `:json_ld` main node as `hasPart` elements, and every write that changes
  what those say re-fires the type's published documents.

  `async: false`: it drains the shared Oban queue to run the re-fires.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.Firing
  alias KilnCMS.Firing.Engine

  @canary "CANARY-draft-title-91c2"

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "llm-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp uniq, do: System.unique_integer([:positive])
  defp slug, do: "llm-#{uniq()}"

  defp def!(admin, attrs),
    do: CMS.create_field_definition!(Map.merge(%{label: "Field"}, attrs), actor: admin)

  defp sub!(admin, parent, name, attrs),
    do: def!(admin, Map.merge(%{name: name, group_of_id: parent.id, field_type: :string}, attrs))

  defp item_type!(admin, flexible, name, attrs),
    do:
      def!(
        admin,
        Map.merge(%{name: name, field_type: :group, flex_of_id: flexible.id}, attrs)
      )

  defp org, do: KilnCMS.Accounts.default_org_id()

  defp artifact(post, surface) do
    {:ok, artifact} =
      Firing.get_artifact(:post, post.id, surface, authorize?: false, tenant: org())

    artifact.body
  end

  defp fire(post, admin, opts \\ []) do
    {:ok, bodies} =
      post.id |> then(&CMS.get_post!(&1, actor: admin)) |> Engine.fire([mode: :preview] ++ opts)

    bodies
  end

  defp hasparts(%{"@graph" => [node | _]}), do: Map.get(node, "hasPart")

  # A flexible `faq` (item type `qa`: question, answer, mood setting, votes)
  # and a plain `note`, both on posts. `flag?` sets `deliver_llm` on both.
  setup do
    admin = user(:admin)
    n = uniq()

    faq =
      def!(admin, %{
        content_type: :post,
        name: "faq#{n}",
        label: "FAQ",
        field_type: :flexible,
        deliver_llm: true
      })

    qa = item_type!(admin, faq, "qa", %{label: "Question and answer"})
    sub!(admin, qa, "question", %{label: "Question"})
    sub!(admin, qa, "answer", %{label: "Answer", field_type: :text, position: 1})
    sub!(admin, qa, "mood", %{label: "Mood", item_setting: true, position: 2})
    sub!(admin, qa, "votes", %{label: "Votes", field_type: :integer, position: 3})

    note =
      def!(admin, %{
        content_type: :post,
        name: "note#{n}",
        label: "Editor note",
        field_type: :string,
        position: 1,
        deliver_llm: true
      })

    values = %{
      faq.name => [
        %{
          "_type" => "qa",
          "question" => "Why?",
          "answer" => "<p>Because.</p>",
          "_settings" => %{"mood" => "calm"},
          "votes" => 4
        }
      ],
      note.name => "Read me"
    }

    post = CMS.create_post!(%{title: "Q&A", slug: slug(), custom_fields: values}, actor: admin)

    %{admin: admin, faq: faq, qa: qa, note: note, post: post, values: values}
  end

  describe "the flag" do
    test "is on for a top-level text, group or flexible field and cleared elsewhere", ctx do
      assert ctx.faq.deliver_llm and ctx.note.deliver_llm

      # A sub-field and an item type can't carry it, whatever was submitted.
      sub = sub!(ctx.admin, ctx.qa, "extra", %{deliver_llm: true})
      assert sub.deliver_llm == false
      assert item_type!(ctx.admin, ctx.faq, "other", %{deliver_llm: true}).deliver_llm == false

      # Neither can a type that has no text to carry.
      number =
        def!(ctx.admin, %{
          content_type: :post,
          name: "n#{uniq()}",
          field_type: :integer,
          deliver_llm: true
        })

      assert number.deliver_llm == false

      # Retyping a flagged field to one of those drops it.
      retyped = CMS.update_field_definition!(ctx.note, %{field_type: :integer}, actor: ctx.admin)
      assert retyped.deliver_llm == false
    end

    test "is refused on a private field", ctx do
      assert {:error, %Ash.Error.Invalid{} = error} =
               CMS.create_field_definition(
                 %{
                   content_type: :post,
                   name: "p#{uniq()}",
                   label: "P",
                   field_type: :string,
                   private: true,
                   deliver_llm: true
                 },
                 actor: ctx.admin
               )

      assert Exception.message(error) =~ "can't be included in AI-readable outputs"
    end

    test "an editor can't set it", ctx do
      editor = user(:editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_field_definition(ctx.note, %{deliver_llm: false}, actor: editor)
    end
  end

  describe "the fired artifacts" do
    test ":llm gets one section per flagged field after the blocks", ctx do
      %{llm: %{"markdown" => md}} = fire(ctx.post, ctx.admin)

      assert md ==
               "# Q&A\n\n## FAQ\n\n### Question and answer\n\n**Question:** Why?\n\n**Answer:** Because.\n\n## Editor note\n\nRead me\n"

      refute md =~ "calm"
      refute md =~ "Votes"
    end

    test ":json_ld gets hasPart elements on the main node", ctx do
      %{json_ld: json_ld} = fire(ctx.post, ctx.admin)

      assert hasparts(json_ld) == [
               %{
                 "@type" => "WebPageElement",
                 "name" => "Question and answer",
                 "text" => "Why?\n\nBecause."
               },
               %{"@type" => "WebPageElement", "name" => "Editor note", "text" => "Read me"}
             ]
    end

    test "with the flag off nothing is added to either artifact", ctx do
      CMS.update_field_definition!(ctx.faq, %{deliver_llm: false}, actor: ctx.admin)
      CMS.update_field_definition!(ctx.note, %{deliver_llm: false}, actor: ctx.admin)

      %{llm: %{"markdown" => md}, json_ld: json_ld} = fire(ctx.post, ctx.admin)

      assert md == "# Q&A\n"
      assert hasparts(json_ld) == nil
      refute inspect(json_ld) =~ "Because"
    end

    test "a point-in-time fire (recompute off) carries the stored text too", ctx do
      %{llm: %{"markdown" => md}, json_ld: json_ld} =
        fire(ctx.post, ctx.admin, custom_fields: :as_stored)

      assert md =~ "**Answer:** Because."
      assert length(hasparts(json_ld)) == 2
    end

    test "an Event-family type carries no hasPart, as it carries no articleBody", ctx do
      gig =
        CMS.create_type_definition!(
          %{name: "gig#{uniq()}", label: "Gig", schema_org_type: "MusicEvent"},
          actor: ctx.admin
        )

      def!(ctx.admin, %{
        type_definition_id: gig.id,
        name: "about",
        label: "About",
        field_type: :string,
        deliver_llm: true
      })

      entry =
        CMS.create_entry!(
          %{
            title: "Live",
            slug: slug(),
            type_definition_id: gig.id,
            custom_fields: %{"about" => "Doors at 8"}
          },
          actor: ctx.admin
        )

      {:ok, %{json_ld: %{"@graph" => [node | _]} = json_ld, llm: %{"markdown" => md}}} =
        Engine.fire(entry, mode: :preview)

      assert node["@type"] == "MusicEvent"
      refute Map.has_key?(node, "hasPart")
      refute inspect(json_ld) =~ "Doors at 8"
      # The Markdown surface has no such rule.
      assert md =~ "## About\n\nDoors at 8"
    end

    test "an unpublished reference snapshot inside an item reaches neither surface", ctx do
      draft = CMS.create_page!(%{title: @canary, slug: slug()}, actor: ctx.admin)

      target =
        sub!(ctx.admin, ctx.qa, "see", %{
          label: "See",
          field_type: :reference,
          target_type: "page",
          position: 4
        })

      assert target.field_type == :reference

      snapshot = %{"id" => draft.id, "type" => "page", "slug" => draft.slug, "title" => @canary}

      post =
        Ash.Seed.update!(ctx.post, %{
          custom_fields: %{
            ctx.faq.name => [
              %{
                "_id" => Ecto.UUID.generate(),
                "_type" => "qa",
                "question" => "Q",
                "see" => snapshot
              }
            ]
          }
        })

      for opts <- [[], [custom_fields: :as_stored]] do
        %{llm: %{"markdown" => md}, json_ld: json_ld} = fire(post, ctx.admin, opts)
        refute md =~ @canary
        refute inspect(json_ld) =~ @canary
        assert md =~ "**Question:** Q"
      end
    end
  end

  describe "re-firing the published documents" do
    setup ctx do
      post = CMS.publish_post!(ctx.post, %{}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      Map.put(ctx, :post, post)
    end

    defp markdown(post), do: artifact(post, :llm)["markdown"]

    test "the published artifacts carry the text", ctx do
      assert markdown(ctx.post) =~ "**Answer:** Because."
      assert length(hasparts(artifact(ctx.post, :json_ld))) == 2
    end

    test "flipping the flag adds and drops the text", ctx do
      CMS.update_field_definition!(ctx.note, %{deliver_llm: false}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      refute markdown(ctx.post) =~ "Read me"
      assert markdown(ctx.post) =~ "Because."

      # Read fresh: a struct that already holds the value makes the update a no-op.
      ctx.note.id
      |> CMS.get_field_definition!(actor: ctx.admin)
      |> CMS.update_field_definition!(%{deliver_llm: true}, actor: ctx.admin)

      KilnCMS.DataCase.drain_oban()
      assert markdown(ctx.post) =~ "Read me"
    end

    test "deleting a flagged field drops it", ctx do
      CMS.destroy_field_definition!(ctx.note, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      refute markdown(ctx.post) =~ "Read me"
    end

    test "relabelling a flagged field, and moving it, is picked up", ctx do
      CMS.update_field_definition!(ctx.note, %{label: "Renamed note"}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      assert markdown(ctx.post) =~ "## Renamed note"

      CMS.update_field_definition!(ctx.note, %{position: -1}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      assert markdown(ctx.post) =~ ~r/## Renamed note.*## FAQ/s
    end

    test "relabelling an item type or one of its sub-fields is picked up", ctx do
      CMS.update_field_definition!(ctx.qa, %{label: "Ask"}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      assert markdown(ctx.post) =~ "### Ask"

      question =
        ctx.qa |> then(&CMS.get_field_definition!(&1.id, actor: ctx.admin)) |> nested("question")

      CMS.update_field_definition!(question, %{label: "Prompt"}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      assert markdown(ctx.post) =~ "**Prompt:** Why?"
    end

    test "adding a sub-field, or deleting one, is picked up", ctx do
      sub!(ctx.admin, ctx.qa, "hint", %{label: "Hint", position: 5})
      KilnCMS.DataCase.drain_oban()

      published = CMS.get_post!(ctx.post.id, actor: ctx.admin)

      Ash.Seed.update!(published, %{
        custom_fields: %{
          ctx.faq.name => [%{"_type" => "qa", "question" => "Why?", "hint" => "Look up"}]
        }
      })

      # The new row re-fired the type, but the stored item still has no hint:
      # a later fire shows it once the document is written again.
      refute markdown(ctx.post) =~ "Look up"
      {:ok, _} = Engine.fire(CMS.get_post!(ctx.post.id, actor: ctx.admin))
      assert markdown(ctx.post) =~ "**Hint:** Look up"

      hint = ctx.qa |> then(&CMS.get_field_definition!(&1.id, actor: ctx.admin)) |> nested("hint")
      CMS.destroy_field_definition!(hint, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()
      refute markdown(ctx.post) =~ "Look up"
    end

    test "a write to a field under an unflagged owner re-fires nothing", ctx do
      other = def!(ctx.admin, %{content_type: :post, name: "o#{uniq()}", field_type: :flexible})
      item = item_type!(ctx.admin, other, "thing", %{label: "Thing"})
      KilnCMS.DataCase.drain_oban()
      before = Firing.get_artifact!(:post, ctx.post.id, :llm, authorize?: false, tenant: org())

      CMS.update_field_definition!(item, %{label: "Renamed thing"}, actor: ctx.admin)
      KilnCMS.DataCase.drain_oban()

      assert Firing.get_artifact!(:post, ctx.post.id, :llm, authorize?: false, tenant: org()).fired_at ==
               before.fired_at
    end

    defp nested(item_type, name) do
      item_type.id
      |> then(&CMS.get_field_definition!(&1, authorize?: false, load: [:group_fields]))
      |> Map.fetch!(:group_fields)
      |> Enum.find(&(&1.name == name))
    end
  end
end
