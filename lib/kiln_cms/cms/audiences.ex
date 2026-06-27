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
end
