defmodule KilnCMS.Experiments do
  @moduledoc """
  Content experiments — A/B testing published content variants (#499, phase 1).

  An experiment targets one published document and holds two or more **variants**,
  each a sparse patch over it: a different headline, a different CTA block. A
  visitor is assigned a variant, sees it, and their conversion is counted against
  it. See `docs/content-experiments-plan.md` for the architecture and why it is
  shaped this way.

  ## No visitor is tracked

  Kiln has no visitor cookie by default and `docs/data-flows.md` says so. So
  assignment splits along the two delivery surfaces:

    * **built-in site** — stateless. A variant is picked per request, nothing is
      stored. A visitor may see a different variant on reload, so only a
      *same-page* goal (a form submission, which travels with the page that
      carried it) can be attributed there;
    * **headless** — the caller passes `?variant_key=`, and the same key always
      resolves to the same variant. The caller already has a session or an
      edge-assigned bucket; they own stickiness and Kiln stores nothing.

  `KilnCMS.Experiments.Sticky` (#984) is the one opt-out of that, off unless an
  operator turns it on: a bucket cookie that keeps a visitor's arm stable, and
  the exposure cookie the `:content_view` goal needs in order to count a
  conversion that happens on a later page. Both are documented in
  `docs/data-flows.md` because turning them on changes what that document says.

  ## What a variant may never touch

  Five invariants, each with a test named after it (see the plan doc):

    1. a variant is never fired, so it cannot reach a feed, Meilisearch or a
       `:json_ld` artifact;
    2. a variant never writes `search_text`, `embedding` or `record.blocks`, so it
       cannot reach tsvector, block embeddings or related content;
    3. a variant is applied to the rendered body **after** SEO assigns and
       `:json_ld` are built from the canonical record, so it cannot reach
       `<title>`, the meta description, the canonical URL or the schema.org
       graph. A variant changes what a human reads, never what a machine indexes;
    4. a page serving a variant is never shared-cached — with `public, max-age=60`
       a CDN would cache one variant and serve it to everyone, which is a 100/0
       split wearing an experiment's clothes;
    5. a variant lives on its own resource, never as an attribute on the content
       record, so it cannot cut a version, bump `updated_at`, take the optimistic
       lock, notify webhooks or trigger a re-fire.
  """
  use Ash.Domain, otp_app: :kiln_cms

  alias KilnCMS.Experiments.Experiment

  require Logger

  # Backstop only — `bust/1` is the freshness signal, since an editor who starts
  # an experiment expects it live on the next request.
  @cache_ttl :timer.minutes(5)

  resources do
    resource KilnCMS.Experiments.Experiment do
      define :list_experiments, action: :read
      define :get_experiment, action: :read, get_by: [:id]
      define :running_experiments, action: :running
      define :create_experiment, action: :create
      define :start_experiment, action: :start
      define :conclude_experiment, action: :conclude, args: [:winner_variant_id]
      define :archive_experiment, action: :archive
      define :destroy_experiment, action: :destroy
    end

    resource KilnCMS.Experiments.Variant do
      define :list_variants, action: :read
      define :create_variant, action: :create
      define :update_variant, action: :update
      define :destroy_variant, action: :destroy
    end

    resource KilnCMS.Experiments.VariantDay do
      define :list_variant_days, action: :read
      define :record_impression, action: :record_impression, args: [:variant_id]
      define :record_conversion, action: :record_conversion, args: [:variant_id]
    end
  end

  @doc """
  Whether this deployment serves experiments at all.

  Off by default. Serving an experiment costs every targeted page its shared
  cache (invariant 4), so an operator fronting Kiln with a CDN should be able to
  say "not here" once rather than discovering it from a cache-hit graph.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @doc """
  The running experiment targeting `document_id`, with its variants loaded, or
  `nil`.

  Cached per site: this is on the delivery hot path for **every** page, and a
  site with no experiments must not pay a query per request to find that out.
  The cache holds the whole running set for an org — small by construction,
  since an experiment costs its page the CDN — and is busted on any experiment
  or variant write.
  """
  @spec for_document(Ash.UUID.t(), String.t(), Ash.UUID.t()) :: Experiment.t() | nil
  def for_document(org_id, content_type, document_id) do
    if enabled?() do
      org_id
      |> running()
      |> Enum.find(
        &(&1.content_type == to_string(content_type) and &1.document_id == document_id)
      )
    end
  end

  @doc "Every running experiment for a site, variants loaded. Cached."
  @spec running(Ash.UUID.t()) :: [Experiment.t()]
  def running(org_id) do
    KilnCMS.Cache.fetch(KilnCMS.Cache.experiments_key(org_id), @cache_ttl, fn ->
      load_running(org_id)
    end)
  end

  @doc "Drop a site's cached running set. Called from every experiment write."
  @spec bust(Ash.UUID.t()) :: :ok
  defdelegate bust(org_id), to: KilnCMS.Cache, as: :bust_experiments

  defp load_running(org_id) do
    Experiment
    |> Ash.Query.for_read(:running)
    |> Ash.Query.load(:variants)
    |> Ash.read!(authorize?: false, tenant: org_id)
  rescue
    # Delivery must survive a database that cannot answer this. No experiments
    # is the safe answer: the canonical document is what gets served.
    #
    # Logged rather than swallowed silently, because "no experiments" and
    # "every experiment on the site stopped serving" look identical from
    # outside. A rolling deploy where the image is ahead of the migration hits
    # exactly this — an `UndefinedColumn` on a column added for one goal takes
    # every OTHER experiment down with it, and without this line nothing says so.
    error ->
      Logger.warning("Experiments.running/1 could not read: #{Exception.message(error)}")
      []
  end

  defp config, do: Application.get_env(:kiln_cms, __MODULE__, [])
end
