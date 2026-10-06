defmodule KilnCMS.TermDuplicateCorpus do
  @moduledoc """
  Recorded tag-name distances behind
  `KilnCMS.Search.near_duplicate_term_threshold/0` (#1596): pairs of labels a
  person would merge (`:same`), related but distinct (`:related`) and unrelated
  (`:unrelated`), with the cosine distance the default
  `BAAI/bge-small-en-v1.5` gave each pair on 2026-10-06 (no document prefix,
  L2-normalized pooled embeddings — what `KilnCMS.Search.VectorCache.embed_document/1`
  stores for a tag name).

  Re-measure for another model by embedding both labels of each pair with the
  configured embedder and reading `1 - cos θ`.
  """

  @pairs [
    {"news", "News", :same, 0.0},
    {"tutorial", "tutorials", :same, 0.0373},
    {"kids", "children", :same, 0.039},
    {"color", "colour", :same, 0.0422},
    {"travel", "traveling", :same, 0.0609},
    {"recipe", "recipes", :same, 0.0622},
    {"how-to", "how to", :same, 0.0646},
    {"Postgres", "PostgreSQL", :same, 0.066},
    {"organisation", "organization", :same, 0.0669},
    {"sourdough", "sourdough bread", :same, 0.0699},
    {"cookie", "cookies", :same, 0.0727},
    {"New York City", "NYC", :same, 0.0879},
    {"AI", "artificial intelligence", :same, 0.1172},
    {"photo", "photograph", :same, 0.1232},
    {"email", "e-mail", :same, 0.1261},
    {"healthcare", "health care", :same, 0.1268},
    {"JavaScript", "JS", :same, 0.1299},
    {"machine learning", "ML", :same, 0.2464},
    {"vegan", "plant-based", :same, 0.267},
    {"UX", "user experience", :same, 0.2679},
    {"recipes", "cooking", :related, 0.0893},
    {"frontend", "backend", :related, 0.1274},
    {"breakfast", "lunch", :related, 0.1737},
    {"baking", "sourdough", :related, 0.1834},
    {"tea", "coffee", :related, 0.2343},
    {"cats", "dogs", :related, 0.2361},
    {"photography", "video", :related, 0.26},
    {"privacy", "security", :related, 0.2611},
    {"health", "fitness", :related, 0.2663},
    {"Python", "JavaScript", :related, 0.2797},
    {"travel", "hotels", :related, 0.2841},
    {"design", "UX", :related, 0.2927},
    {"marketing", "sales", :related, 0.2992},
    {"news", "opinion", :related, 0.3795},
    {"Elixir", "Erlang", :related, 0.3951},
    {"knitting", "finance", :unrelated, 0.3917},
    {"travel", "databases", :unrelated, 0.41},
    {"poetry", "SQL", :unrelated, 0.4224},
    {"Python", "gardening", :unrelated, 0.424},
    {"marketing", "astronomy", :unrelated, 0.4564},
    {"music", "plumbing", :unrelated, 0.4572},
    {"cats", "taxes", :unrelated, 0.461},
    {"vegan", "firmware", :unrelated, 0.4617},
    {"recipes", "kernel", :unrelated, 0.4657},
    {"tea", "carburetors", :unrelated, 0.52}
  ]

  @doc "`[{label_a, label_b, kind, distance}]`."
  def pairs, do: @pairs
end
