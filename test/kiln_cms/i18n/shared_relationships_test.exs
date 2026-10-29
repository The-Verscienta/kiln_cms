defmodule KilnCMS.I18n.SharedRelationshipsTest do
  @moduledoc """
  Shared tags and curated related content across locale variants (#1859, the
  "Tags and related content" section of `docs/field-level-localization.md`):
  the declaration, the copy on publish (tag references as they are; related
  targets resolved to the translation's locale along the fallback chain, in
  order), the copy's version and lock, a sibling's working copy, the #1860
  write refusal, and staleness.

  The test config runs `en` (the default), `fr` and `es`, with no site chain:
  `fr → en`, `es → en`.

  `async: false`: the page type opts its relationships in through the
  operator config, which is VM-global, and the chain is read through the
  default org's cached key (see `KilnCMS.I18n.FieldLocalizationTest`).
  """
  use KilnCMS.DataCase, async: false

  require Ash.Query

  alias KilnCMS.CMS
  alias KilnCMS.CMS.Translations
  alias KilnCMS.CMS.WorkingCopy
  alias KilnCMS.I18n.FieldLocalization
  alias KilnCMS.I18n.SharedFields
  alias KilnCMS.I18n.SharedFieldsWorker

  setup do
    previous = Application.get_env(:kiln_cms, :i18n)

    Application.put_env(
      :kiln_cms,
      :i18n,
      Keyword.put(previous, :field_localization, page: [shared: [:tags, :related]])
    )

    on_exit(fn ->
      Application.put_env(:kiln_cms, :i18n, previous)
      KilnCMS.Cache.bust_locale_fallbacks(KilnCMS.Accounts.default_org_id())
    end)

    %{actor: admin()}
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "srel-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp slug, do: "srel-#{System.unique_integer([:positive])}"

  defp tag(actor, name),
    do: CMS.create_tag!(%{name: name, slug: slug()}, actor: actor)

  defp reload(page), do: CMS.get_page!(page.id, authorize?: false, tenant: page.org_id)

  defp run_worker(record) do
    SharedFieldsWorker.perform(%Oban.Job{
      args: %{"org_id" => record.org_id, "type" => "page", "id" => record.id}
    })
  end

  defp tag_ids(page), do: SharedFields.tag_ids(reload(page))
  defp related_ids(page), do: SharedFields.related_ids(reload(page))

  defp sorted(records), do: records |> Enum.map(&to_string(&1.id)) |> Enum.sort()

  # An English source and its published French translation (Translate copies
  # the tags; it never copies related content).
  defp document(actor, attrs \\ %{}) do
    en =
      CMS.create_page!(Map.merge(%{title: "Product", slug: slug(), locale: "en"}, attrs),
        actor: actor
      )

    en = CMS.publish_page!(en, %{}, actor: actor)
    fr = Translations.create_translation!(:page, en, "fr", actor: actor)
    fr = CMS.publish_page!(fr, %{}, actor: actor)
    {reload(en), reload(fr)}
  end

  # A related target: an English page, plus a variant in each of `locales`.
  defp target(actor, locales) do
    en = CMS.create_page!(%{title: "Target", slug: slug(), locale: "en"}, actor: actor)

    variants =
      Map.new(locales, fn locale ->
        {locale, Translations.create_translation!(:page, en, locale, actor: actor)}
      end)

    Map.put(variants, "en", en)
  end

  defp versions(page) do
    CMS.Page.Version
    |> Ash.Query.filter(version_source_id == ^page.id)
    |> Ash.read!(authorize?: false, tenant: page.org_id)
  end

  defp stale?(source, locale, actor) do
    source
    |> then(&Translations.coverage(:page, &1, actor: actor))
    |> Enum.find(&(&1.locale == locale))
    |> Map.fetch!(:stale?)
  end

  describe "declarations" do
    test "the option's shared list names :tags and :related, and neither falls back" do
      assert FieldLocalization.validate!([shared: [:tags, :related, :seo_image]], false) ==
               %{shared: [:tags, :related, :seo_image], fallback: []}

      assert_raise ArgumentError, ~r/cannot name \[:tags\]/, fn ->
        FieldLocalization.validate!([fallback: [:tags]], false)
      end

      assert_raise ArgumentError, ~r/cannot name \[:related_pages\]/, fn ->
        FieldLocalization.validate!([shared: [:related_pages]], false)
      end
    end

    test "attributes/1 answers attributes only; relationships/1 the shared relationships" do
      assert FieldLocalization.relationships(CMS.Page) == [:tags, :related]
      assert FieldLocalization.attributes(CMS.Page) == %{shared: [], fallback: []}

      # A type sharing a relationship opts in, so its publish queues the copy.
      assert FieldLocalization.any?(%CMS.Page{blocks: []}, [])
      assert FieldLocalization.relationships(CMS.Post) == []
    end
  end

  describe "shared tags" do
    test "the source's tag set is copied as references, leaving the tags alone", ctx do
      [a, b, c] = for name <- ~w(Alpha Beta Gamma), do: tag(ctx.actor, name)
      {en, fr} = document(ctx.actor, %{tag_ids: [a.id, b.id]})
      assert tag_ids(fr) == sorted([a, b])

      en = CMS.update_page!(en, %{tag_ids: [b.id, c.id]}, actor: ctx.actor)
      before = length(versions(fr))
      lock = reload(fr).lock_version

      assert :ok = run_worker(en)
      assert tag_ids(fr) == sorted([b, c])

      # Versioned and locked, like any other shared value.
      assert length(versions(fr)) == before + 1

      assert List.last(Enum.sort_by(versions(fr), & &1.version_inserted_at)).version_action_name ==
               :sync_shared_fields

      assert reload(fr).lock_version == lock + 1

      # The tags themselves are untouched.
      assert CMS.get_tag!(b.id, authorize?: false).name == "Beta"

      # Nothing left to copy: a second run writes nothing.
      assert :ok = run_worker(en)
      assert length(versions(fr)) == before + 1
    end

    test "a translation that publishes later takes the source's current tags", ctx do
      [a, b] = for name <- ~w(One Two), do: tag(ctx.actor, name)
      en = CMS.create_page!(%{title: "P", slug: slug(), locale: "en"}, actor: ctx.actor)
      en = CMS.publish_page!(en, %{}, actor: ctx.actor)
      fr = Translations.create_translation!(:page, en, "fr", actor: ctx.actor)

      CMS.update_page!(reload(en), %{tag_ids: [a.id, b.id]}, actor: ctx.actor)
      assert tag_ids(fr) == []

      fr = CMS.publish_page!(reload(fr), %{}, actor: ctx.actor)
      assert :ok = run_worker(fr)
      assert tag_ids(fr) == sorted([a, b])
    end

    test "a sibling's working copy that holds its own tags gets the shared set", ctx do
      [a, b, c] = for name <- ~w(Red Green Blue), do: tag(ctx.actor, name)
      {en, fr} = document(ctx.actor, %{tag_ids: [a.id]})

      # Held in the French draft from before the type shared its tags.
      sharing = Application.get_env(:kiln_cms, :i18n)
      Application.put_env(:kiln_cms, :i18n, Keyword.put(sharing, :field_localization, []))

      {:ok, _fr} =
        CMS.save_page_working_copy(
          reload(fr),
          %{working_title: "Produit", fields: %{"tag_ids" => [to_string(b.id)]}},
          actor: ctx.actor,
          tenant: fr.org_id
        )

      Application.put_env(:kiln_cms, :i18n, sharing)

      assert WorkingCopy.held_ids(reload(fr), :tag_ids) == [to_string(b.id)]

      en = CMS.update_page!(reload(en), %{tag_ids: [c.id]}, actor: ctx.actor)
      assert :ok = run_worker(en)

      fr = reload(fr)
      assert tag_ids(fr) == sorted([c])
      assert WorkingCopy.held_ids(fr, :tag_ids) == sorted([c])
      assert WorkingCopy.reconcile(fr).conflicts == []

      published = CMS.publish_page_changes!(fr, %{}, actor: ctx.actor, tenant: fr.org_id)
      assert published.title == "Produit"
      assert tag_ids(published) == sorted([c])
    end
  end

  describe "shared related content" do
    test "each target resolves to its variant in the translation's locale, in order", ctx do
      both = target(ctx.actor, ["fr"])
      en_only = target(ctx.actor, [])
      last = target(ctx.actor, ["fr", "es"])
      {en, fr} = document(ctx.actor)

      ids = [last["en"].id, en_only["en"].id, both["en"].id]
      en = CMS.update_page!(en, %{related_page_ids: ids}, actor: ctx.actor)
      assert related_ids(en) == Enum.map(ids, &to_string/1)

      assert :ok = run_worker(en)

      # French variants where they exist; the English one along `fr → en`
      # where the target has none; the source's order kept.
      assert related_ids(fr) ==
               Enum.map([last["fr"].id, en_only["en"].id, both["fr"].id], &to_string/1)

      # A reorder on the source reorders the translation.
      en = CMS.update_page!(reload(en), %{related_page_ids: Enum.reverse(ids)}, actor: ctx.actor)
      assert :ok = run_worker(en)

      assert related_ids(fr) ==
               Enum.map([both["fr"].id, en_only["en"].id, last["fr"].id], &to_string/1)

      # Removing one on the source removes its variant here.
      en = CMS.update_page!(reload(en), %{related_page_ids: [both["en"].id]}, actor: ctx.actor)
      assert :ok = run_worker(en)
      assert related_ids(fr) == [to_string(both["fr"].id)]
    end

    test "a target with no variant along the chain is left out", ctx do
      # Linked from the source in Spanish only: `fr → en` reaches neither.
      spanish = CMS.create_page!(%{title: "S", slug: slug(), locale: "es"}, actor: ctx.actor)
      kept = target(ctx.actor, ["fr"])
      {en, fr} = document(ctx.actor)

      en =
        CMS.update_page!(en, %{related_page_ids: [spanish.id, kept["en"].id]}, actor: ctx.actor)

      assert :ok = run_worker(en)
      assert related_ids(fr) == [to_string(kept["fr"].id)]
    end

    test "resolution follows a configured chain, and drops the variant itself", ctx do
      t = target(ctx.actor, ["es"])
      {en, fr} = document(ctx.actor)

      chains = %KilnCMS.I18n.Fallback.Chains{explicit: %{"fr" => ["es"]}}

      targets =
        SharedFields.related_targets(
          CMS.update_page!(en, %{related_page_ids: [t["en"].id]}, actor: ctx.actor)
        )

      assert SharedFields.resolve_related(CMS.Page, targets, "fr", chains, fr.org_id) ==
               [to_string(t["es"].id)]

      # The source linking its own translation: that link is not the
      # translation's related content.
      own = SharedFields.related_targets(reload(en)) ++ [fr]

      assert SharedFields.resolve_related(CMS.Page, own, "fr", chains, fr.org_id, except: fr.id) ==
               [to_string(t["es"].id)]
    end
  end

  describe "the write refusal (#1860)" do
    setup ctx do
      [a, b] = for name <- ~w(Kept Other), do: tag(ctx.actor, name)
      t = target(ctx.actor, ["fr"])
      other = target(ctx.actor, ["fr"])
      {en, fr} = document(ctx.actor, %{tag_ids: [a.id]})
      en = CMS.update_page!(en, %{related_page_ids: [t["en"].id]}, actor: ctx.actor)
      :ok = run_worker(en)
      %{a: a, b: b, t: t, other: other, en: reload(en), fr: reload(fr)}
    end

    test "a translation's tags cannot be changed, by complete set or merge verb", ctx do
      for params <- [
            %{tag_ids: [ctx.b.id]},
            %{add_tag_ids: [ctx.b.id]},
            %{remove_tag_ids: [ctx.a.id]}
          ] do
        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 CMS.update_page(ctx.fr, params, actor: ctx.actor)

        assert Enum.any?(
                 errors,
                 &(&1.field == :tag_ids and &1.message =~ "can only be changed on the en version")
               )
      end

      # Re-sending what is stored passes, and so does a merge verb that
      # changes nothing.
      assert {:ok, _} = CMS.update_page(ctx.fr, %{tag_ids: [ctx.a.id]}, actor: ctx.actor)

      assert {:ok, _} =
               CMS.update_page(reload(ctx.fr), %{add_tag_ids: [ctx.a.id]}, actor: ctx.actor)
    end

    test "a translation's related list cannot be changed, order included", ctx do
      t_fr = ctx.t["fr"].id
      other_fr = ctx.other["fr"].id

      assert {:error, %Ash.Error.Invalid{errors: [error]}} =
               CMS.update_page(ctx.fr, %{related_page_ids: [t_fr, other_fr]}, actor: ctx.actor)

      assert error.field == :related_page_ids
      assert error.message =~ "related content is shared"

      assert {:ok, _} = CMS.update_page(ctx.fr, %{related_page_ids: [t_fr]}, actor: ctx.actor)
    end

    test "the source's own writes and a type sharing nothing are not judged", ctx do
      assert {:ok, _} = CMS.update_page(ctx.en, %{tag_ids: [ctx.b.id]}, actor: ctx.actor)

      Application.put_env(
        :kiln_cms,
        :i18n,
        Keyword.put(Application.get_env(:kiln_cms, :i18n), :field_localization, [])
      )

      assert {:ok, _} = CMS.update_page(ctx.fr, %{add_tag_ids: [ctx.b.id]}, actor: ctx.actor)
    end
  end

  describe "the translation workflow around it" do
    test "a tag copy does not make an outdated translation look fresh", ctx do
      a = tag(ctx.actor, "Fresh")
      {en, fr} = document(ctx.actor)

      en = CMS.update_page!(reload(en), %{title: "Product v2", tag_ids: [a.id]}, actor: ctx.actor)
      assert stale?(en, "fr", ctx.actor)

      assert :ok = run_worker(en)
      assert tag_ids(fr) == sorted([a])
      assert stale?(en, "fr", ctx.actor), "the copy is not a translator's edit"
    end
  end
end
