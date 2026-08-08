defmodule KilnCMS.Firing.PointInTimeTest do
  @moduledoc "Point-in-time reconstruction of published content (#338)."
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Firing.PointInTime

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "pit-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "pit-#{System.unique_integer([:positive])}"

  test "reconstructs the published state as of a past date" do
    admin = admin()
    org = KilnCMS.Accounts.default_org_id()
    post = CMS.create_post!(%{title: "Original guidance", slug: slug()}, actor: admin)
    post = CMS.publish_post!(post, %{}, actor: admin)

    as_of = DateTime.utc_now()

    # Revise: unpublish → edit → republish (the workflow to change live content).
    post = CMS.unpublish_post!(post, %{}, actor: admin)
    post = CMS.update_post!(post, %{title: "Revised guidance"}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    assert {:ok, historical, published_at} =
             PointInTime.read(org, CMS.Post, post.id, :json, as_of)

    assert historical["title"] == "Original guidance"
    assert %DateTime{} = published_at

    assert {:ok, current, _} = PointInTime.read(org, CMS.Post, post.id, :json, DateTime.utc_now())
    assert current["title"] == "Revised guidance"
  end

  test "fires any surface for the historical state" do
    admin = admin()
    org = KilnCMS.Accounts.default_org_id()
    post = CMS.create_post!(%{title: "Heading", slug: slug()}, actor: admin)
    CMS.publish_post!(post, %{}, actor: admin)

    assert {:ok, %{"@context" => "https://schema.org"}, _} =
             PointInTime.read(org, CMS.Post, post.id, :json_ld, DateTime.utc_now())
  end

  test "returns not_published before the first publish" do
    admin = admin()
    org = KilnCMS.Accounts.default_org_id()
    post = CMS.create_post!(%{title: "Draft only", slug: slug()}, actor: admin)
    before_publish = DateTime.utc_now()
    CMS.publish_post!(post, %{}, actor: admin)

    assert {:error, :not_published} =
             PointInTime.read(org, CMS.Post, post.id, :json, before_publish)
  end

  describe "index/4 — the collection as of a date (#338 phase 2)" do
    test "lists what was published then, respects unpublish, and replays titles" do
      admin = admin()

      a = CMS.create_post!(%{title: "Alpha v1", slug: slug()}, actor: admin)
      a = CMS.publish_post!(a, %{}, actor: admin)
      b = CMS.create_post!(%{title: "Beta", slug: slug()}, actor: admin)
      b = CMS.publish_post!(b, %{}, actor: admin)

      both_live = DateTime.utc_now()

      # Later: B is unpublished and A is renamed (without re-publishing).
      CMS.unpublish_post!(b, %{}, actor: admin)
      CMS.update_post!(a, %{title: "Alpha v2"}, actor: admin)
      after_changes = DateTime.utc_now()

      org = a.org_id

      then_entries = PointInTime.index(org, CMS.Post, both_live)
      then_slugs = Enum.map(then_entries, & &1.slug)
      assert a.slug in then_slugs
      assert b.slug in then_slugs
      # Title as of the last publish ≤ as_of — not today's rename.
      assert %{title: "Alpha v1"} = Enum.find(then_entries, &(&1.slug == a.slug))

      now_entries = PointInTime.index(org, CMS.Post, after_changes)
      now_slugs = Enum.map(now_entries, & &1.slug)
      assert a.slug in now_slugs
      refute b.slug in now_slugs
    end

    test "the REST collection route and the GraphQL twin agree" do
      admin = admin()
      post = CMS.create_post!(%{title: "Twin", slug: slug()}, actor: admin)
      CMS.publish_post!(post, %{}, actor: admin)
      as_of = DateTime.utc_now() |> DateTime.to_iso8601()

      rest =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.dispatch(KilnCMSWeb.Endpoint, :get, "/api/content/post", %{
          "as_of" => as_of
        })

      assert rest.status == 200
      body = Jason.decode!(rest.resp_body)
      assert Enum.any?(body["entries"], &(&1["slug"] == post.slug and &1["title"] == "Twin"))
      assert Enum.all?(body["entries"], &String.contains?(&1["href"], "as_of="))

      gql =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.dispatch(KilnCMSWeb.Endpoint, :post, "/gql", %{
          "query" => """
          query($asOf: DateTime!) {
            contentAsOf(type: "post", asOf: $asOf) { slug title publishedAt }
          }
          """,
          "variables" => %{"asOf" => as_of}
        })

      assert %{"data" => %{"contentAsOf" => entries}} = Jason.decode!(gql.resp_body)
      assert Enum.any?(entries, &(&1["slug"] == post.slug and &1["title"] == "Twin"))
    end

    test "the collection route requires as_of and validates it" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.dispatch(KilnCMSWeb.Endpoint, :get, "/api/content/post", %{})

      assert conn.status == 400
      assert conn.resp_body =~ "missing_as_of"

      bad =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.dispatch(KilnCMSWeb.Endpoint, :get, "/api/content/post", %{
          "as_of" => "not-a-date"
        })

      assert bad.status == 400
    end
  end

  # Found while fixing the fragment case, and strictly bigger than it: a union
  # attribute lands in a paper-trail version's freeform `changes` map in its
  # JSON shape (`%{"type" => tag, "value" => …}`), which `to_typed/1` did not
  # recognize — so EVERY block in a replayed document came back as `Custom`.
  # A historical read rendered a generic fallback for every heading, quote and
  # image it had ever published.
  test "replayed blocks keep their real types, not Custom (#917)" do
    admin = admin()
    org = KilnCMS.Accounts.default_org_id()

    page =
      CMS.create_page!(
        %{
          title: "Typed",
          slug: slug(),
          blocks: [
            %{"_type" => "heading", "text" => "Head", "level" => 2},
            %{"_type" => "quote", "text" => "Quoted"}
          ]
        },
        actor: admin
      )

    CMS.publish_page!(page, %{}, actor: admin)
    as_of = DateTime.utc_now()

    assert {:ok, state} = PointInTime.snapshot_state(org, CMS.Page, page.id, as_of)

    assert Enum.map(KilnCMS.CMS.TypedBlocks.to_typed(state["blocks"]), & &1.__struct__) == [
             KilnCMS.Blocks.Heading,
             KilnCMS.Blocks.Quote
           ]

    # …and the artifact renders them as themselves.
    assert {:ok, artifact, _} = PointInTime.read(org, CMS.Page, page.id, :web, as_of)
    assert artifact["html"] =~ "<h2>Head</h2>"
    assert artifact["html"] =~ "<blockquote>Quoted</blockquote>"
  end

  describe "fragments are reconstructed as they were, not as they are (#917)" do
    # `Fragments.expand/3` reads the target's CURRENT published blocks, so a
    # historical read returned the fragment as edited today — or an empty
    # `blocks` array where the content was, if the target has since been
    # unpublished. Both are silent wrong answers on the one endpoint whose
    # entire promise is "what did this say on…".
    defp fragment_ref(record),
      do: %{"_type" => "fragment", "ref" => %{"type" => "page", "id" => record.id}}

    test "an edited fragment reads as its body at as_of, not today's" do
      admin = admin()
      org = KilnCMS.Accounts.default_org_id()

      shared =
        CMS.create_page!(
          %{title: "Shared", slug: slug(), blocks: [%{"_type" => "heading", "text" => "Then"}]},
          actor: admin
        )

      shared = CMS.publish_page!(shared, %{}, actor: admin)

      host =
        CMS.create_page!(
          %{title: "Host", slug: slug(), blocks: [fragment_ref(shared)]},
          actor: admin
        )

      CMS.publish_page!(host, %{}, actor: admin)

      as_of = DateTime.utc_now()

      # Edit the fragment after the snapshot instant.
      shared = CMS.unpublish_page!(shared, %{}, actor: admin)

      shared =
        CMS.update_page!(shared, %{blocks: [%{"_type" => "heading", "text" => "Now"}]},
          actor: admin
        )

      CMS.publish_page!(shared, %{}, actor: admin)

      assert {:ok, historical, _} = PointInTime.read(org, CMS.Page, host.id, :web, as_of)

      assert historical["html"] =~ "Then"
      refute historical["html"] =~ "Now"
    end

    test "a fragment withdrawn since still reads at as_of" do
      # The other direction, and the one that silently emptied the body: the
      # target is gone today, so a live read expands it to nothing — but it was
      # published at `as_of`, so the historical answer must still carry it.
      admin = admin()
      org = KilnCMS.Accounts.default_org_id()

      shared =
        CMS.create_page!(
          %{
            title: "Shared",
            slug: slug(),
            blocks: [%{"_type" => "heading", "text" => "Was live"}]
          },
          actor: admin
        )

      shared = CMS.publish_page!(shared, %{}, actor: admin)

      host =
        CMS.create_page!(
          %{title: "Host", slug: slug(), blocks: [fragment_ref(shared)]},
          actor: admin
        )

      CMS.publish_page!(host, %{}, actor: admin)

      as_of = DateTime.utc_now()
      CMS.unpublish_page!(shared, %{}, actor: admin)

      assert {:ok, historical, _} = PointInTime.read(org, CMS.Page, host.id, :web, as_of)
      assert historical["html"] =~ "Was live"
    end

    test "a fragment not yet published at as_of stays absent" do
      admin = admin()
      org = KilnCMS.Accounts.default_org_id()

      host_before =
        CMS.create_page!(%{title: "Host", slug: slug(), blocks: []}, actor: admin)

      host_before = CMS.publish_page!(host_before, %{}, actor: admin)

      shared =
        CMS.create_page!(
          %{title: "Shared", slug: slug(), blocks: [%{"_type" => "heading", "text" => "Later"}]},
          actor: admin
        )

      shared = CMS.publish_page!(shared, %{}, actor: admin)

      as_of = DateTime.utc_now()

      # The host gains the fragment only after the snapshot instant.
      host = CMS.unpublish_page!(host_before, %{}, actor: admin)
      host = CMS.update_page!(host, %{blocks: [fragment_ref(shared)]}, actor: admin)
      CMS.publish_page!(host, %{}, actor: admin)

      assert {:ok, historical, _} = PointInTime.read(org, CMS.Page, host_before.id, :web, as_of)
      refute historical["html"] =~ "Later"
    end
  end
end
