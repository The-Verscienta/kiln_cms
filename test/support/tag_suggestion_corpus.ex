defmodule KilnCMS.TagSuggestionCorpus do
  @moduledoc """
  The corpus and the measurement behind `:suggest_tags_threshold` (#1086).

  #851 shipped `KilnCMS.Search.Related.suggest_tags/2`'s cosine-distance ceiling
  with a **derived** default, and said so: `KilnCMS.StubEmbedder` produces
  hash-seeded vectors, so no test in the suite could tell a good suggestion from
  a bad one, and every test had to neutralise the ceiling to assert anything.
  That left the one number the feature turns on exercised by nothing.

  This module is the other half. `documents/0` and `vocabulary/0` are a corpus
  with human labels — which tags a person would actually tick for each document
  — and `distances/0` is what the shipped embedder measured against it, recorded
  so an assertion can run in CI without a model.

  ## The measurement

  Model `BAAI/bge-small-en-v1.5` (`config :kiln_cms, KilnCMS.Search, :model`),
  `:cls_token_pooling`, L2-normalised, empty document prefix — i.e. exactly what
  `KilnCMS.Search.Embedder.Bumblebee` runs. Each document's vector is the **mean
  of its per-block embeddings**, because that is what `Related.centroid/1`
  computes from stored `BlockEmbedding` rows; each tag's is
  `VectorCache.embed_document/1` of the tag name. Every document is scored
  against the **whole** vocabulary, which is the real regime: `suggest_tags/2`'s
  candidate set is the site's entire tag list.

  Observed, over 8 documents and 35 tags — 280 pairs, 27 of them wanted:

    * tags a human would tick: **0.2119 – 0.4292**
    * tags they would not:     **0.2828 – 0.5626**

  The two bands overlap, which is the finding. There is no ceiling that keeps
  every wanted tag and admits no unwanted one, so the number is a judgement
  about which error to make — and `docs/rag.md` records why the judgement went
  where it did.

  Note what this contradicts. #851's docstring reasoned from bge-small putting
  unrelated pairs at 0.6–0.8 *similarity* — 0.2–0.4 in distance — and #1086
  warned that band describes sentence-to-sentence similarity and might not
  transfer to a one-word tag label against a whole-document centroid. It does
  not: measured, an unrelated tag sits at 0.35+, and a wanted one can sit at
  0.42. Reasoning from the wrong band is what made the shipped 0.25 keep
  **3 of 27** wanted tags.

  ## Re-measuring for another model

  `test/kiln_cms/search/tag_suggestion_calibration_test.exs` carries the
  harness, tagged `:calibration` and excluded by default because it downloads a
  model and takes minutes:

      mix test --include calibration test/kiln_cms/search/tag_suggestion_calibration_test.exs

  It prints the bands and the per-ceiling table for whatever model is
  configured. `Related.suggest_tags(record, threshold: 2.0)` does the same
  against your own content.
  """

  @typedoc "A document: title, its block texts, and the tags a human would tick."
  @type document :: {String.t(), [String.t()], [String.t()]}

  @documents [
    {"Sourdough starter maintenance",
     [
       "Keeping a sourdough starter alive",
       "A starter is a colony of wild yeast and lactobacilli living in flour and water. Feed it once a day at room temperature, or once a week in the fridge.",
       "Discard half before each feed. Without the discard the acid builds up faster than the yeast can work and the rise slows to nothing.",
       "A starter that smells of acetone is hungry, not dead. Feed it twice a day for three days before giving up on it."
     ], ~w(baking bread fermentation)},
    {"Glazing a raku pot",
     [
       "Glazing for raku firing",
       "Raku glazes are formulated to craze. The thermal shock of pulling a pot from the kiln at 1000C into a reduction chamber is what produces the crackle.",
       "Copper carbonate in a clear base gives the metallic lustres people associate with raku. Reduction is what pulls the copper back to metal.",
       "Do not use raku ware for food. The crazed surface and the low-fire glaze are both porous."
     ], ~w(pottery ceramics glazing kilns)},
    {"Choosing a hosting provider for a small Phoenix app",
     [
       "Where to run a small Phoenix application",
       "For a single-node deployment a $10 VPS with a managed Postgres is usually enough. The BEAM is frugal and Phoenix serves a lot of requests per core.",
       "Prefer a provider that gives you a real IP and a firewall you control. Platform-as-a-service is convenient until you need a long-lived connection.",
       "Whatever you pick, put the database backups somewhere else."
     ], ~w(elixir phoenix devops hosting)},
    {"Winter pruning of apple trees",
     [
       "Pruning apples in winter",
       "Prune when the tree is dormant and the wood is bare. You can see the shape you are cutting, and the tree is not spending energy it will lose.",
       "Take out crossing branches first, then anything growing inward. Aim for an open centre a bird could fly through.",
       "Never take more than a quarter of the canopy in one winter or the tree responds with a thicket of watershoots."
     ], ~w(gardening orchards pruning)},
    {"Understanding cosine similarity",
     [
       "What cosine similarity measures",
       "Cosine similarity is the cosine of the angle between two vectors. It ignores magnitude entirely and asks only whether they point the same way.",
       "For embeddings this is usually what you want: a long document and a short one about the same subject should be close.",
       "Cosine distance is 1 minus the similarity, so it runs from 0 for identical directions to 2 for exactly opposed ones."
     ], ~w(mathematics embeddings vectors)},
    {"Wiring a three-way light switch",
     [
       "How a three-way switch is wired",
       "Two switches control one light. The travellers run between them and the common terminal carries the feed on one end and the load on the other.",
       "Kill the breaker and test with a non-contact tester before you touch anything. A switch loop can be live even when the light is off.",
       "If the light only works when one switch is in a particular position, the common and a traveller have been swapped."
     ], ~w(electrical wiring diy)},
    {"Cold brew coffee ratios",
     [
       "Getting the ratio right for cold brew",
       "Start at 1:8 coffee to water by weight for a concentrate you will dilute, or 1:15 for something you can drink straight from the fridge.",
       "Grind coarse. A fine grind over eighteen hours extracts the bitter compounds a hot brew leaves behind, and no dilution fixes that.",
       "Steep at room temperature for twelve hours or in the fridge for eighteen. Longer is not stronger past that point, only more astringent."
     ], ~w(coffee brewing recipes)},
    {"Reading a Postgres EXPLAIN plan",
     [
       "Making sense of EXPLAIN ANALYZE",
       "Read the plan from the innermost node outward. The cost numbers are estimates; the actual rows and actual time are what happened.",
       "A sequential scan is not automatically wrong. On a small table it beats an index, and the planner knows the table size better than you do.",
       "The number to look for is a large gap between estimated and actual rows — that is where the statistics are stale or the correlation is wrong."
     ], ~w(postgres databases performance sql)}
  ]

  @near_misses ~w(brewing pottery gardening baking sql performance wiring coffee)
  @unrelated ~w(taxidermy cryptocurrency ballet philately payroll rugby opera dentistry)

  @doc "The labelled corpus."
  @spec documents() :: [document()]
  def documents, do: @documents

  @doc """
  The site's whole tag list: every document's own tags, plus near-misses that
  are plausible-but-wrong for a particular document (`brewing` for cold brew's
  neighbour, `sql` for a maths article), plus unrelated ones.

  The near-misses matter more than the unrelated ones. "carburetors for herbal
  tea" is not the failure an editor sees; "fermentation for cold brew" is.
  """
  @spec vocabulary() :: [String.t()]
  def vocabulary do
    (Enum.flat_map(@documents, fn {_title, _blocks, tags} -> tags end) ++
       @near_misses ++ @unrelated)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The recorded measurement: `{document title, tag, :good | :bad, distance}` for
  every pair, from the run described in the moduledoc.

  Rounded to four decimals — the differences that decide a ceiling are in the
  second, and a full-precision float would make this file re-record on any
  platform whose BLAS sums in a different order.
  """
  @spec distances() :: [{String.t(), String.t(), :good | :bad, float()}]
  def distances do
    [
      {"Choosing a hosting provider for a small Phoenix app", "hosting", :good, 0.2669},
      {"Choosing a hosting provider for a small Phoenix app", "postgres", :bad, 0.3074},
      {"Choosing a hosting provider for a small Phoenix app", "devops", :good, 0.3165},
      {"Choosing a hosting provider for a small Phoenix app", "cryptocurrency", :bad, 0.3431},
      {"Choosing a hosting provider for a small Phoenix app", "phoenix", :good, 0.3466},
      {"Choosing a hosting provider for a small Phoenix app", "databases", :bad, 0.3654},
      {"Choosing a hosting provider for a small Phoenix app", "diy", :bad, 0.3677},
      {"Choosing a hosting provider for a small Phoenix app", "pruning", :bad, 0.4025},
      {"Choosing a hosting provider for a small Phoenix app", "payroll", :bad, 0.4082},
      {"Choosing a hosting provider for a small Phoenix app", "wiring", :bad, 0.4120},
      {"Choosing a hosting provider for a small Phoenix app", "elixir", :good, 0.4134},
      {"Choosing a hosting provider for a small Phoenix app", "sql", :bad, 0.4163},
      {"Choosing a hosting provider for a small Phoenix app", "orchards", :bad, 0.4279},
      {"Choosing a hosting provider for a small Phoenix app", "performance", :bad, 0.4345},
      {"Choosing a hosting provider for a small Phoenix app", "embeddings", :bad, 0.4412},
      {"Choosing a hosting provider for a small Phoenix app", "vectors", :bad, 0.4491},
      {"Choosing a hosting provider for a small Phoenix app", "glazing", :bad, 0.4495},
      {"Choosing a hosting provider for a small Phoenix app", "gardening", :bad, 0.4513},
      {"Choosing a hosting provider for a small Phoenix app", "taxidermy", :bad, 0.4528},
      {"Choosing a hosting provider for a small Phoenix app", "kilns", :bad, 0.4613},
      {"Choosing a hosting provider for a small Phoenix app", "fermentation", :bad, 0.4659},
      {"Choosing a hosting provider for a small Phoenix app", "recipes", :bad, 0.4749},
      {"Choosing a hosting provider for a small Phoenix app", "brewing", :bad, 0.4781},
      {"Choosing a hosting provider for a small Phoenix app", "electrical", :bad, 0.4799},
      {"Choosing a hosting provider for a small Phoenix app", "opera", :bad, 0.4900},
      {"Choosing a hosting provider for a small Phoenix app", "baking", :bad, 0.4915},
      {"Choosing a hosting provider for a small Phoenix app", "philately", :bad, 0.4958},
      {"Choosing a hosting provider for a small Phoenix app", "bread", :bad, 0.4999},
      {"Choosing a hosting provider for a small Phoenix app", "rugby", :bad, 0.5089},
      {"Choosing a hosting provider for a small Phoenix app", "pottery", :bad, 0.5173},
      {"Choosing a hosting provider for a small Phoenix app", "coffee", :bad, 0.5211},
      {"Choosing a hosting provider for a small Phoenix app", "dentistry", :bad, 0.5255},
      {"Choosing a hosting provider for a small Phoenix app", "ceramics", :bad, 0.5296},
      {"Choosing a hosting provider for a small Phoenix app", "mathematics", :bad, 0.5460},
      {"Choosing a hosting provider for a small Phoenix app", "ballet", :bad, 0.5538},
      {"Cold brew coffee ratios", "brewing", :good, 0.2369},
      {"Cold brew coffee ratios", "coffee", :good, 0.2532},
      {"Cold brew coffee ratios", "fermentation", :bad, 0.2828},
      {"Cold brew coffee ratios", "recipes", :good, 0.3137},
      {"Cold brew coffee ratios", "baking", :bad, 0.3296},
      {"Cold brew coffee ratios", "bread", :bad, 0.3466},
      {"Cold brew coffee ratios", "kilns", :bad, 0.3469},
      {"Cold brew coffee ratios", "pruning", :bad, 0.3602},
      {"Cold brew coffee ratios", "glazing", :bad, 0.3722},
      {"Cold brew coffee ratios", "elixir", :bad, 0.3728},
      {"Cold brew coffee ratios", "diy", :bad, 0.3905},
      {"Cold brew coffee ratios", "ceramics", :bad, 0.3907},
      {"Cold brew coffee ratios", "gardening", :bad, 0.3925},
      {"Cold brew coffee ratios", "pottery", :bad, 0.3996},
      {"Cold brew coffee ratios", "orchards", :bad, 0.4237},
      {"Cold brew coffee ratios", "wiring", :bad, 0.4272},
      {"Cold brew coffee ratios", "dentistry", :bad, 0.4304},
      {"Cold brew coffee ratios", "performance", :bad, 0.4335},
      {"Cold brew coffee ratios", "postgres", :bad, 0.4458},
      {"Cold brew coffee ratios", "electrical", :bad, 0.4472},
      {"Cold brew coffee ratios", "hosting", :bad, 0.4476},
      {"Cold brew coffee ratios", "taxidermy", :bad, 0.4515},
      {"Cold brew coffee ratios", "mathematics", :bad, 0.4573},
      {"Cold brew coffee ratios", "devops", :bad, 0.4725},
      {"Cold brew coffee ratios", "payroll", :bad, 0.4793},
      {"Cold brew coffee ratios", "sql", :bad, 0.4796},
      {"Cold brew coffee ratios", "rugby", :bad, 0.4900},
      {"Cold brew coffee ratios", "embeddings", :bad, 0.4914},
      {"Cold brew coffee ratios", "vectors", :bad, 0.4951},
      {"Cold brew coffee ratios", "philately", :bad, 0.5020},
      {"Cold brew coffee ratios", "phoenix", :bad, 0.5038},
      {"Cold brew coffee ratios", "opera", :bad, 0.5149},
      {"Cold brew coffee ratios", "cryptocurrency", :bad, 0.5158},
      {"Cold brew coffee ratios", "databases", :bad, 0.5160},
      {"Cold brew coffee ratios", "ballet", :bad, 0.5228},
      {"Glazing a raku pot", "glazing", :good, 0.2903},
      {"Glazing a raku pot", "kilns", :good, 0.2958},
      {"Glazing a raku pot", "pottery", :good, 0.3435},
      {"Glazing a raku pot", "pruning", :bad, 0.3556},
      {"Glazing a raku pot", "ceramics", :good, 0.3566},
      {"Glazing a raku pot", "fermentation", :bad, 0.3702},
      {"Glazing a raku pot", "diy", :bad, 0.3720},
      {"Glazing a raku pot", "taxidermy", :bad, 0.3917},
      {"Glazing a raku pot", "baking", :bad, 0.3950},
      {"Glazing a raku pot", "gardening", :bad, 0.4201},
      {"Glazing a raku pot", "wiring", :bad, 0.4217},
      {"Glazing a raku pot", "recipes", :bad, 0.4226},
      {"Glazing a raku pot", "brewing", :bad, 0.4238},
      {"Glazing a raku pot", "coffee", :bad, 0.4496},
      {"Glazing a raku pot", "electrical", :bad, 0.4501},
      {"Glazing a raku pot", "performance", :bad, 0.4582},
      {"Glazing a raku pot", "bread", :bad, 0.4613},
      {"Glazing a raku pot", "elixir", :bad, 0.4646},
      {"Glazing a raku pot", "postgres", :bad, 0.4678},
      {"Glazing a raku pot", "rugby", :bad, 0.4682},
      {"Glazing a raku pot", "cryptocurrency", :bad, 0.4750},
      {"Glazing a raku pot", "embeddings", :bad, 0.4875},
      {"Glazing a raku pot", "dentistry", :bad, 0.4877},
      {"Glazing a raku pot", "phoenix", :bad, 0.4879},
      {"Glazing a raku pot", "philately", :bad, 0.4906},
      {"Glazing a raku pot", "orchards", :bad, 0.4922},
      {"Glazing a raku pot", "mathematics", :bad, 0.4927},
      {"Glazing a raku pot", "ballet", :bad, 0.4939},
      {"Glazing a raku pot", "devops", :bad, 0.4980},
      {"Glazing a raku pot", "hosting", :bad, 0.5068},
      {"Glazing a raku pot", "vectors", :bad, 0.5081},
      {"Glazing a raku pot", "payroll", :bad, 0.5197},
      {"Glazing a raku pot", "sql", :bad, 0.5247},
      {"Glazing a raku pot", "opera", :bad, 0.5290},
      {"Glazing a raku pot", "databases", :bad, 0.5334},
      {"Reading a Postgres EXPLAIN plan", "postgres", :good, 0.3051},
      {"Reading a Postgres EXPLAIN plan", "sql", :good, 0.3269},
      {"Reading a Postgres EXPLAIN plan", "embeddings", :bad, 0.3461},
      {"Reading a Postgres EXPLAIN plan", "databases", :good, 0.3579},
      {"Reading a Postgres EXPLAIN plan", "mathematics", :bad, 0.3685},
      {"Reading a Postgres EXPLAIN plan", "vectors", :bad, 0.3699},
      {"Reading a Postgres EXPLAIN plan", "payroll", :bad, 0.3961},
      {"Reading a Postgres EXPLAIN plan", "performance", :good, 0.3991},
      {"Reading a Postgres EXPLAIN plan", "pruning", :bad, 0.3992},
      {"Reading a Postgres EXPLAIN plan", "devops", :bad, 0.4110},
      {"Reading a Postgres EXPLAIN plan", "elixir", :bad, 0.4155},
      {"Reading a Postgres EXPLAIN plan", "cryptocurrency", :bad, 0.4253},
      {"Reading a Postgres EXPLAIN plan", "hosting", :bad, 0.4320},
      {"Reading a Postgres EXPLAIN plan", "wiring", :bad, 0.4439},
      {"Reading a Postgres EXPLAIN plan", "diy", :bad, 0.4459},
      {"Reading a Postgres EXPLAIN plan", "gardening", :bad, 0.4522},
      {"Reading a Postgres EXPLAIN plan", "fermentation", :bad, 0.4549},
      {"Reading a Postgres EXPLAIN plan", "taxidermy", :bad, 0.4565},
      {"Reading a Postgres EXPLAIN plan", "electrical", :bad, 0.4583},
      {"Reading a Postgres EXPLAIN plan", "glazing", :bad, 0.4623},
      {"Reading a Postgres EXPLAIN plan", "kilns", :bad, 0.4637},
      {"Reading a Postgres EXPLAIN plan", "opera", :bad, 0.4695},
      {"Reading a Postgres EXPLAIN plan", "bread", :bad, 0.4735},
      {"Reading a Postgres EXPLAIN plan", "baking", :bad, 0.4745},
      {"Reading a Postgres EXPLAIN plan", "philately", :bad, 0.4765},
      {"Reading a Postgres EXPLAIN plan", "recipes", :bad, 0.4799},
      {"Reading a Postgres EXPLAIN plan", "dentistry", :bad, 0.4804},
      {"Reading a Postgres EXPLAIN plan", "pottery", :bad, 0.4814},
      {"Reading a Postgres EXPLAIN plan", "brewing", :bad, 0.4815},
      {"Reading a Postgres EXPLAIN plan", "orchards", :bad, 0.4861},
      {"Reading a Postgres EXPLAIN plan", "ceramics", :bad, 0.4872},
      {"Reading a Postgres EXPLAIN plan", "phoenix", :bad, 0.4952},
      {"Reading a Postgres EXPLAIN plan", "ballet", :bad, 0.5143},
      {"Reading a Postgres EXPLAIN plan", "coffee", :bad, 0.5148},
      {"Reading a Postgres EXPLAIN plan", "rugby", :bad, 0.5149},
      {"Sourdough starter maintenance", "fermentation", :good, 0.2615},
      {"Sourdough starter maintenance", "baking", :good, 0.3023},
      {"Sourdough starter maintenance", "bread", :good, 0.3170},
      {"Sourdough starter maintenance", "brewing", :bad, 0.3182},
      {"Sourdough starter maintenance", "recipes", :bad, 0.3481},
      {"Sourdough starter maintenance", "kilns", :bad, 0.3548},
      {"Sourdough starter maintenance", "pruning", :bad, 0.3552},
      {"Sourdough starter maintenance", "gardening", :bad, 0.3565},
      {"Sourdough starter maintenance", "coffee", :bad, 0.3705},
      {"Sourdough starter maintenance", "elixir", :bad, 0.3998},
      {"Sourdough starter maintenance", "pottery", :bad, 0.4024},
      {"Sourdough starter maintenance", "ceramics", :bad, 0.4047},
      {"Sourdough starter maintenance", "orchards", :bad, 0.4097},
      {"Sourdough starter maintenance", "glazing", :bad, 0.4130},
      {"Sourdough starter maintenance", "diy", :bad, 0.4156},
      {"Sourdough starter maintenance", "taxidermy", :bad, 0.4389},
      {"Sourdough starter maintenance", "hosting", :bad, 0.4409},
      {"Sourdough starter maintenance", "wiring", :bad, 0.4424},
      {"Sourdough starter maintenance", "payroll", :bad, 0.4453},
      {"Sourdough starter maintenance", "devops", :bad, 0.4454},
      {"Sourdough starter maintenance", "electrical", :bad, 0.4536},
      {"Sourdough starter maintenance", "performance", :bad, 0.4546},
      {"Sourdough starter maintenance", "postgres", :bad, 0.4573},
      {"Sourdough starter maintenance", "cryptocurrency", :bad, 0.4841},
      {"Sourdough starter maintenance", "rugby", :bad, 0.4860},
      {"Sourdough starter maintenance", "dentistry", :bad, 0.4961},
      {"Sourdough starter maintenance", "sql", :bad, 0.4967},
      {"Sourdough starter maintenance", "philately", :bad, 0.4992},
      {"Sourdough starter maintenance", "vectors", :bad, 0.5056},
      {"Sourdough starter maintenance", "mathematics", :bad, 0.5064},
      {"Sourdough starter maintenance", "databases", :bad, 0.5153},
      {"Sourdough starter maintenance", "embeddings", :bad, 0.5230},
      {"Sourdough starter maintenance", "phoenix", :bad, 0.5245},
      {"Sourdough starter maintenance", "opera", :bad, 0.5329},
      {"Sourdough starter maintenance", "ballet", :bad, 0.5564},
      {"Understanding cosine similarity", "embeddings", :good, 0.2724},
      {"Understanding cosine similarity", "vectors", :good, 0.3067},
      {"Understanding cosine similarity", "mathematics", :good, 0.3563},
      {"Understanding cosine similarity", "sql", :bad, 0.3770},
      {"Understanding cosine similarity", "postgres", :bad, 0.3927},
      {"Understanding cosine similarity", "databases", :bad, 0.4137},
      {"Understanding cosine similarity", "pruning", :bad, 0.4323},
      {"Understanding cosine similarity", "elixir", :bad, 0.4483},
      {"Understanding cosine similarity", "performance", :bad, 0.4548},
      {"Understanding cosine similarity", "glazing", :bad, 0.4571},
      {"Understanding cosine similarity", "bread", :bad, 0.4603},
      {"Understanding cosine similarity", "cryptocurrency", :bad, 0.4656},
      {"Understanding cosine similarity", "dentistry", :bad, 0.4660},
      {"Understanding cosine similarity", "kilns", :bad, 0.4676},
      {"Understanding cosine similarity", "baking", :bad, 0.4693},
      {"Understanding cosine similarity", "payroll", :bad, 0.4708},
      {"Understanding cosine similarity", "ceramics", :bad, 0.4740},
      {"Understanding cosine similarity", "ballet", :bad, 0.4765},
      {"Understanding cosine similarity", "wiring", :bad, 0.4792},
      {"Understanding cosine similarity", "rugby", :bad, 0.4804},
      {"Understanding cosine similarity", "taxidermy", :bad, 0.4806},
      {"Understanding cosine similarity", "devops", :bad, 0.4812},
      {"Understanding cosine similarity", "opera", :bad, 0.4812},
      {"Understanding cosine similarity", "fermentation", :bad, 0.4847},
      {"Understanding cosine similarity", "hosting", :bad, 0.4859},
      {"Understanding cosine similarity", "philately", :bad, 0.4859},
      {"Understanding cosine similarity", "electrical", :bad, 0.4886},
      {"Understanding cosine similarity", "diy", :bad, 0.4929},
      {"Understanding cosine similarity", "pottery", :bad, 0.4960},
      {"Understanding cosine similarity", "recipes", :bad, 0.4992},
      {"Understanding cosine similarity", "gardening", :bad, 0.5001},
      {"Understanding cosine similarity", "brewing", :bad, 0.5030},
      {"Understanding cosine similarity", "orchards", :bad, 0.5119},
      {"Understanding cosine similarity", "coffee", :bad, 0.5144},
      {"Understanding cosine similarity", "phoenix", :bad, 0.5306},
      {"Winter pruning of apple trees", "pruning", :good, 0.2119},
      {"Winter pruning of apple trees", "gardening", :good, 0.2600},
      {"Winter pruning of apple trees", "orchards", :good, 0.2725},
      {"Winter pruning of apple trees", "glazing", :bad, 0.3342},
      {"Winter pruning of apple trees", "kilns", :bad, 0.3590},
      {"Winter pruning of apple trees", "fermentation", :bad, 0.3705},
      {"Winter pruning of apple trees", "brewing", :bad, 0.3800},
      {"Winter pruning of apple trees", "diy", :bad, 0.3825},
      {"Winter pruning of apple trees", "wiring", :bad, 0.3988},
      {"Winter pruning of apple trees", "taxidermy", :bad, 0.4063},
      {"Winter pruning of apple trees", "baking", :bad, 0.4098},
      {"Winter pruning of apple trees", "ceramics", :bad, 0.4193},
      {"Winter pruning of apple trees", "recipes", :bad, 0.4233},
      {"Winter pruning of apple trees", "pottery", :bad, 0.4308},
      {"Winter pruning of apple trees", "performance", :bad, 0.4365},
      {"Winter pruning of apple trees", "electrical", :bad, 0.4417},
      {"Winter pruning of apple trees", "elixir", :bad, 0.4418},
      {"Winter pruning of apple trees", "bread", :bad, 0.4423},
      {"Winter pruning of apple trees", "devops", :bad, 0.4455},
      {"Winter pruning of apple trees", "dentistry", :bad, 0.4619},
      {"Winter pruning of apple trees", "embeddings", :bad, 0.4711},
      {"Winter pruning of apple trees", "phoenix", :bad, 0.4713},
      {"Winter pruning of apple trees", "coffee", :bad, 0.4725},
      {"Winter pruning of apple trees", "ballet", :bad, 0.4744},
      {"Winter pruning of apple trees", "hosting", :bad, 0.4804},
      {"Winter pruning of apple trees", "rugby", :bad, 0.4853},
      {"Winter pruning of apple trees", "vectors", :bad, 0.4923},
      {"Winter pruning of apple trees", "payroll", :bad, 0.4964},
      {"Winter pruning of apple trees", "postgres", :bad, 0.4991},
      {"Winter pruning of apple trees", "philately", :bad, 0.5015},
      {"Winter pruning of apple trees", "mathematics", :bad, 0.5138},
      {"Winter pruning of apple trees", "databases", :bad, 0.5323},
      {"Winter pruning of apple trees", "cryptocurrency", :bad, 0.5345},
      {"Winter pruning of apple trees", "sql", :bad, 0.5405},
      {"Winter pruning of apple trees", "opera", :bad, 0.5606},
      {"Wiring a three-way light switch", "wiring", :good, 0.2407},
      {"Wiring a three-way light switch", "electrical", :good, 0.2635},
      {"Wiring a three-way light switch", "kilns", :bad, 0.4189},
      {"Wiring a three-way light switch", "diy", :good, 0.4292},
      {"Wiring a three-way light switch", "pruning", :bad, 0.4351},
      {"Wiring a three-way light switch", "rugby", :bad, 0.4584},
      {"Wiring a three-way light switch", "ceramics", :bad, 0.4635},
      {"Wiring a three-way light switch", "elixir", :bad, 0.4739},
      {"Wiring a three-way light switch", "brewing", :bad, 0.4755},
      {"Wiring a three-way light switch", "cryptocurrency", :bad, 0.4794},
      {"Wiring a three-way light switch", "gardening", :bad, 0.4864},
      {"Wiring a three-way light switch", "performance", :bad, 0.4864},
      {"Wiring a three-way light switch", "coffee", :bad, 0.4891},
      {"Wiring a three-way light switch", "phoenix", :bad, 0.4892},
      {"Wiring a three-way light switch", "mathematics", :bad, 0.4897},
      {"Wiring a three-way light switch", "baking", :bad, 0.4899},
      {"Wiring a three-way light switch", "glazing", :bad, 0.4909},
      {"Wiring a three-way light switch", "bread", :bad, 0.4987},
      {"Wiring a three-way light switch", "taxidermy", :bad, 0.5001},
      {"Wiring a three-way light switch", "fermentation", :bad, 0.5043},
      {"Wiring a three-way light switch", "devops", :bad, 0.5047},
      {"Wiring a three-way light switch", "pottery", :bad, 0.5091},
      {"Wiring a three-way light switch", "vectors", :bad, 0.5097},
      {"Wiring a three-way light switch", "postgres", :bad, 0.5171},
      {"Wiring a three-way light switch", "embeddings", :bad, 0.5237},
      {"Wiring a three-way light switch", "hosting", :bad, 0.5259},
      {"Wiring a three-way light switch", "payroll", :bad, 0.5311},
      {"Wiring a three-way light switch", "philately", :bad, 0.5316},
      {"Wiring a three-way light switch", "sql", :bad, 0.5379},
      {"Wiring a three-way light switch", "ballet", :bad, 0.5403},
      {"Wiring a three-way light switch", "recipes", :bad, 0.5457},
      {"Wiring a three-way light switch", "dentistry", :bad, 0.5508},
      {"Wiring a three-way light switch", "orchards", :bad, 0.5516},
      {"Wiring a three-way light switch", "opera", :bad, 0.5611},
      {"Wiring a three-way light switch", "databases", :bad, 0.5626}
    ]
  end
end
