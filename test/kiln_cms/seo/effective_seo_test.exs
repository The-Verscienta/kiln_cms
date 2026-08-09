defmodule KilnCMS.Seo.EffectiveSeoTest do
  @moduledoc """
  #805's SEO patterns reaching the surfaces the delivered HTML page is not
  (#1102): feeds, `.ics`, the event index, `llms.txt`, auto-posted social text,
  the fired `:json_ld` artifact and the serializer.

  Each test here fails on `main` by rendering an **empty** description for a
  document whose own page carries a sentence — the divergence in the issue, one
  surface at a time. The sharpest is the fired artifact: that one was permanent
  rather than stale, because re-firing re-read the same column.

  Two negatives carry as much weight as the positives, and are here because a
  first cut got both wrong: a pattern fills a blank and must never outrank an
  author's own excerpt, and the paywall teaser's pinned column set stays pinned —
  a token that needs a column it omits goes quiet rather than widening the read.

  Every case here uses a **dynamic** type, because a compiled type's pattern is
  a `use KilnCMS.CMS.Content` option fixed at compile time and no compiled type
  in this repo sets one. That is also why the eighth surface — the ActivityPub
  `Note` summary — has no end-to-end case: federation reads
  `descriptor.resource`, which is `nil` for every dynamic type, so the two tiers
  do not overlap. It reads the same `effective/3` as everything else, and
  `KilnCMS.Federation.AnnounceTest` covers the chain it sits in.
  """
  use KilnCMSWeb.ConnCase, async: false

  alias KilnCMS.CMS
  alias KilnCMS.CMS.ContentSerializer
  alias KilnCMS.CMS.ContentTypes
  alias KilnCMS.Seo.Patterns

  @london "Europe/London"

  setup do
    KilnCMS.Cache.bust_published()
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "eff-seo-#{uniq()}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # A dynamic type, because a compiled type's pattern is a macro option fixed at
  # compile time — the admin-configurable tier is the one a test can vary.
  defp patterned_type(actor, attrs \\ %{}) do
    name = "guide#{uniq()}"

    CMS.create_type_definition!(
      Map.merge(
        %{
          name: name,
          label: "Guide",
          plural_label: name,
          path_segment: name,
          seo_description_pattern: "About [title] — from [site-name]"
        },
        attrs
      ),
      actor: actor
    )
  end

  defp publish!(type, actor, attrs) do
    entry = ContentTypes.create!(type.name, attrs, actor: actor)
    {:ok, published} = ContentTypes.transition(type.name, "publish", entry, actor: actor)
    published
  end

  defp patterned_entry(actor, type_attrs \\ %{}, entry_attrs \\ %{}) do
    type = patterned_type(actor, type_attrs)
    {type, publish!(type, actor, Map.merge(%{title: "Firing"}, entry_attrs))}
  end

  defp in_a_week do
    DateTime.utc_now()
    |> DateTime.add(7 * 86_400, :second)
    |> DateTime.shift_zone!(@london)
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
  end

  @expected "About Firing — from KilnCMS"

  describe "the calculations" do
    test "resolve the type's pattern for a record that has no description" do
      actor = admin()
      {type, entry} = patterned_entry(actor)

      loaded =
        ContentTypes.get_record!(type.name, entry.id,
          actor: actor,
          load: [:effective_seo_description]
        )

      assert loaded.effective_seo_description == @expected
      # The stored column still says what a human typed, which is nothing.
      assert loaded.seo_description == nil
    end

    test "hand the author's own value back untouched" do
      actor = admin()
      {type, entry} = patterned_entry(actor, %{}, %{seo_description: "Mine."})

      loaded =
        ContentTypes.get_record!(type.name, entry.id,
          actor: actor,
          load: [:effective_seo_description]
        )

      assert loaded.effective_seo_description == "Mine."
    end

    test "are nil for a type with no pattern, rather than inventing one" do
      actor = admin()
      {type, entry} = patterned_entry(actor, %{seo_description_pattern: nil})

      loaded =
        ContentTypes.get_record!(type.name, entry.id,
          actor: actor,
          load: [:effective_seo_description]
        )

      assert loaded.effective_seo_description == nil
    end

    # The point of `load/3`: a `[field:<name>]` token needs `custom_fields`,
    # which a delivery read's pinned `select:` does not carry. Naming the
    # calculation has to be enough.
    test "carry their own dependencies into a pinned select" do
      actor = admin()

      type = patterned_type(actor, %{seo_description_pattern: "Serves [field:serves]"})

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "serves", label: "Serves", field_type: "text"},
        actor: actor
      )

      entry = publish!(type, actor, %{title: "Firing", custom_fields: %{"serves" => "four"}})

      [loaded] =
        ContentTypes.list!(type.name,
          authorize?: false,
          query: [
            filter: [id: entry.id],
            select: [:id, :title, :seo_description],
            load: [:effective_seo_description]
          ]
        )

      assert loaded.effective_seo_description == "Serves four"
    end
  end

  describe "the feed" do
    test "carries the type's default description", %{conn: conn} do
      actor = admin()
      {_type, _entry} = patterned_entry(actor, %{has_published_feed: true})

      body = conn |> get("/feed.xml") |> response(200)

      assert body =~ @expected
    end
  end

  describe "llms.txt" do
    test "carries the type's default description", %{conn: conn} do
      actor = admin()
      patterned_entry(actor)

      assert conn |> get("/llms.txt") |> response(200) =~ @expected
    end
  end

  describe "the event surfaces" do
    setup do
      actor = admin()
      type = patterned_type(actor)

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "when", label: "When", field_type: "datetime_range"},
        actor: actor
      )

      entry =
        publish!(type, actor, %{
          title: "Firing",
          custom_fields: %{"when" => %{"start" => in_a_week(), "time_zone" => @london}}
        })

      %{actor: actor, type: type, entry: entry}
    end

    test "the .ics DESCRIPTION", %{conn: conn, type: type, entry: entry} do
      body =
        conn |> get("/#{type.path_segment}/#{entry.slug}/calendar.ics") |> response(200)

      # RFC 5545 folds long lines; unfold before matching.
      assert String.replace(body, ~r/\r\n[ \t]/, "") =~ "DESCRIPTION:#{@expected}"
    end

    # The pattern fills a blank, it does not outrank what an editor wrote. Every
    # other surface picks `excerpt` first and this one used to as well.
    test "the .ics DESCRIPTION still prefers the author's excerpt", %{conn: conn} do
      actor = admin()
      type = patterned_type(actor, %{has_excerpt: true})

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "when", label: "When", field_type: "datetime_range"},
        actor: actor
      )

      entry =
        publish!(type, actor, %{
          title: "Firing",
          excerpt: "A two-day raku firing.",
          custom_fields: %{"when" => %{"start" => in_a_week(), "time_zone" => @london}}
        })

      body = conn |> get("/#{type.path_segment}/#{entry.slug}/calendar.ics") |> response(200)

      assert String.replace(body, ~r/\r\n[ \t]/, "") =~ "DESCRIPTION:A two-day raku firing."
    end

    test "the index.json summary", %{conn: conn, type: type} do
      body = conn |> get("/#{type.path_segment}/index.json") |> json_response(200)

      assert [%{"summary" => @expected}] = body["events"]
    end
  end

  describe "the fired :json_ld artifact" do
    # The sharpest case in #1102: `KilnCMSWeb.StructuredData` says it mirrors
    # `Firing.SchemaOrg.base_node/3`, and the two emitted different
    # `description` for the same document — permanently, since re-firing re-read
    # the stored column.
    test "says what the page's inline JSON-LD says", %{conn: conn} do
      actor = admin()
      {type, entry} = patterned_entry(actor)

      {:ok, %{json_ld: fired}} =
        KilnCMS.Firing.References.load_published(entry.org_id, :entry, entry.id)
        |> then(fn {:ok, document} -> KilnCMS.Firing.Engine.fire(document, mode: :preview) end)

      html = conn |> get("/#{type.path_segment}/#{entry.slug}") |> html_response(200)

      assert %{"@graph" => [%{"description" => @expected} | _]} = fired
      assert html =~ @expected
    end
  end

  describe "an auto-posted status" do
    test "carries the type's default description" do
      actor = admin()
      {type, entry} = patterned_entry(actor)

      record =
        ContentTypes.get_record!(type.name, entry.id,
          actor: actor,
          load: [:effective_seo_description]
        )

      assert KilnCMS.Social.Composer.compose(record, "https://example.test/x", 300) =~ @expected
    end

    # The composer is handed whatever the automation rule read, so it must
    # resolve without the load too — one registry lookup for one record.
    test "resolves without the calculation loaded" do
      actor = admin()
      {type, entry} = patterned_entry(actor)

      record = ContentTypes.get_record!(type.name, entry.id, actor: actor)

      assert KilnCMS.Social.Composer.compose(record, "https://example.test/x", 300) =~ @expected
    end
  end

  describe "the serializer" do
    test "ships the effective values beside the stored ones" do
      actor = admin()
      {type, entry} = patterned_entry(actor)

      payload =
        type.name
        |> ContentTypes.get_record!(entry.id, actor: actor, load: Patterns.loads())
        |> ContentSerializer.to_map()

      assert payload.seo_description == nil
      assert payload.effective_seo_description == @expected
    end

    # It reads a loaded calculation; it never resolves one. `Changes.NotifyWebhooks`
    # builds this payload inside the publishing transaction, where a failed query
    # aborts the commit — so a record read without the load reports the stored
    # column rather than putting a registry lookup on the publish path.
    test "reports the stored value rather than querying for the effective one" do
      actor = admin()
      {type, entry} = patterned_entry(actor)

      payload =
        type.name
        |> ContentTypes.get_record!(entry.id, actor: actor)
        |> ContentSerializer.to_map()

      assert payload.effective_seo_description == nil
    end
  end

  describe "the paywall teaser" do
    @tag :capture_log
    test "carries the type's default in its meta tag", %{conn: conn} do
      actor = admin()
      gated = hd(KilnCMS.CMS.Audiences.gated())
      {type, entry} = patterned_entry(actor, %{}, %{audience: gated})

      html = conn |> get("/#{type.path_segment}/#{entry.slug}") |> html_response(200)

      assert html =~ "kiln-paywalled"
      assert html =~ ~s(<meta name="description" content="#{@expected}")
    end

    # The teaser read pins a paywall-safe column set with no `custom_fields`, and
    # loading the calculations here would widen it for every consumer of the
    # record — `KilnCMSWeb.StructuredData.teaser/3` among them, which would then
    # publish a gated event's schedule in the paywall page's JSON-LD. So the two
    # tokens that need those columns stay quiet, exactly as `docs/seo.md` says,
    # and the elision makes that a shorter tag rather than a broken one.
    @tag :capture_log
    test "leaves a custom-field token quiet rather than widening its select", %{conn: conn} do
      actor = admin()

      type = patterned_type(actor, %{seo_description_pattern: "Serves [field:serves]"})

      CMS.create_field_definition!(
        %{type_definition_id: type.id, name: "serves", label: "Serves", field_type: "text"},
        actor: actor
      )

      entry =
        publish!(type, actor, %{
          title: "Firing",
          audience: hd(KilnCMS.CMS.Audiences.gated()),
          custom_fields: %{"serves" => "four"}
        })

      html = conn |> get("/#{type.path_segment}/#{entry.slug}") |> html_response(200)

      assert html =~ "kiln-paywalled"
      refute html =~ "Serves four"
      refute html =~ ~s(<meta name="description" content="Serves ")
    end

    # The slug route and the `path_alias` route reach the same renderer through
    # two different reads. One document, one answer.
    @tag :capture_log
    test "says the same thing at a path_alias as at the slug", %{conn: conn} do
      actor = admin()
      gated = hd(KilnCMS.CMS.Audiences.gated())
      alias_path = "/deep/firing-#{uniq()}"

      {type, entry} =
        patterned_entry(actor, %{}, %{audience: gated, path_alias: alias_path})

      by_slug = conn |> get("/#{type.path_segment}/#{entry.slug}") |> html_response(200)
      by_alias = conn |> get(alias_path) |> html_response(200)

      assert by_slug =~ ~s(<meta name="description" content="#{@expected}")
      assert by_alias =~ ~s(<meta name="description" content="#{@expected}")
    end
  end

  describe "a historical artifact" do
    # `PointInTime.read/5` re-fires a document replayed from version rows, with
    # `custom_fields: :as_stored` and `fragments: as_of` so it asserts nothing
    # that was not live then. Resolving today's pattern against it would be the
    # same class of wrong answer on the one endpoint sold as "what did this say
    # on <date>".
    test "keeps the description the document actually carried" do
      actor = admin()
      type = patterned_type(actor, %{seo_description_pattern: nil})
      entry = publish!(type, actor, %{title: "Firing"})

      # The pattern arrives AFTER the document was published.
      CMS.update_type_definition!(type, %{seo_description_pattern: "Rewritten"}, actor: actor)

      {:ok, artifact, _at} =
        KilnCMS.Firing.PointInTime.read(
          entry.org_id,
          KilnCMS.CMS.Entry,
          entry.id,
          :json_ld,
          DateTime.utc_now()
        )

      assert %{"@graph" => [main | _]} = artifact
      refute Map.has_key?(main, "description")
    end
  end

  describe "effective/3" do
    # `AnnounceWorker` builds a bare `%{id, title, slug, locale}` for a `Delete`
    # whose document is already gone. Resolving a descriptor for that map raises.
    test "is nil for a map with no such field" do
      assert Patterns.effective(%{id: "x", title: nil, slug: nil, locale: nil}, :seo_description) ==
               nil
    end

    # An unselected column says "nobody asked", not "nobody wrote one". Reading
    # it as the latter would replace an author's own description with the type's
    # default on any surface whose read forgot the column.
    test "is nil for an unselected column rather than the pattern's expansion" do
      record = %{seo_description: %Ash.NotLoaded{}, title: "T", org_id: nil}

      assert Patterns.effective(record, :seo_description,
               type: %{seo_description_pattern: "[title]"}
             ) ==
               nil
    end

    # `clamp/2` cuts on a BYTE ceiling, and #1102 routes the result into four
    # JSON encoders. A cut landing mid-character is invalid UTF-8, which
    # `Jason.encode!/1` raises on — and a CJK string has no ASCII space, so the
    # word-boundary trim never rescues it.
    test "never returns invalid UTF-8, whatever the ceiling lands on" do
      long = String.duplicate("焼", 3000)
      record = %{seo_description: nil, title: long, org_id: nil}

      value =
        Patterns.effective(record, :seo_description,
          type: %{seo_description_pattern: "[title]"},
          org: nil
        )

      assert String.valid?(value)
      assert {:ok, _json} = Jason.encode(%{"description" => value})
    end

    # `%Ash.NotLoaded{}` is truthy, so an `||` chain hands it on as a value.
    test "the composer reaches the pattern even when excerpt was not selected" do
      record =
        struct!(KilnCMS.CMS.Post, title: "A title", slug: "a-post", excerpt: %Ash.NotLoaded{})

      assert KilnCMS.Social.Composer.compose(record, "https://example.test/x", 300) ==
               "A title\n\nhttps://example.test/x"
    end

    test "prefers a loaded calculation over resolving again" do
      record = %{
        seo_description: nil,
        effective_seo_description: "already resolved",
        title: "T",
        org_id: nil
      }

      assert Patterns.effective(record, :seo_description,
               type: %{seo_description_pattern: "[title]"}
             ) == "already resolved"
    end
  end

  describe "a type's pattern change" do
    # `effective_seo_*` resolve inside the read, so their values land in the
    # 60-minute published-payload cache — which a `TypeDefinition` write did not
    # reach, while `docs/seo.md` promised the change takes effect immediately.
    test "takes effect at once rather than at the payload TTL", %{conn: conn} do
      actor = admin()
      {type, entry} = patterned_entry(actor)

      url = "/#{type.path_segment}/#{entry.slug}"
      assert conn |> get(url) |> html_response(200) =~ @expected

      CMS.update_type_definition!(type, %{seo_description_pattern: "Rewritten"}, actor: actor)

      html = conn |> get(url) |> html_response(200)

      assert html =~ "Rewritten"
      refute html =~ @expected
    end
  end
end
