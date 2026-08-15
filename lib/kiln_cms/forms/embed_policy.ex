defmodule KilnCMS.Forms.EmbedPolicy do
  @moduledoc """
  The middle rung of the framing-allowlist ladder (#1131):

      form.embed_origins  ->  SiteEmbedSettings.embed_origins  ->  EMBED_ORIGINS

  — and, since #1133, the place the operator's ceiling is applied on the read:
  under `EMBED_ORIGINS_LOCKED`, whichever tenant rung answers is clamped to
  `EMBED_ORIGINS` before it is served (`KilnCMS.Forms.EmbedCeiling`).

  `KilnCMSWeb.Embed` already resolves the form-vs-deployment half — its own
  `own_origins/1` is "the only reader of the [form] attribute's shape," and
  every function there still means exactly what its own moduledoc says.
  Rather than teach `Embed` a second data source, `effective/1` resolves the
  org rung *before* handing anything to it: a form whose own list is `nil`
  and whose org has a configured default is handed back as a form-shaped map
  carrying that default in `embed_origins` instead, so every existing
  `Embed.*` function — `content_security_policy/1`, `frame_ancestors_for/1`,
  `cross_site?/1`, `allowed_origins_label/1`, `warn_if_framing_blocked/2` —
  needs no change and keeps meaning what it already means. A form that has
  its own list, or whose org has none configured, passes through unchanged.

  `KilnCMS.CMS.SiteEmbedSettings` is the row this reads. Nothing outside this
  module should read it directly, for the same reason `KilnCMS.CMS.TaskSettings`
  exists: absence is the default, so an org that has never opened the setting
  has no row, and resolving that here — rather than in every call site — keeps
  the embed route from writing one as a side effect of being rendered.

  ## One caveat `own_origins/1`'s wording no longer fully covers

  `KilnCMSWeb.Embed.warn_if_framing_blocked/2` names *which* setting closed a
  blocked embed — "this form's own Embed allowlist" or `EMBED_ORIGINS` — by
  re-deriving it from the (now rewritten) effective form, so a close caused by
  an org default of `[]` reads as "this form's own." Both remedies point the
  operator at editable settings and an org default `[]` is a rarer
  configuration than a form's own, so the imprecision costs a slightly wrong
  pointer in an already-rare warning log, not a wrong *policy* — every
  render/serve function stays correct either way.
  """

  alias KilnCMS.CMS.SiteEmbedSettings
  alias KilnCMS.Forms.EmbedCeiling

  @doc """
  This org's configured default, or `nil` when it has none (no row, or a row
  whose `embed_origins` is itself `nil`) — the same "fall through to the next
  rung" state `Form.embed_origins: nil` carries.

  Takes an org id; `nil` in (no tenant to ask) answers `nil` without a query,
  the same "nothing to speak for" rule `Embed.own_origins(nil)` follows one
  rung up.
  """
  @spec org_default(Ash.UUID.t() | nil) :: [String.t()] | nil
  def org_default(nil), do: nil

  def org_default(org_id) do
    SiteEmbedSettings
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: org_id)
    |> case do
      {:ok, %SiteEmbedSettings{embed_origins: origins}} when is_list(origins) -> origins
      {:ok, _no_row_or_unset} -> nil
      {:error, _reason} -> nil
    end
  end

  @doc """
  `form`, with its effective allowlist substituted in when it has none of its
  own and its org has configured a default — the value every `KilnCMS.Web.Embed`
  function should be handed in place of the raw form from here on.

  `nil` in (no form to speak for — a 404) is `nil` out: there is no org to ask
  either, and `Embed.own_origins(nil)` already answers the deployment
  question directly, which is the correct answer for a slug that doesn't
  exist.

  A form whose `embed_origins` was not selected (`%Ash.NotLoaded{}`) is
  refused, not defaulted — same rule `Embed.own_origins/1` enforces for the
  same reason: a narrowed read must not silently regain the deployment-wide
  policy a form (or now an org) had deliberately narrowed away from.
  """
  @spec effective(map() | nil) :: map() | nil
  def effective(nil), do: nil

  def effective(%{embed_origins: origins} = form) when is_list(origins), do: clamp(form)

  def effective(%{embed_origins: %Ash.NotLoaded{}} = form), do: form

  def effective(%{embed_origins: nil} = form) do
    case org_default(Map.get(form, :org_id)) do
      nil -> form
      origins -> clamp(%{form | embed_origins: origins})
    end
  end

  def effective(form), do: form

  # The operator's ceiling (#1133), applied to whichever tenant rung answered —
  # the form's own list or its org's — and never to `nil`, which is already the
  # ceiling itself (`EMBED_ORIGINS`). Identity when `EMBED_ORIGINS_LOCKED` is
  # off. Applied on the read as well as refused on the write, so a list saved
  # before the cap was turned on cannot keep the page wider than the operator
  # now allows.
  defp clamp(%{embed_origins: origins} = form) when is_list(origins),
    do: %{form | embed_origins: EmbedCeiling.clamp(origins)}
end
