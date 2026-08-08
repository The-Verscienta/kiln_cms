defmodule KilnCMS.CMS.Audiences do
  @moduledoc """
  Consumer-facing access tiers ("audiences") — the *read* axis, kept separate
  from the editorial RBAC `role` (the *authoring* axis).

  A `role` (`:admin`/`:editor`/`:viewer`) decides who may author and publish. An
  **audience** decides which signed-in end-users may *read* a published record —
  the consumer-facing access model (e.g. Directus "Professional"/"Patient"
  access). Each content record carries one `audience`; each user carries the set
  of `audiences` they belong to. A reader may see a published record when its
  audience is `:public`, or when its audience is one of the reader's audiences.
  Editors and admins see everything regardless.

  The list is configured via `config :kiln_cms, :audiences` and read at **compile
  time** — the Ash `one_of` constraints bake it in, so changing it needs a
  recompile (a deliberate trade for static validation). `:public` is always
  implied; it must stay first and never gates anything. Defaults to
  `[:public, :member]`.
  """
  @audiences Application.compile_env(:kiln_cms, :audiences, [:public, :member])

  @doc "Every configured audience, `:public` first."
  @spec all() :: [atom()]
  def all, do: @audiences

  @doc "Audiences other than `:public` — the ones that actually gate content."
  @spec gated() :: [atom()]
  def gated, do: @audiences -- [:public]

  @doc "Whether `audience` is a configured audience."
  @spec valid?(term()) :: boolean()
  def valid?(audience), do: audience in @audiences

  @doc """
  Whether a **loaded record** is readable by an anonymous visitor — published,
  `:public`, and not behind a passphrase (#496).

  The one definition of that rule for the surfaces that decide it in memory,
  rather than in an Ash `expr`. Those surfaces are the ones with no actor to
  authorize against: the Meilisearch index (#1006), an ActivityPub Announce
  (#491), related-content suggestions. Each was spelling the same three-part
  rule its own way, and they did not agree on the case that matters — one
  defaulted a missing `audience` to `:public`, which announces a gated document
  to strangers' timelines if a `select` ever narrows the load.

  So this **fails closed**: a record that does not carry the fields cannot be
  shown to be public, and is therefore treated as not public. The alternative
  reads better and is wrong in exactly one direction.

  Ash `expr` filters (`Content`'s `search_published`, `Slugs`, the feed
  controller) express the same rule in SQL and cannot share this function; they
  are policy-gated instead, which is the stronger enforcement.
  """
  @spec public_to_anonymous?(map()) :: boolean()
  def public_to_anonymous?(record) when is_map(record) do
    Map.get(record, :state) == :published and
      Map.get(record, :audience) == :public and
      is_nil(Map.get(record, :access_password_hash, :absent))
  end

  def public_to_anonymous?(_record), do: false
end
