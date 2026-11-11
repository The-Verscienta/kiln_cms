defmodule KilnCMS.Webhooks.TaxonomyEventsTest do
  @moduledoc """
  Taxonomy webhooks (#1965): creating, updating or deleting a tag, tag group
  or category dispatches `<type>.<verb>` once, after the write commits, to the
  endpoints of the record's org that opted in. The events are not retractions,
  carry no drafts, reach the CDN purge, and skip automation and federation.
  """
  # async: false — the consumer tests set the global `KilnCMS.CDN` and
  # `KilnCMS.Federation` app env.
  use KilnCMS.DataCase, async: false
  use Oban.Testing, repo: KilnCMS.Repo

  alias KilnCMS.CMS
  alias KilnCMS.CMS.WebhookEndpoint
  alias KilnCMS.Webhooks

  @verbs ~w(created updated deleted)

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "taxwh-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp org(name) do
    Ash.Seed.seed!(KilnCMS.Accounts.Organization, %{
      name: name,
      slug: "#{name}-#{System.unique_integer([:positive])}",
      status: :active
    })
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp subscribe(events, opts),
    do: CMS.create_webhook_endpoint!(%{url: "https://example.test/hook", events: events}, opts)

  defp deliveries(opts), do: CMS.list_webhook_deliveries!(Keyword.put(opts, :authorize?, false))

  defp events_of(opts), do: opts |> deliveries() |> Enum.map(& &1.event) |> Enum.sort()

  # The three resources, by namespace, as `{create, update, destroy}` code
  # interfaces and the attrs to create one with.
  defp kinds do
    [
      {"tag", &CMS.create_tag!/2, &CMS.update_tag!/3, &CMS.destroy_tag!/2},
      {"tag_group", &CMS.create_tag_group!/2, &CMS.update_tag_group!/3,
       &CMS.destroy_tag_group!/2},
      {"category", &CMS.create_category!/2, &CMS.update_category!/3, &CMS.destroy_category!/2}
    ]
  end

  setup do
    org = org("taxwh")
    %{org: org, opts: [actor: admin(), tenant: org]}
  end

  describe "each write dispatches its event exactly once" do
    for type <- ~w(tag tag_group category) do
      @type_name type
      test "#{type}: created, updated, deleted — one delivery each, with the payload",
           %{org: org, opts: opts} do
        {type, create, update, destroy} = List.keyfind(kinds(), @type_name, 0)
        subscribe(for(v <- @verbs, do: "#{type}.#{v}"), opts)

        slug = uniq("t")
        record = create.(%{name: "First", slug: slug}, opts)
        assert events_of(opts) == ["#{type}.created"]

        renamed = update.(record, %{name: "Second", slug: slug <> "-x"}, opts)
        destroy.(renamed, opts)

        by_event = opts |> deliveries() |> Enum.group_by(& &1.event)

        assert by_event |> Map.keys() |> Enum.sort() ==
                 Enum.sort(for v <- @verbs, do: "#{type}.#{v}")

        assert Enum.all?(by_event, fn {_event, rows} -> length(rows) == 1 end)
        assert Enum.all?(Map.values(by_event), fn [row] -> row.org_id == org.id end)

        [created] = by_event["#{type}.created"]
        [updated] = by_event["#{type}.updated"]
        [deleted] = by_event["#{type}.deleted"]

        group_key = if type == "tag", do: %{"tag_group_id" => nil}, else: %{}

        assert Map.delete(created.payload, "updated_at") ==
                 Map.merge(%{"id" => record.id, "slug" => slug, "name" => "First"}, group_key)

        assert Map.delete(updated.payload, "updated_at") ==
                 Map.merge(
                   %{
                     "id" => record.id,
                     "slug" => slug <> "-x",
                     "name" => "Second",
                     "previous_slug" => slug
                   },
                   group_key
                 )

        # The record as it was when it was removed.
        assert Map.delete(deleted.payload, "updated_at") ==
                 Map.merge(
                   %{"id" => record.id, "slug" => slug <> "-x", "name" => "Second"},
                   group_key
                 )

        assert is_binary(deleted.payload["updated_at"])

        # A deleted term withdraws no document: an ordinary delivery.
        refute deleted.retraction
        assert is_nil(deleted.document_id)

        assert length(all_enqueued(worker: KilnCMS.Webhooks.DeliveryWorker)) == 3
      end
    end
  end

  test "an update that leaves the slug alone carries no previous_slug", %{opts: opts} do
    subscribe(["category.updated"], opts)
    category = CMS.create_category!(%{name: "Herbs", slug: uniq("herbs")}, opts)
    CMS.update_category!(category, %{name: "Herbs & spices"}, opts)

    assert [%{payload: payload}] = deliveries(opts)
    assert payload["name"] == "Herbs & spices"
    refute Map.has_key?(payload, "previous_slug")
  end

  test "moving a tag between groups carries previous_tag_group_id", %{opts: opts} do
    from = CMS.create_tag_group!(%{name: "Payers", slug: uniq("payers")}, opts)
    to = CMS.create_tag_group!(%{name: "Old payers", slug: uniq("old")}, opts)
    tag = CMS.create_tag!(%{name: "Acme", slug: uniq("payer"), tag_group_id: from.id}, opts)

    subscribe(["tag.updated"], opts)
    CMS.update_tag!(tag, %{tag_group_id: to.id}, opts)

    assert [%{payload: payload}] = deliveries(opts)
    assert payload["tag_group_id"] == to.id
    assert payload["previous_tag_group_id"] == from.id
    refute Map.has_key?(payload, "previous_slug")
  end

  test "a tag delete identifies the tag and its group", %{opts: opts} do
    group = CMS.create_tag_group!(%{name: "Payers", slug: uniq("payers")}, opts)
    tag = CMS.create_tag!(%{name: "Acme", slug: uniq("payer"), tag_group_id: group.id}, opts)
    subscribe(["tag.deleted"], opts)

    CMS.destroy_tag!(tag, opts)

    assert [%{payload: payload}] = deliveries(opts)

    assert %{"id" => id, "slug" => slug, "name" => "Acme", "tag_group_id" => group_id} =
             payload

    assert {id, slug, group_id} == {tag.id, tag.slug, group.id}
  end

  test "a failed write dispatches nothing", %{opts: opts} do
    subscribe(WebhookEndpoint.taxonomy_events(), opts)

    assert {:error, _} = CMS.create_tag(%{name: "Bad", slug: "Not A Slug"}, opts)

    category = CMS.create_category!(%{name: "Ok", slug: uniq("ok")}, opts)
    assert {:error, _} = CMS.update_category(category, %{slug: "Not A Slug"}, opts)

    assert events_of(opts) == ["category.created"]
  end

  test "an endpoint on the default subscription receives no taxonomy event", %{opts: opts} do
    CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, opts)
    tag = CMS.create_tag!(%{name: "Quiet", slug: uniq("quiet")}, opts)
    tag = CMS.update_tag!(tag, %{name: "Still quiet"}, opts)
    CMS.destroy_tag!(tag, opts)

    assert deliveries(opts) == []
  end

  test "an endpoint gets only the taxonomy events it selected", %{opts: opts} do
    subscribe(["tag.created"], opts)
    tag = CMS.create_tag!(%{name: "One", slug: uniq("one")}, opts)
    CMS.destroy_tag!(tag, opts)
    CMS.create_category!(%{name: "Cat", slug: uniq("cat")}, opts)

    assert events_of(opts) == ["tag.created"]
  end

  test "another org's subscribed endpoint receives nothing", %{opts: opts} do
    other = org("taxwh-b")
    other_opts = Keyword.put(opts, :tenant, other)
    subscribe(WebhookEndpoint.taxonomy_events(), other_opts)
    subscribe(["tag.created"], opts)

    CMS.create_tag!(%{name: "Mine", slug: uniq("mine")}, opts)

    assert events_of(opts) == ["tag.created"]
    assert deliveries(other_opts) == []
  end

  describe "selectable events" do
    test "every taxonomy event is selectable and none is a default" do
      expected =
        for type <- ~w(category tag tag_group), verb <- @verbs, do: "#{type}.#{verb}"

      assert Enum.sort(WebhookEndpoint.taxonomy_events()) == Enum.sort(expected)

      selectable = WebhookEndpoint.events()
      assert Enum.all?(expected, &(&1 in selectable))
      assert Enum.filter(WebhookEndpoint.default_events(), &(&1 in expected)) == []
    end

    test "a taxonomy event is neither a draft nor a retraction" do
      for event <- WebhookEndpoint.taxonomy_events() do
        refute WebhookEndpoint.carries_drafts?(event), event
        refute Webhooks.retraction?(event), event
      end

      # The content verbs they share are unaffected.
      assert WebhookEndpoint.carries_drafts?("page.created")
      assert Webhooks.retraction?("page.deleted")
    end
  end

  describe "the funnel's other consumers" do
    setup do
      cdn = Application.get_env(:kiln_cms, KilnCMS.CDN, [])
      federation = Application.get_env(:kiln_cms, KilnCMS.Federation, [])

      on_exit(fn ->
        Application.put_env(:kiln_cms, KilnCMS.CDN, cdn)
        Application.put_env(:kiln_cms, KilnCMS.Federation, federation)
      end)

      Application.put_env(
        :kiln_cms,
        KilnCMS.CDN,
        Keyword.put(cdn, :purge_url, "https://purge.example.test/purge")
      )

      Application.put_env(:kiln_cms, KilnCMS.Federation, Keyword.put(federation, :enabled, true))
      :ok
    end

    test "a taxonomy write purges the CDN and skips automation and federation", %{
      org: org,
      opts: opts
    } do
      # An "any type, on updated" rule: what automation would match a tag against.
      KilnCMS.Automation.create_rule!(
        %{name: "Any type, on updated", trigger_event: :updated, action: :broadcast, config: %{}},
        opts
      )

      tag = CMS.create_tag!(%{name: "Purge me", slug: uniq("purge")}, opts)
      tag = CMS.update_tag!(tag, %{name: "Purged"}, opts)
      CMS.destroy_tag!(tag, opts)

      refute_enqueued(worker: KilnCMS.Automation.DispatchWorker)
      refute_enqueued(worker: KilnCMS.Federation.AnnounceWorker)
      assert_enqueued(worker: KilnCMS.CDN.PurgeWorker, args: %{org_id: org.id})
    end

    test "the guard leaves content events alone" do
      org_id = KilnCMS.Accounts.default_org_id()
      Webhooks.dispatch("page.updated", %{id: Ecto.UUID.generate()}, org_id)

      assert_enqueued(worker: KilnCMS.Automation.DispatchWorker)
      assert_enqueued(worker: KilnCMS.Federation.AnnounceWorker)
    end

    test "announce: :delivery reaches the endpoints and the change feed only (#2463)", %{
      org: org,
      opts: opts
    } do
      CMS.create_webhook_endpoint!(%{url: "https://example.test/hook"}, opts)
      :ok = KilnCMS.Delivery.Feed.subscribe(org.id)
      id = Ecto.UUID.generate()

      Webhooks.dispatch("page.updated", %{id: id, state: :published}, org.id, announce: :delivery)

      assert [%{event: "page.updated"}] =
               CMS.list_webhook_deliveries!(authorize?: false, tenant: org.id)

      KilnCMS.Delivery.Feed.sync(org.id)
      assert_received {:kiln_feed, %KilnCMS.Delivery.Feed.Event{kind: :updated, id: ^id}}

      refute_enqueued(worker: KilnCMS.Automation.DispatchWorker)
      refute_enqueued(worker: KilnCMS.Federation.AnnounceWorker)
      refute_enqueued(worker: KilnCMS.CDN.PurgeWorker)
    end

    test "purges? covers every taxonomy verb, and no more content verbs than before" do
      for event <- WebhookEndpoint.taxonomy_events(), do: assert(KilnCMS.CDN.purges?(event))

      refute KilnCMS.CDN.purges?("page.in_review")
      refute KilnCMS.CDN.purges?("page.created")
      refute KilnCMS.CDN.purges?("page.deleted")
    end
  end

  describe "content type names" do
    test "a dynamic type may not be named after a taxonomy namespace", %{opts: opts} do
      for name <- ~w(tag tag_group category) do
        assert {:error, error} =
                 CMS.create_type_definition(
                   %{name: name, label: "X", path_segment: uniq("seg")},
                   opts
                 )

        assert Exception.message(error) =~ "built-in webhook event namespace"
      end
    end

    test "a type already named after one (from before the rule) can still be edited",
         %{org: org, opts: opts} do
      legacy =
        Ash.Seed.seed!(KilnCMS.CMS.TypeDefinition, %{
          name: "tag",
          label: "Legacy",
          path_segment: uniq("legacy"),
          org_id: org.id
        })

      assert %{label: "Renamed"} =
               CMS.update_type_definition!(legacy, %{label: "Renamed"}, opts)
    end
  end
end
