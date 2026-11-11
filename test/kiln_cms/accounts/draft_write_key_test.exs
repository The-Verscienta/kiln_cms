defmodule KilnCMS.Accounts.DraftWriteKeyTest do
  @moduledoc """
  The `:draft_write` API-key scope (#2273): a headless service may create drafts
  and edit its own drafts, and nothing else — whatever its owner's role is at the
  moment of the request.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.Checks.DraftWriteKey
  alias KilnCMS.CMS
  alias KilnCMS.CMS.MediaItem
  alias KilnCMS.CMS.Post

  defp user(role) do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "dw-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp mint(owner, access \\ :draft_write, days \\ 7) do
    Accounts.mint_api_key(
      owner.id,
      "svc",
      DateTime.add(DateTime.utc_now(), days, :day),
      %{access: access},
      actor: user(:admin)
    )
  end

  # The actor a request authenticated by `plaintext` runs as.
  defp key_actor(plaintext) do
    {:ok, actor} = Accounts.actor_from_api_key(plaintext)
    actor
  end

  defp key_actor_for(owner) do
    {:ok, key} = mint(owner)
    key_actor(Ash.Resource.get_metadata(key, :plaintext_api_key))
  end

  # Seeded directly so fixtures don't depend on the policies under test.
  defp post(attrs) do
    Ash.Seed.seed!(
      Post,
      Map.merge(%{title: "T", slug: "dw-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  setup do
    owner = user(:viewer)
    {:ok, key} = mint(owner)
    plaintext = Ash.Resource.get_metadata(key, :plaintext_api_key)
    {:ok, owner: owner, plaintext: plaintext, actor: key_actor(plaintext)}
  end

  test "the actor carries a draft-write key", %{actor: actor} do
    assert actor.__metadata__.api_key.access == :draft_write
    assert DraftWriteKey.match?(actor, %{}, [])
  end

  describe "what it may do" do
    test "create a draft, authored by the key owner", %{owner: owner, actor: actor} do
      assert {:ok, post} = CMS.create_post(%{title: "From the app"}, actor: actor)
      assert post.state == :draft
      assert post.author_id == owner.id
    end

    test "update its own draft", %{owner: owner, actor: actor} do
      draft = post(%{state: :draft, author_id: owner.id})
      assert {:ok, updated} = CMS.update_post(draft, %{title: "Edited"}, actor: actor)
      assert updated.title == "Edited"
    end

    test "autosave its own draft", %{owner: owner, actor: actor} do
      draft = post(%{state: :draft, author_id: owner.id})

      # `:autosave` has no domain interface (the editor and the collab
      # checkpoint call it through a changeset).
      assert {:ok, saved} =
               draft
               |> Ash.Changeset.for_update(:autosave, %{title: "Autosaved"}, actor: actor)
               |> Ash.update()

      assert saved.title == "Autosaved"
    end

    test "still drafts after its owner is promoted to admin, but cannot publish",
         %{owner: owner, plaintext: plaintext} do
      Ash.Seed.update!(owner, %{role: :admin})
      promoted = key_actor(plaintext)
      assert promoted.role == :admin

      assert {:ok, draft} = CMS.create_post(%{title: "Still a draft"}, actor: promoted)
      refute CMS.can_publish_post?(promoted, draft)
      assert {:error, %Ash.Error.Forbidden{}} = CMS.publish_post(draft, %{}, actor: promoted)
      refute CMS.can_unpublish_post?(promoted, draft)
      refute CMS.can_destroy_post?(promoted, draft)
      refute CMS.can_purge_post?(promoted, draft)
    end

    test "a promoted owner still cannot edit another's draft or a live document",
         %{owner: owner, plaintext: plaintext} do
      Ash.Seed.update!(owner, %{role: :admin})
      promoted = key_actor(plaintext)

      refute CMS.can_update_post?(promoted, post(%{state: :draft, author_id: user(:editor).id}))
      refute CMS.can_update_post?(promoted, post(%{state: :published, author_id: owner.id}))
    end
  end

  describe "what it may not do" do
    test "touch another author's draft", %{actor: actor} do
      other = post(%{state: :draft, author_id: user(:editor).id})

      refute CMS.can_update_post?(actor, other)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_post(other, %{title: "Mine now"}, actor: actor)

      refute Ash.can?({other, :autosave}, actor)
    end

    test "touch a draft with no author", %{actor: actor} do
      refute CMS.can_update_post?(actor, post(%{state: :draft, author_id: nil}))
    end

    test "touch a document that is not a draft, even its own", %{owner: owner, actor: actor} do
      for state <- [:published, :in_review, :archived] do
        record = post(%{state: state, author_id: owner.id})
        refute CMS.can_update_post?(actor, record), "updated a #{state} post"
        refute Ash.can?({record, :autosave}, actor), "autosaved a #{state} post"
      end
    end

    test "touch a live document that has a pending working copy (Live · draft)",
         %{owner: owner, actor: actor} do
      live =
        post(%{state: :published, author_id: owner.id, working_copy_at: DateTime.utc_now()})

      refute CMS.can_update_post?(actor, live)
      refute Ash.can?({live, :autosave}, actor)
      refute Ash.can?({live, :save_working_copy}, actor)
      refute Ash.can?({live, :publish_changes}, actor)
    end

    test "run any action outside the allowlist, on its own draft or a published row",
         %{owner: owner, actor: actor} do
      own_draft = post(%{state: :draft, author_id: owner.id})
      own_live = post(%{state: :published, author_id: owner.id})

      actions = Ash.Resource.Info.actions(Post)
      allowed = DraftWriteKey.allowed_actions()

      # Enumerated, not listed: an action added to Content later must be
      # refused to this key until the allowlist names it.
      offenders =
        for %{type: type, name: name} <- actions,
            type in [:update, :destroy],
            name not in allowed,
            record <- [own_draft, own_live],
            Ash.can?({record, name}, actor),
            do: {name, record.state}

      assert offenders == []
      assert Enum.count(actions, &(&1.type in [:update, :destroy])) > 20
    end

    test "run the workflow transitions by name", %{actor: actor} do
      for name <- [:submit_for_review, :publish, :archive, :unpublish, :purge, :destroy] do
        refute Ash.can?({post(%{state: :draft}), name}, actor), "#{name} was allowed"
      end
    end

    test "submit its own draft for review (default deny)", %{owner: owner, actor: actor} do
      refute CMS.can_submit_post_for_review?(actor, post(%{state: :draft, author_id: owner.id}))
    end

    test "set a publish date on create or update", %{owner: owner, actor: actor} do
      later = DateTime.add(DateTime.utc_now(), 1, :day)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.create_post(%{title: "Timed", scheduled_at: later}, actor: actor)

      draft = post(%{state: :draft, author_id: owner.id})

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.update_post(draft, %{scheduled_at: later}, actor: actor)
    end

    test "link tags on a draft it creates", %{actor: actor} do
      admin = user(:admin)
      n = System.unique_integer([:positive])
      tag = CMS.create_tag!(%{name: "T#{n}", slug: "t-#{n}"}, actor: admin)

      result = CMS.create_post(%{title: "Tagged", tag_ids: [tag.id]}, actor: actor)
      assert {:error, %Ash.Error.Forbidden{}} = result
    end

    test "write media", %{actor: actor} do
      refute CMS.can_create_media_item?(actor, %{filename: "x.jpg"})
      item = Ash.Seed.seed!(MediaItem, media_attrs())
      refute CMS.can_update_media_item?(actor, item)
      refute CMS.can_destroy_media_item?(actor, item)
      refute CMS.can_purge_media_item?(actor, item)
    end

    test "read other authors' unpublished content", %{actor: actor} do
      other = post(%{state: :draft, author_id: user(:editor).id})
      mine_elsewhere = post(%{state: :in_review, author_id: user(:editor).id})

      ids = Enum.map(CMS.list_posts!(actor: actor), & &1.id)
      refute other.id in ids
      refute mine_elsewhere.id in ids
      assert {:error, _} = CMS.get_post(other.id, actor: actor)
    end
  end

  describe "reading its own drafts" do
    import ExUnit.CaptureLog

    test "reads the drafts it authored, and published content", %{owner: owner, actor: actor} do
      mine = post(%{state: :draft, author_id: owner.id})
      live = post(%{state: :published, author_id: user(:editor).id})

      ids = Enum.map(CMS.list_posts!(actor: actor), & &1.id)
      assert mine.id in ids
      assert live.id in ids
      assert {:ok, _} = CMS.get_post(mine.id, actor: actor)
    end

    test "does not read others' drafts or any unpublished state but its own draft",
         %{owner: owner, actor: actor} do
      editor = user(:editor)

      hidden =
        [
          post(%{state: :draft, author_id: editor.id}),
          post(%{state: :draft, author_id: nil}),
          post(%{state: :in_review, author_id: owner.id}),
          post(%{state: :in_review, author_id: editor.id}),
          post(%{state: :archived, author_id: owner.id}),
          post(%{state: :archived, author_id: editor.id})
        ]

      ids = Enum.map(CMS.list_posts!(actor: actor), & &1.id)

      for record <- hidden do
        refute record.id in ids, "read a #{record.state} post"
        assert {:error, _} = CMS.get_post(record.id, actor: actor)
      end
    end

    test "another actor's draft stays invisible to a viewer and to a read key", %{owner: owner} do
      mine = post(%{state: :draft, author_id: owner.id})
      read_key = mint(owner, :read) |> elem(1) |> Ash.Resource.get_metadata(:plaintext_api_key)

      refute mine.id in Enum.map(CMS.list_posts!(actor: key_actor(read_key)), & &1.id)
      refute mine.id in Enum.map(CMS.list_posts!(actor: owner), & &1.id)
    end

    test "reads the versions of its own drafts, not anyone else's",
         %{owner: owner, actor: actor} do
      editor = user(:editor)
      mine = CMS.create_post!(%{title: "Mine"}, actor: key_actor_for(owner))
      theirs = CMS.create_post!(%{title: "Theirs"}, actor: editor)

      sources =
        Post.Version
        |> Ash.read!(actor: actor)
        |> Enum.map(& &1.version_source_id)
        |> Enum.uniq()

      assert mine.id in sources
      refute theirs.id in sources
    end

    test "a second key on the same owner reads no provenance through version history",
         %{owner: owner, actor: key_a} do
      key_b = key_actor_for(owner)

      draft =
        CMS.create_post!(%{title: "From A"},
          actor: key_a,
          context: %{kiln_on_behalf_of: "end-user-of-a"}
        )

      assert draft.on_behalf_of == "end-user-of-a"
      assert draft.created_via_key_id == key_a.__metadata__.api_key.id

      # B edits A's draft (same owner), so it keeps reading that history:
      # its autosaves coalesce over it.
      draft
      |> Ash.Changeset.for_update(:autosave, %{title: "B 1"}, actor: key_b)
      |> Ash.update!()
      |> Ash.Changeset.for_update(:autosave, %{title: "B 2"}, actor: key_b)
      |> Ash.update!()

      versions =
        Post.Version
        |> Ash.read!(actor: key_b)
        |> Enum.filter(&(&1.version_source_id == draft.id))

      assert Enum.any?(versions, &(&1.version_action_name == :create))
      assert Enum.count(versions, &(&1.version_action_name == :autosave)) == 1

      # ...but A's provenance is in none of it, raw or folded.
      provenance = ~w(created_via_key_id created_via_key_name on_behalf_of)

      for version <- versions do
        keys = version.changes |> Map.keys() |> Enum.map(&to_string/1)
        assert keys -- provenance == keys, "version #{version.id} carries #{inspect(keys)}"
        refute inspect(version.changes) =~ "end-user-of-a"
      end
    end

    test "loses the versions of a draft once a person moves it out of draft",
         %{owner: owner, actor: actor} do
      mine = CMS.create_post!(%{title: "Mine"}, actor: key_actor_for(owner))
      Ash.Seed.update!(mine, %{state: :in_review})

      sources = Post.Version |> Ash.read!(actor: actor) |> Enum.map(& &1.version_source_id)
      refute mine.id in sources
    end

    test "autosave coalescing reads the history as the key and logs no failure",
         %{owner: owner, actor: actor} do
      draft = CMS.create_post!(%{title: "Autosaved"}, actor: actor)
      assert draft.author_id == owner.id

      log =
        capture_log(fn ->
          Enum.reduce(1..3, draft, fn n, current ->
            current
            |> Ash.Changeset.for_update(:autosave, %{title: "Autosave #{n}"}, actor: actor)
            |> Ash.update!()
          end)
        end)

      refute log =~ "Autosave version coalescing failed"

      autosaves =
        Post.Version
        |> Ash.read!(actor: actor)
        |> Enum.filter(
          &(&1.version_source_id == draft.id and &1.version_action_name == :autosave)
        )

      assert length(autosaves) == 1
    end
  end

  describe "minting" do
    test "succeeds for a viewer-tier owner within the lifetime cap", %{owner: owner} do
      assert {:ok, key} = mint(owner, :draft_write, 30)
      assert key.access == :draft_write
    end

    test "refuses a lifetime past the cap", %{owner: owner} do
      assert {:error, %Ash.Error.Invalid{} = error} = mint(owner, :draft_write, 31)
      assert Exception.message(error) =~ "at most 30 days"
    end

    # "The cap is configurable" lives in KilnCMS.Accounts.DraftWriteKeyConfigTest:
    # it rewrites VM-global config, so it cannot run beside async tests (#2380).

    test "other scopes keep their own lifetimes", %{owner: owner} do
      assert {:ok, _} = mint(owner, :read, 365)
    end

    test "refuses editor and admin owners" do
      for role <- [:editor, :admin] do
        assert {:error, %Ash.Error.Invalid{} = error} = mint(user(role))
        assert Exception.message(error) =~ "cannot edit or publish"
      end
    end

    test "refuses an owner who is an editor in some organization" do
      owner = user(:viewer)
      org = Accounts.default_org()

      Ash.Seed.seed!(Accounts.OrgMembership, %{
        user_id: owner.id,
        organization_id: org.id,
        role: :editor
      })

      assert {:error, %Ash.Error.Invalid{}} = mint(owner)
    end

    test "refuses an owner with a live temporary elevation" do
      owner = user(:viewer)

      Ash.Seed.update!(owner, %{
        granted_role: :editor,
        granted_role_expires_at: DateTime.add(DateTime.utc_now(), 1, :day)
      })

      assert {:error, %Ash.Error.Invalid{}} = mint(owner)
    end

    test "only an admin may mint one", %{owner: owner} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.mint_api_key(
                 owner.id,
                 "self",
                 DateTime.add(DateTime.utc_now(), 1, :day),
                 %{access: :draft_write},
                 actor: user(:editor)
               )
    end
  end

  defp media_attrs do
    %{
      filename: "photo.jpg",
      content_type: "image/jpeg",
      byte_size: 1024,
      storage_key: "photo-#{System.unique_integer([:positive])}.jpg",
      url: "/uploads/photo.jpg"
    }
  end
end
