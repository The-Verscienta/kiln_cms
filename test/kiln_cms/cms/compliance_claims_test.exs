defmodule KilnCMS.CMS.ComplianceClaimsTest do
  @moduledoc """
  The hard half of claim checking (#377) — the opt-in gate that turns an
  `:error`-severity match into a refused publish rather than advice.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.CMS

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMS.Compliance, [])
    on_exit(fn -> Application.put_env(:kiln_cms, KilnCMS.Compliance, previous) end)
    :ok
  end

  # No cache bust needed anywhere in this file: the gate resolves its settings
  # through `Settings.for_org_uncached/1`, because it runs inside the write
  # transaction. That is a production property, not a test convenience — see
  # that function.
  defp gate!(opts \\ []) do
    Application.put_env(
      :kiln_cms,
      KilnCMS.Compliance,
      Keyword.merge([enabled: true, require_at_publish: true, rules: :default], opts)
    )
  end

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "claims-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  # Canonical Portable Text, which is what the body walk reads — a
  # `legacy_html` block would be a no-op wherever `body` exists.
  defp text_block(text),
    do: %{
      "_type" => "rich_text",
      "body" => [%{"_type" => "block", "style" => "normal", "children" => [%{"text" => text}]}]
    }

  defp page(attrs, actor) do
    n = System.unique_integer([:positive])
    CMS.create_page!(Map.merge(%{title: "Page #{n}", slug: "claim-#{n}"}, attrs), actor: actor)
  end

  describe "the publish gate" do
    test "is off unless configured, so existing content keeps publishing" do
      actor = admin()
      p = page(%{blocks: [text_block("This is FDA approved.")]}, actor)

      assert {:ok, _published} = CMS.publish_page(p, actor: actor)
    end

    test "stays off when claim checking is enabled but the gate is not" do
      gate!(require_at_publish: false)
      actor = admin()
      p = page(%{blocks: [text_block("This is FDA approved.")]}, actor)

      assert {:ok, _published} = CMS.publish_page(p, actor: actor)
    end

    test "refuses a publish carrying an error-severity claim, quoting the phrase" do
      gate!()
      actor = admin()
      p = page(%{blocks: [text_block("Our formula is FDA approved.")]}, actor)

      assert {:error, error} = CMS.publish_page(p, actor: actor)
      assert Exception.message(error) =~ "fda approved"
      assert Exception.message(error) =~ "unreviewed claim"
    end

    # Severity is the operator's statement of what a rule means. Only the
    # regulatory and safety rules ship as errors; loose marketing copy stays
    # advice and must not stop a publish.
    test "a warning-severity match does not block" do
      gate!()
      actor = admin()
      p = page(%{blocks: [text_block("Guaranteed results, every time.")]}, actor)

      assert {:ok, _published} = CMS.publish_page(p, actor: actor)
    end

    # A claim in the meta description ships to a search results page, where it
    # is read by more people than the article.
    test "gates the SEO description, not only the body" do
      gate!()
      actor = admin()

      p =
        page(
          %{
            blocks: [text_block("A calm article.")],
            seo_description: "Clinically proven relief."
          },
          actor
        )

      assert {:error, error} = CMS.publish_page(p, actor: actor)
      assert Exception.message(error) =~ "clinically proven"
    end

    test "names every offending phrase at once rather than one per retry" do
      gate!()
      actor = admin()
      p = page(%{blocks: [text_block("FDA approved and 100% safe.")]}, actor)

      assert {:error, error} = CMS.publish_page(p, actor: actor)
      message = Exception.message(error)

      assert message =~ "fda approved"
      assert message =~ "100% safe"
    end

    test "publishes clean content unchanged" do
      gate!()
      actor = admin()
      p = page(%{blocks: [text_block("Herbal tea is pleasant to drink.")]}, actor)

      assert {:ok, published} = CMS.publish_page(p, actor: actor)
      assert published.state == :published
    end

    test "a custom rule set replaces the shipped pack" do
      gate!(rules: [%{code: :house_style, severity: :error, phrases: ["synergize"]}])
      actor = admin()

      # Shipped phrase, no longer configured — passes.
      assert {:ok, _} =
               %{blocks: [text_block("FDA approved.")]}
               |> page(actor)
               |> then(&CMS.publish_page(&1, actor: actor))

      assert {:error, error} =
               %{blocks: [text_block("We synergize outcomes.")]}
               |> page(actor)
               |> then(&CMS.publish_page(&1, actor: actor))

      assert Exception.message(error) =~ "synergize"
    end
  end

  describe "the gate agrees with the panel" do
    # The gate used to concatenate the body and the three scalar fields before
    # scanning, so a phrase could match across a seam that does not exist in
    # the document — and the editor, which scans the pieces separately, showed
    # nothing. The author was refused for words they could not find.
    test "does not invent a phrase spanning the body/field boundary" do
      gate!()
      actor = admin()

      p =
        page(
          %{
            blocks: [text_block("Use the sauna at your own risk")],
            title: "Free consultation guide",
            slug: "seam-#{System.unique_integer([:positive])}"
          },
          actor
        )

      # "risk free" is an :error phrase, and it appears nowhere in this
      # document — only across the join.
      assert {:ok, _published} = CMS.publish_page(p, actor: actor)
    end

    # Under the shipped English pack the panel reports :n_a for a non-English
    # document. A gate that refused it anyway would quote an English phrase the
    # author was never shown.
    test "skips a non-English document under the shipped English pack" do
      gate!()
      actor = admin()

      p =
        page(
          %{blocks: [text_block("Notre formule est FDA approved.")], locale: "fr"},
          actor
        )

      assert {:ok, _published} = CMS.publish_page(p, actor: actor)
    end

    test "custom rules gate in every locale" do
      gate!(rules: [%{code: :maison, severity: :error, phrases: ["approuvé par la fda"]}])
      actor = admin()

      p =
        page(
          %{blocks: [text_block("Approuvé par la FDA.")], locale: "fr"},
          actor
        )

      assert {:error, error} = CMS.publish_page(p, actor: actor)
      assert Exception.message(error) =~ "approuvé par la fda"
    end

    # A record whose locale is blank must not silently skip the gate — a gate
    # that turns itself off on missing data reads as passing.
    test "a blank locale falls back to the instance default, not 'unknown'" do
      gate!()
      actor = admin()

      p = page(%{blocks: [text_block("This is FDA approved.")], locale: ""}, actor)

      assert {:error, _error} = CMS.publish_page(p, actor: actor)
    end
  end

  describe "the edit gate" do
    # Without `only_new`, switching the gate on would make every already-live
    # page carrying a flagged phrase un-editable — an author fixing a typo
    # refused until they rewrote a sentence they never touched.
    test "an already-published claim does not block an unrelated edit" do
      actor = admin()

      p = page(%{blocks: [text_block("Our formula is FDA approved.")]}, actor)
      {:ok, published} = CMS.publish_page(p, actor: actor)

      gate!()

      assert {:ok, _updated} =
               CMS.update_page(published, %{seo_description: "A tidier description."},
                 actor: actor
               )
    end

    test "but adding a NEW claim to a live page is refused" do
      actor = admin()

      p = page(%{blocks: [text_block("Our formula is FDA approved.")]}, actor)
      {:ok, published} = CMS.publish_page(p, actor: actor)

      gate!()

      assert {:error, error} =
               CMS.update_page(
                 published,
                 %{blocks: [text_block("Our formula is FDA approved and 100% safe.")]},
                 actor: actor
               )

      message = Exception.message(error)

      assert message =~ "100% safe"
      # The phrase that was already live is not re-reported — it is not what
      # this write introduced.
      refute message =~ "fda approved"
    end

    test "a draft is not gated — a draft in progress is not an assertion it is done" do
      gate!()
      actor = admin()

      p = page(%{blocks: [text_block("A calm article.")]}, actor)

      assert {:ok, _updated} =
               CMS.update_page(p, %{blocks: [text_block("FDA approved.")]}, actor: actor)
    end

    # The whole justification for dropping `changing(:blocks)` from this gate's
    # `where:` — the alt-text gate can key on blocks because blocks are all it
    # reads, and this one also reads the SEO fields.
    test "fires when only the SEO description changes on a live record" do
      actor = admin()

      p = page(%{blocks: [text_block("A calm article.")]}, actor)
      {:ok, published} = CMS.publish_page(p, actor: actor)

      gate!()

      assert {:error, error} =
               CMS.update_page(published, %{seo_description: "Clinically proven relief."},
                 actor: actor
               )

      assert Exception.message(error) =~ "clinically proven"
    end
  end

  describe "the version-restore gate" do
    # `:restore_version` force-changes blocks and the SEO fields from a
    # snapshot in a `before_action`, so the ordinary `validate` never sees
    # them, and the action fires artifacts of its own when the record is
    # published. Without a hand-run check, rolling a live page back to a
    # version that made a claim puts it straight back on the public site.
    test "restoring a published page to a version carrying a claim is refused" do
      actor = admin()

      # v1: the claim, legal while a draft.
      draft = page(%{blocks: [text_block("Our formula is FDA approved.")]}, actor)

      # v2: reworded, then published clean.
      fixed =
        CMS.update_page!(draft, %{blocks: [text_block("Our formula is well studied.")]},
          actor: actor
        )

      {:ok, published} = CMS.publish_page(fixed, actor: actor)

      gate!()

      [create_version | _] =
        CMS.list_page_versions!(actor: actor)
        |> Enum.filter(&(&1.version_source_id == published.id))
        |> Enum.sort_by(& &1.version_inserted_at, DateTime)

      assert {:error, error} =
               CMS.restore_page_version(published, %{version_id: create_version.id}, actor: actor)

      assert Exception.message(error) =~ "fda approved"
    end

    test "restoring a DRAFT is not gated — it makes no public claim" do
      actor = admin()

      draft = page(%{blocks: [text_block("Our formula is FDA approved.")]}, actor)

      fixed =
        CMS.update_page!(draft, %{blocks: [text_block("Our formula is well studied.")]},
          actor: actor
        )

      gate!()

      [create_version | _] =
        CMS.list_page_versions!(actor: actor)
        |> Enum.filter(&(&1.version_source_id == fixed.id))
        |> Enum.sort_by(& &1.version_inserted_at, DateTime)

      assert {:ok, _restored} =
               CMS.restore_page_version(fixed, %{version_id: create_version.id}, actor: actor)
    end
  end

  describe "the scheduled publish gate" do
    # Two independent `validate` lines in the resource, so dropping one is
    # silent. A claim that must not go live by hand must not go live by
    # scheduler either.
    test "refuses a scheduled publish carrying an error-severity claim" do
      gate!()
      actor = admin()
      p = page(%{blocks: [text_block("Our formula is FDA approved.")]}, actor)

      assert {:error, error} = Ash.update(p, %{}, action: :publish_scheduled, actor: actor)
      assert Exception.message(error) =~ "fda approved"
    end

    test "lets a clean scheduled publish through" do
      gate!()
      actor = admin()
      p = page(%{blocks: [text_block("Herbal tea is pleasant.")]}, actor)

      assert {:ok, published} = Ash.update(p, %{}, action: :publish_scheduled, actor: actor)
      assert published.state == :published
    end
  end
end
