defmodule KilnCMS.CMS.TeaserReadTest do
  @moduledoc """
  The two new delivery reads (#337 Phase 2): the `:audiences` widening on
  `:public_by_slug`, and the paywall-safe `:teaser_by_slug`.

  These filters are the **sole** security boundary — both actions are consumed
  with `authorize?: false` on the anonymous delivery path — so the negative cases
  here carry the weight.
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Audiences
  alias KilnCMS.CMS.ContentTypes

  @gated hd(Audiences.gated())

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "teaser-admin-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp post(attrs) do
    actor = admin()

    {:ok, post} =
      CMS.create_post(
        Map.merge(
          %{
            title: "Gated piece",
            slug: "gated-#{System.unique_integer([:positive])}",
            excerpt: "A teaser sentence.",
            seo_description: "SEO description.",
            blocks: [%{"_type" => "heading", "text" => "SECRET-BODY-TEXT", "level" => 2}]
          },
          attrs
        ),
        actor: actor
      )

    {:ok, published} = CMS.publish_post(post, %{}, actor: actor)
    published
  end

  describe ":audiences widening on public_by_slug" do
    test "a gated post is NOT served without the audience" do
      p = post(%{audience: @gated})

      assert {:ok, nil} =
               CMS.get_published_post_by_slug(p.slug, p.locale, %{audiences: []},
                 authorize?: false,
                 not_found_error?: false
               )
    end

    test "the argument defaults to [] — every existing caller is unchanged" do
      # This is the safety property of adding an argument rather than switching
      # delivery to policy-based authorization.
      p = post(%{audience: @gated})

      assert {:ok, nil} =
               CMS.get_published_post_by_slug(p.slug, p.locale,
                 authorize?: false,
                 not_found_error?: false
               )
    end

    test "a gated post IS served with the matching audience" do
      p = post(%{audience: @gated})

      assert {:ok, found} =
               CMS.get_published_post_by_slug(p.slug, p.locale, %{audiences: [@gated]},
                 authorize?: false,
                 not_found_error?: false
               )

      assert found.id == p.id
    end

    test "a public post is still served with no audiences" do
      p = post(%{audience: :public})

      assert {:ok, found} =
               CMS.get_published_post_by_slug(p.slug, p.locale, %{audiences: []},
                 authorize?: false,
                 not_found_error?: false
               )

      assert found.id == p.id
    end

    test "an unrelated audience does not unlock it" do
      other = Enum.find(Audiences.all(), &(&1 not in [:public, @gated]))
      p = post(%{audience: @gated})

      if other do
        assert {:ok, nil} =
                 CMS.get_published_post_by_slug(p.slug, p.locale, %{audiences: [other]},
                   authorize?: false,
                   not_found_error?: false
                 )
      end
    end

    test "an unconfigured audience is rejected by the constraint" do
      p = post(%{audience: @gated})

      assert_raise Ash.Error.Invalid, fn ->
        CMS.get_published_post_by_slug!(p.slug, p.locale, %{audiences: [:not_an_audience]},
          authorize?: false,
          not_found_error?: false
        )
      end
    end

    test "a DRAFT gated post is not served even with the audience" do
      actor = admin()

      {:ok, draft} =
        CMS.create_post(
          %{
            title: "Draft",
            slug: "draft-#{System.unique_integer([:positive])}",
            audience: @gated
          },
          actor: actor
        )

      assert {:ok, nil} =
               CMS.get_published_post_by_slug(draft.slug, draft.locale, %{audiences: [@gated]},
                 authorize?: false,
                 not_found_error?: false
               )
    end
  end

  describe "teaser_by_slug" do
    test "finds a gated published post" do
      p = post(%{audience: @gated})

      assert {:ok, teaser} =
               CMS.get_post_teaser_by_slug(p.slug, p.locale,
                 authorize?: false,
                 not_found_error?: false
               )

      assert teaser.id == p.id
      assert teaser.title == p.title
      assert teaser.excerpt == "A teaser sentence."
    end

    test "NEVER carries the block tree" do
      # The projection that makes the paywall safe: `blocks` is omitted from the
      # action's select, so it is never fetched at all.
      p = post(%{audience: @gated})

      {:ok, teaser} =
        CMS.get_post_teaser_by_slug(p.slug, p.locale,
          authorize?: false,
          not_found_error?: false
        )

      assert %Ash.NotLoaded{} = teaser.blocks
      refute inspect(teaser) =~ "SECRET-BODY-TEXT"
    end

    test "does NOT find a public post — it cannot stand in for public_by_slug" do
      p = post(%{audience: :public})

      assert {:ok, nil} =
               CMS.get_post_teaser_by_slug(p.slug, p.locale,
                 authorize?: false,
                 not_found_error?: false
               )
    end

    test "does not find a draft" do
      actor = admin()

      {:ok, draft} =
        CMS.create_post(
          %{
            title: "Draft",
            slug: "draft-#{System.unique_integer([:positive])}",
            audience: @gated
          },
          actor: actor
        )

      assert {:ok, nil} =
               CMS.get_post_teaser_by_slug(draft.slug, draft.locale,
                 authorize?: false,
                 not_found_error?: false
               )
    end

    test "is reachable through the generic type dispatch" do
      p = post(%{audience: @gated})

      assert %{} =
               teaser =
               ContentTypes.get_teaser_by_slug(:post, p.slug, p.locale,
                 authorize?: false,
                 not_found_error?: false
               )

      assert teaser.id == p.id
    end
  end

  describe "the Teaser projection" do
    test "has no blocks field at all" do
      # A one-line guarantee that cannot be satisfied by accident: even if the
      # read were widened, the template could not render a block.
      # `__struct__/0` rather than `%Teaser{}` — the struct has `@enforce_keys`.
      fields = KilnCMSWeb.Teaser.__struct__() |> Map.keys()

      refute :blocks in fields
      refute :body in fields
    end

    test "summary falls back from excerpt to seo_description" do
      p = post(%{audience: @gated, excerpt: nil, seo_description: "Only the SEO line."})

      {:ok, record} =
        CMS.get_post_teaser_by_slug(p.slug, p.locale,
          authorize?: false,
          not_found_error?: false
        )

      teaser = KilnCMSWeb.Teaser.from_record(record, "https://example.test/blog/x")
      assert teaser.summary == "Only the SEO line."
    end

    test "summary is nil when neither is present, rather than invented" do
      # Never synthesised from block 1 — that would require selecting `blocks`.
      p = post(%{audience: @gated, excerpt: nil, seo_description: nil})

      {:ok, record} =
        CMS.get_post_teaser_by_slug(p.slug, p.locale,
          authorize?: false,
          not_found_error?: false
        )

      teaser = KilnCMSWeb.Teaser.from_record(record, "https://example.test/blog/x")
      refute teaser.summary
    end
  end
end
