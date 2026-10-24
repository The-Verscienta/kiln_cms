defmodule KilnCMS.Delivery.FeedTest do
  @moduledoc """
  #2050 (2.1): the public change feed publishes `published` / `updated` /
  `withdrawn` per site over PubSub, from the webhook funnel, carrying
  identifiers and never content.
  """
  # Other async tests publish to the default site's feed too, so every
  # assertion here matches on the document's own id.
  use KilnCMS.DataCase, async: true

  alias KilnCMS.CMS
  alias KilnCMS.Delivery.Feed
  alias KilnCMS.Delivery.Feed.Event

  @moduletag :capture_log

  setup do
    :ok = Feed.subscribe(org())
    :ok
  end

  defp org, do: KilnCMS.Accounts.default_org_id()

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "feed-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "feed-#{System.unique_integer([:positive])}"

  defp draft!(admin, attrs \\ %{}),
    do: CMS.create_page!(Map.merge(%{title: "Dose", slug: slug()}, attrs), actor: admin)

  defp published!(admin, attrs \\ %{}),
    do: admin |> draft!(attrs) |> CMS.publish_page!(%{}, actor: admin)

  # Every feed event for document `id` already in the mailbox, oldest first.
  defp events_for(id) do
    receive do
      {:kiln_feed, %Event{id: ^id} = event} -> [event | events_for(id)]
    after
      0 -> []
    end
  end

  describe "transitions" do
    test "publishing emits `published`, with identifiers and no content" do
      admin = admin()
      page = published!(admin)

      assert [%Event{kind: :published} = event] = events_for(page.id)
      assert event.type == "page"
      assert event.slug == page.slug
      assert event.locale == "en"
      assert %DateTime{} = event.published_at
      assert %DateTime{} = event.at
      assert event.public == true
      assert event.affected == []

      # The struct is the whole message: no title, excerpt, blocks or SEO.
      assert event |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
               ~w(affected at id kind locale public published_at slug type)a

      encoded = Jason.encode!(event)
      refute encoded =~ "Dose"
    end

    test "editing live content emits `updated`; editing a draft emits nothing" do
      admin = admin()
      page = published!(admin)
      _ = events_for(page.id)

      CMS.update_page!(page, %{title: "Dose, revised"}, actor: admin)
      assert [%Event{kind: :updated}] = events_for(page.id)

      draft = draft!(admin)
      CMS.update_page!(draft, %{title: "Still private"}, actor: admin)
      assert events_for(draft.id) == []
    end

    test "unpublishing emits `withdrawn`" do
      admin = admin()
      page = published!(admin)
      _ = events_for(page.id)

      CMS.unpublish_page!(page, %{}, actor: admin)
      assert [%Event{kind: :withdrawn, slug: slug}] = events_for(page.id)
      assert slug == page.slug
    end

    test "archiving a live document withdraws it once; archiving a draft is silent" do
      admin = admin()
      page = published!(admin)
      _ = events_for(page.id)

      # `:archive` fires `unpublished` and `archived`: one withdrawal, not two.
      CMS.archive_page!(page, %{}, actor: admin)
      assert [%Event{kind: :withdrawn}] = events_for(page.id)

      draft = draft!(admin)
      CMS.archive_page!(draft, %{}, actor: admin)
      assert events_for(draft.id) == []
    end

    test "trashing a live document withdraws it; restoring it publishes it again" do
      admin = admin()
      live = published!(admin)
      _ = events_for(live.id)

      CMS.destroy_page!(live, actor: admin)
      # A delete's tombstone carries no audience, so `public` cannot be shown.
      assert [%Event{kind: :withdrawn, public: nil, affected: []}] = events_for(live.id)

      [trashed] = CMS.list_trashed_pages!(actor: admin, query: [filter: [id: live.id]])
      CMS.restore_page!(trashed, actor: admin)
      assert [%Event{kind: :published}] = events_for(live.id)
    end

    test "a draft's lifecycle emits nothing" do
      admin = admin()
      draft = draft!(admin)
      draft = CMS.submit_page_for_review!(draft, actor: admin)
      CMS.destroy_page!(draft, actor: admin)

      [trashed] = CMS.list_trashed_pages!(actor: admin, query: [filter: [id: draft.id]])
      CMS.restore_page!(trashed, actor: admin)

      assert events_for(draft.id) == []
    end

    test "a members-only document is on the feed, marked not public" do
      admin = admin()
      page = published!(admin, %{audience: :member})

      assert [%Event{kind: :published, public: false}] = events_for(page.id)
    end

    test "a passphrase-locked document is marked not public" do
      admin = admin()
      page = published!(admin)
      _ = events_for(page.id)

      CMS.update_page!(page, %{access_password: "shared secret"}, actor: admin)
      assert [%Event{kind: :updated, public: false}] = events_for(page.id)
    end
  end

  describe "kind/3" do
    test "maps the webhook verbs the feed carries" do
      live = %{state: :published}
      tombstone = %{state: :draft}

      assert Feed.kind("page.published", live, false) == :published
      assert Feed.kind("page.updated", live, true) == :updated
      assert Feed.kind("page.updated", tombstone, false) == nil
      assert Feed.kind("page.restored", live, false) == :published
      assert Feed.kind("page.restored", tombstone, false) == nil
      assert Feed.kind("page.unpublished", tombstone, true) == :withdrawn
      assert Feed.kind("page.deleted", tombstone, true) == :withdrawn
      assert Feed.kind("page.deleted", tombstone, false) == nil
      assert Feed.kind("page.archived", tombstone, true) == nil
      assert Feed.kind("page.created", tombstone, false) == nil
      assert Feed.kind("page.in_review", tombstone, false) == nil
    end

    test "domain and taxonomy events are not a document's" do
      assert Feed.kind("release.published", %{}, true) == nil
      assert Feed.kind("tag.updated", %{state: :published}, true) == nil
      assert Feed.kind("tag.deleted", %{}, true) == nil
      assert Feed.kind("ping", %{}, true) == nil
    end
  end

  describe "publish/4" do
    test "is per site" do
      other = Ecto.UUID.generate()
      id = Ecto.UUID.generate()

      Feed.publish("page.published", %{id: id, state: :published}, other)
      assert events_for(id) == []

      :ok = Feed.subscribe(other)
      Feed.publish("page.published", %{id: id, state: :published}, other)
      assert [%Event{kind: :published}] = events_for(id)
    end

    test "keeps identity only from `affected`, and reads string-keyed payloads" do
      id = Ecto.UUID.generate()
      ref = Ecto.UUID.generate()

      Feed.publish(
        "page.updated",
        %{
          "id" => id,
          "state" => "published",
          "slug" => "herb",
          "audience" => "public",
          "locked" => false,
          "title" => "Not carried",
          "affected" => [
            %{"type" => "formula", "id" => ref, "slug" => "f", "locale" => "en", "title" => "No"}
          ]
        },
        org(),
        true
      )

      assert [%Event{kind: :updated, slug: "herb", public: true, affected: [affected]}] =
               events_for(id)

      assert affected == %{type: "formula", id: ref, slug: "f", locale: "en"}
    end

    test "emits the telemetry event once per broadcast" do
      test_pid = self()
      handler = "feed-test-#{System.unique_integer([:positive])}"
      id = Ecto.UUID.generate()

      :telemetry.attach(
        handler,
        Feed.telemetry_event(),
        fn _event, measurements, metadata, _config ->
          if metadata.id == id, do: send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Feed.publish("page.unpublished", %{id: id, state: :draft}, org(), true)

      assert_received {:telemetry, %{count: 1}, %{kind: :withdrawn, type: "page"}}
    end

    test "never raises, and skips what it cannot place" do
      assert Feed.publish("page.published", %{id: "not-a-uuid"}, org()) == :ok
      assert Feed.publish("page.published", %{id: Ecto.UUID.generate()}, nil) == :ok
      assert Feed.publish("page.published", :not_a_map, org()) == :ok
    end
  end
end
