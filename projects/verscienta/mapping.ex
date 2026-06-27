defmodule Verscienta.Mapping do
  @moduledoc """
  Declarative map from the Verscienta **Directus** schema to **KilnCMS** content.

  Directus and Kiln model content very differently, so the importer can't copy
  columns 1:1. This module declares, per source collection, where each field
  goes:

    * **Core attributes** — `title`/`slug`/`state` (and `name` for clinics).
    * **Body blocks** (`:body_sections`) — Directus rich-text/HTML fields become
      an ordered run of `heading` + `rich_text` blocks in Kiln's typed block
      tree. The HTML lands in `RichText.legacy_html` (sanitised on cast).
    * **Tags** (`:taxonomy_links`) — Directus M2M taxonomy relations
      (`herb_tags`, `tcm_categories`) become Kiln `Tag`s, namespaced so the two
      vocabularies never collide.
    * **Content links** (`:m2m_links` / `:o2m_links`) — cross-document relations
      become `ContentLink`s. O2M children that carry their own data (formula
      ingredients, modifications) put that data on the link `metadata`.
    * **Media** (`:featured_image` / `:image_o2m`) — Directus file references
      become `MediaItem`s; the first becomes the content's `featured_image`, the
      rest become `image` blocks.
    * **Custom fields** — *everything else* (scalars, selects, JSON arrays, and
      the rich O2M child collections) is captured automatically as
      `custom_fields` by `Verscienta.Transform`, JSON-encoding any
      non-scalar value losslessly. Nothing is silently dropped.

  Keeping the rules as data (not code) means the long tail of fields needs no
  bespoke handling and the mapping is reviewable in one place.
  """

  @typedoc "One source-collection mapping config."
  @type config :: %{
          collection: String.t(),
          type: atom(),
          title_field: String.t(),
          slug_field: String.t(),
          state_field: String.t() | nil,
          excerpt_field: String.t() | nil,
          body_sections: [{String.t(), String.t()}],
          featured_image: String.t() | nil,
          image_o2m: {String.t(), String.t()} | nil,
          taxonomy_links: [{String.t(), String.t()}],
          m2m_links: [{String.t(), atom(), String.t()}],
          o2m_links: [{String.t(), atom(), String.t(), [String.t()]}]
        }

  # Content collections, in import order (independents before dependents so that
  # cross-document links can resolve their targets in pass 2).
  @configs [
    %{
      collection: "conditions",
      type: :condition,
      title_field: "title",
      slug_field: "slug",
      state_field: nil,
      excerpt_field: nil,
      body_sections: [{"description", "Description"}],
      featured_image: nil,
      image_o2m: nil,
      taxonomy_links: [],
      m2m_links: [],
      o2m_links: []
    },
    %{
      collection: "modalities",
      type: :modality,
      title_field: "title",
      slug_field: "slug",
      state_field: nil,
      excerpt_field: nil,
      body_sections: [{"benefits", "Benefits"}, {"description", "Description"}],
      featured_image: nil,
      image_o2m: nil,
      taxonomy_links: [],
      m2m_links: [{"conditions", :treats, "conditions"}],
      o2m_links: []
    },
    %{
      collection: "herbs",
      type: :herb,
      title_field: "title",
      slug_field: "slug",
      state_field: "status",
      excerpt_field: nil,
      body_sections: [
        {"botanical_description", "Botanical Description"},
        {"conservation_notes", "Conservation Notes"},
        {"tcm_functions", "TCM Functions"},
        {"therapeutic_uses", "Therapeutic Uses"},
        {"pharmacological_effects", "Pharmacological Effects"},
        {"contraindications", "Contraindications"},
        {"side_effects", "Side Effects"},
        {"allergenic_potential", "Allergenic Potential"},
        {"traditional_american_uses", "Traditional American Uses"},
        {"traditional_chinese_uses", "Traditional Chinese Uses"},
        {"native_american_uses", "Native American Uses"},
        {"cultural_significance", "Cultural Significance"},
        {"ethnobotanical_notes", "Ethnobotanical Notes"},
        {"folklore", "Folklore"},
        {"toxicity_symptoms", "Toxicity Symptoms"},
        {"toxicity_treatment", "Toxicity Treatment"}
      ],
      featured_image: nil,
      image_o2m: {"images", "file"},
      taxonomy_links: [{"tags", "herb-tag"}, {"tcm_category_tags", "tcm"}],
      m2m_links: [
        {"conditions_treated", :treats, "conditions"},
        {"related_species", :related_species, "herbs"},
        {"substitute_herbs", :substitute, "herbs"},
        {"similar_tcm_herbs", :similar_tcm, "herbs"},
        {"similar_western_herbs", :similar_western, "herbs"}
      ],
      o2m_links: []
    },
    %{
      collection: "formulas",
      type: :formula,
      title_field: "title",
      slug_field: "slug",
      state_field: nil,
      excerpt_field: nil,
      body_sections: [
        {"description", "Description"},
        {"preparation_instructions", "Preparation"},
        {"dosage", "Dosage"}
      ],
      featured_image: "image",
      image_o2m: nil,
      taxonomy_links: [],
      m2m_links: [
        {"conditions", :treats, "conditions"},
        {"related_formulas", :related, "formulas"}
      ],
      o2m_links: [
        {"ingredients", :ingredient, "herbs",
         ["herb_id", "quantity", "unit", "percentage", "role", "function", "notes"]},
        {"modifications", :modification, "herbs",
         ["herb_id", "condition", "action", "amount", "note"]}
      ]
    },
    %{
      collection: "practitioners",
      type: :practitioner,
      title_field: "title",
      slug_field: "slug",
      state_field: nil,
      excerpt_field: nil,
      body_sections: [{"bio", "Biography"}],
      featured_image: "image",
      image_o2m: nil,
      taxonomy_links: [],
      m2m_links: [{"modalities", :offers, "modalities"}],
      o2m_links: []
    },
    %{
      collection: "clinics",
      type: :clinic,
      title_field: "name",
      slug_field: "slug",
      state_field: "status",
      excerpt_field: nil,
      body_sections: [{"description", "Description"}],
      featured_image: nil,
      image_o2m: {"images", "file"},
      taxonomy_links: [],
      m2m_links: [
        {"practitioners", :staff, "practitioners"},
        {"modalities", :offers, "modalities"}
      ],
      o2m_links: []
    }
  ]

  # Taxonomy source collections → Kiln Tag namespace (slug prefix).
  @taxonomies [
    {"herb_tags", "herb-tag"},
    {"tcm_categories", "tcm"}
  ]

  @doc "All content-collection mapping configs, in safe import order."
  @spec configs() :: [config()]
  def configs, do: @configs

  @doc "Taxonomy source collections paired with their Kiln tag namespace."
  @spec taxonomies() :: [{String.t(), String.t()}]
  def taxonomies, do: @taxonomies

  @doc "Look up a config by source collection name."
  @spec config_for(String.t()) :: config() | nil
  def config_for(collection), do: Enum.find(@configs, &(&1.collection == collection))

  @doc """
  Source fields consumed structurally for a config (so the transform knows which
  keys to *exclude* from the auto-captured `custom_fields`).
  """
  @spec consumed_fields(config()) :: MapSet.t(String.t())
  def consumed_fields(cfg) do
    base = ["id", "sort", cfg.title_field, cfg.slug_field, cfg.state_field, cfg.excerpt_field]
    sections = Enum.map(cfg.body_sections, &elem(&1, 0))
    taxonomies = Enum.map(cfg.taxonomy_links, &elem(&1, 0))
    m2m = Enum.map(cfg.m2m_links, &elem(&1, 0))
    o2m = Enum.map(cfg.o2m_links, &elem(&1, 0))
    images = if cfg.image_o2m, do: [elem(cfg.image_o2m, 0)], else: []
    featured = if cfg.featured_image, do: [cfg.featured_image], else: []

    (base ++ sections ++ taxonomies ++ m2m ++ o2m ++ images ++ featured)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end
end
