defmodule KilnCMS.CMS.ValidationLookupsAuthorizationTest do
  @moduledoc """
  The CMS validations' reference lookups run under the policies (#1659 batch
  10a), and every one of them fails CLOSED.

  Two shapes, per `KilnCMS.CMS.Validations.Lookup`:

    * **as the caller** — the release validations and the slug-pattern token
      lookup. Each is called directly with a context whose actor lacks the read
      (a viewer), because through the action the action's own policy would
      refuse that actor first and hide what the validation does. A refusal must
      come back as an error, never as `:ok`.
    * **as the system actor** — the two publish gates, which also run for the
      AshOban scheduler (no actor). `Lookup.with_actor/2` takes the grant away
      and the publish must be refused, not let through.
  """
  use KilnCMS.DataCase, async: false

  alias Ash.Resource.Validation.Context
  alias KilnCMS.CMS
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.CMS.ReleaseItem
  alias KilnCMS.CMS.TypeDefinition
  alias KilnCMS.CMS.Validations

  alias KilnCMS.CMS.Validations.Lookup

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "vlookup-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp n, do: System.unique_integer([:positive])

  defp as(actor), do: %Context{actor: actor, authorize?: true}

  defp draft_page(admin),
    do: CMS.create_page!(%{title: "Lookup #{n()}", slug: "lookup-#{n()}"}, actor: admin)

  defp add_changeset(release, page) do
    Ash.Changeset.for_create(
      ReleaseItem,
      :add,
      %{release_id: release.id, content_type: "page", content_id: page.id, action: :publish},
      authorize?: false
    )
  end

  describe "release validations read as the caller" do
    setup do
      admin = user(:admin)
      {:ok, release} = CMS.create_release(%{name: "Lookup #{n()}"}, actor: admin)
      %{admin: admin, editor: user(:editor), viewer: user(:viewer), release: release}
    end

    test "ReleaseOpenForEdit: the editor composing it passes; a refused read is Forbidden",
         %{admin: admin, editor: editor, viewer: viewer, release: release} do
      cs = add_changeset(release, draft_page(admin))

      assert :ok = Validations.ReleaseOpenForEdit.validate(cs, [], as(editor))

      assert {:error, %Ash.Error.Forbidden{}} =
               Validations.ReleaseOpenForEdit.validate(cs, [], as(viewer))
    end

    test "ReleaseContentExists: a draft the caller may not read is refused, not taken as existing",
         %{admin: admin, editor: editor, viewer: viewer, release: release} do
      cs = add_changeset(release, draft_page(admin))

      assert :ok = Validations.ReleaseContentExists.validate(cs, [], as(editor))

      # Refused like a record that does not exist: an invalid write, not a
      # Forbidden, so a type-scoped editor's error is unchanged (#332).
      assert {:error,
              %Ash.Error.Changes.InvalidAttribute{
                field: :content_id,
                message: "does not resolve to an existing record"
              }} = Validations.ReleaseContentExists.validate(cs, [], as(viewer))
    end

    test "ReleaseWithinSizeLimit: a refused count is a rejection, never a count of zero",
         %{admin: admin, editor: editor, viewer: viewer, release: release} do
      {:ok, _item} =
        CMS.add_release_item(
          %{
            release_id: release.id,
            content_type: "page",
            content_id: draft_page(admin).id,
            action: :publish
          },
          actor: admin
        )

      cs = add_changeset(release, draft_page(admin))

      previous = Application.get_env(:kiln_cms, KilnCMS.CMS.Releases)
      Application.put_env(:kiln_cms, KilnCMS.CMS.Releases, max_items: 1)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:kiln_cms, KilnCMS.CMS.Releases, previous),
          else: Application.delete_env(:kiln_cms, KilnCMS.CMS.Releases)
      end)

      # The editor's count sees the one pending item: the release is full.
      assert {:error, %Ash.Error.Changes.InvalidChanges{message: "release is full" <> _}} =
               Validations.ReleaseWithinSizeLimit.validate(cs, [], as(editor))

      # A viewer's read is refused. Under a filter it would have counted zero
      # and let the add through past the cap.
      assert {:error, %Ash.Error.Forbidden{}} =
               Validations.ReleaseWithinSizeLimit.validate(cs, [], as(viewer))
    end

    test "a caller that bypassed the action's policies reads the same way (no actor needed)",
         %{admin: admin, release: release} do
      cs = add_changeset(release, draft_page(admin))
      bypassed = %Context{actor: nil, authorize?: false}

      assert :ok = Validations.ReleaseOpenForEdit.validate(cs, [], bypassed)
      assert :ok = Validations.ReleaseContentExists.validate(cs, [], bypassed)
      assert :ok = Validations.ReleaseWithinSizeLimit.validate(cs, [], bypassed)
    end
  end

  describe "SlugPatternTokens reads field definitions as the caller" do
    # `:rating` (the fixture plugin's field type) declares `[field:rating.word]`.
    test "an admin's read finds the declared token; a refused read cannot widen the vocabulary" do
      admin = user(:admin)
      type = CMS.create_type_definition!(%{name: "vl#{n()}", label: "VL"}, actor: admin)

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "rating", label: "Rating", field_type: :rating},
        actor: admin
      )

      cs =
        Ash.Changeset.for_update(
          type,
          :update,
          %{slug_pattern: "[title]-[field:rating.word]"},
          authorize?: false
        )

      assert cs.resource == TypeDefinition
      assert :ok = Validations.SlugPatternTokens.validate(cs, [], as(admin))

      assert {:error, [field: :slug_pattern, message: _]} =
               Validations.SlugPatternTokens.validate(cs, [], as(user(:viewer)))
    end
  end

  describe "the required-consent publish gate reads as the system actor" do
    setup do
      Application.put_env(:kiln_cms, :consent, required_before_publish: [:reviewer_signoff])
      on_exit(fn -> Application.delete_env(:kiln_cms, :consent) end)

      admin = user(:admin)
      page = draft_page(admin)

      CMS.record_consent!(
        %{content_type: "page", content_id: page.id, kind: :reviewer_signoff, grantor: "Ada"},
        actor: admin
      )

      %{admin: admin, page: page}
    end

    test "with the grant, a recorded consent clears the publish", %{admin: admin, page: page} do
      assert {:ok, %{state: :published}} = CMS.publish_page(page, actor: admin)
    end

    test "without the grant, the publish is refused even though the consent exists",
         %{admin: admin, page: page} do
      assert {:error, error} =
               Lookup.with_actor(nil, fn -> CMS.publish_page(page, actor: admin) end)

      assert Exception.message(error) =~ "consents could not be checked"
      assert CMS.get_page!(page.id, authorize?: false).state == :draft
    end

    test "the system actor reads one document's consents, and may do nothing else",
         %{page: page} do
      system = Lookup.system()

      assert {:ok, [_consent]} = CMS.list_consents_for("page", page.id, actor: system)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.list_consents(actor: system, authorize_with: :error)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.record_consent(
                 %{content_type: "page", content_id: page.id, kind: :source_release},
                 actor: system
               )
    end
  end

  describe "the alt-text publish gate reads as the system actor" do
    setup do
      previous = Application.get_env(:kiln_cms, :media, [])
      Application.put_env(:kiln_cms, :media, require_alt_text: true)
      on_exit(fn -> Application.put_env(:kiln_cms, :media, previous) end)
      :ok
    end

    defp image(attrs) do
      i = n()

      Ash.Seed.seed!(
        MediaItem,
        Map.merge(
          %{filename: "vl-#{i}.png", url: "/uploads/vl-#{i}.png", content_type: "image/png"},
          attrs
        )
      )
    end

    defp page_showing(img, admin) do
      block = %{"_type" => "image", "url" => img.url, "media_id" => img.id, "alt" => nil}

      CMS.create_page!(%{title: "Alt #{n()}", slug: "alt-vl-#{n()}", blocks: [block]},
        actor: admin
      )
    end

    test "with the grant, a decorative item excuses the blank alt" do
      admin = user(:admin)
      page = page_showing(image(%{decorative: true}), admin)

      assert {:ok, %{state: :published}} = CMS.publish_page(page, actor: admin)
    end

    # A `:member` item: a public one is readable by anyone, so taking the grant
    # away would not refuse its read at all.
    test "without the grant, the publish is refused rather than read as 'not decorative'" do
      admin = user(:admin)
      page = page_showing(image(%{decorative: true, audience: :member}), admin)

      assert {:error, error} =
               Lookup.with_actor(nil, fn -> CMS.publish_page(page, actor: admin) end)

      assert Exception.message(error) =~ "alt text could not be checked"
      assert CMS.get_page!(page.id, authorize?: false).state == :draft
    end

    test "the system actor reads the plain `read`, and no wider through the library" do
      system = Lookup.system()
      held = image(%{decorative: true, quarantined: true})

      # The gate's read sees the quarantined row (its flag, not its bytes)...
      assert {:ok, %{id: id}} = CMS.get_media_item(held.id, actor: system)
      assert id == held.id

      # ...but `library` admits the system actor to nothing a stranger could
      # not read, and a quarantined item is readable by no stranger.
      assert {:ok, listed} = CMS.library_media_items(actor: system)
      refute Enum.any?(listed, &(&1.id == held.id))
    end
  end

  describe "a scheduled publish (the AshOban scheduler, no actor)" do
    test "clears both gates through the system actor" do
      Application.put_env(:kiln_cms, :consent, required_before_publish: [:reviewer_signoff])
      previous = Application.get_env(:kiln_cms, :media, [])
      Application.put_env(:kiln_cms, :media, require_alt_text: true)

      on_exit(fn ->
        Application.delete_env(:kiln_cms, :consent)
        Application.put_env(:kiln_cms, :media, previous)
      end)

      admin = user(:admin)

      img =
        Ash.Seed.seed!(MediaItem, %{
          filename: "sched.png",
          url: "/uploads/sched-#{n()}.png",
          content_type: "image/png",
          decorative: true,
          # Gated, so an actorless read could not see it: only the system
          # actor's grant lets the scheduler's gate find the flag.
          audience: :member
        })

      block = %{"_type" => "image", "url" => img.url, "media_id" => img.id, "alt" => nil}

      page =
        CMS.create_page!(%{title: "Sched #{n()}", slug: "sched-#{n()}", blocks: [block]},
          actor: admin
        )

      CMS.record_consent!(
        %{content_type: "page", content_id: page.id, kind: :reviewer_signoff, grantor: "Ada"},
        actor: admin
      )

      Ash.Seed.update!(page, %{scheduled_at: DateTime.add(DateTime.utc_now(), -60, :second)})

      AshOban.schedule_and_run_triggers(CMS.Page, drain_queues?: true, with_scheduled: true)

      assert CMS.get_page!(page.id, authorize?: false).state == :published
    end
  end
end
