defmodule KilnCMS.Limits do
  @moduledoc """
  Ceilings for user-supplied string attributes (#542).

  AshPostgres maps `:string` to `text`, so there is no database ceiling; the
  only bound was the endpoint's 8MB request cap. That meant any single
  authenticated write could persist a multi-megabyte string into a field meant
  to hold a filename, and it would be accepted silently and then rendered into
  a table cell.

  This is **hygiene, not a live vulnerability**, and it is worth saying so
  plainly: the anonymous surface stores its free text in `FormSubmission.data`
  (a `:map`, where `max_length` would not apply anyway), so the real targets are
  client-influenced fields like `MediaItem.filename` and editor free-text like
  `alt` and `caption`. What this buys is bounded row growth and a clean
  validation error instead of a silent megabyte.

  ## Four ceilings, not ninety numbers

  Every bound comes from here so the values are consistent rather than
  ad hoc, and so raising one is a single edit with one place to argue about:

    * `identifier/0` — 255. Filenames, slugs, handles, locales, keys. The
      familiar filesystem/DNS ceiling, and far above anything legitimate.
    * `line/0` — 1_000. Single-line free text: titles, names, labels, alt text.
      Generous by an order of magnitude against real use (an SEO title is ~60
      characters, alt text ~125) so nothing anyone types is ever refused.
    * `paragraph/0` — 4_000. Multi-line free text: descriptions, captions,
      excerpts, help text. Roughly 600 words.
    * `url/0` — 2_048. The de-facto browser and CDN ceiling for a URL; longer
      than this does not survive the trip anyway.

  ## What is deliberately unbounded

  Server-derived values — hashes, signatures, storage keys, provider ids,
  denormalized search text — carry no bound, because nothing a user types
  reaches them and a ceiling would only turn an internal invariant into a
  runtime failure. `test/kiln_cms/limits_test.exs` enumerates every public
  string attribute in the tree and requires each one to either carry a bound or
  appear in its allowlist with a reason, so the next unbounded attribute is a
  decision somebody makes rather than one nobody notices.
  """

  @identifier 255
  @line 1_000
  @paragraph 4_000
  @url 2_048

  @doc "Filenames, slugs, handles, locales, keys — 255."
  @spec identifier() :: pos_integer()
  def identifier, do: @identifier

  @doc "Single-line free text: titles, names, labels, alt text — 1,000."
  @spec line() :: pos_integer()
  def line, do: @line

  @doc "Multi-line free text: descriptions, captions, excerpts — 4,000."
  @spec paragraph() :: pos_integer()
  def paragraph, do: @paragraph

  @doc "URLs — 2,048, the de-facto browser ceiling."
  @spec url() :: pos_integer()
  def url, do: @url

  @doc "Every ceiling, for the test that enumerates them."
  @spec all() :: [pos_integer()]
  def all, do: [@identifier, @line, @url, @paragraph]
end
