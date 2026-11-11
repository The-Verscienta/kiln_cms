defmodule KilnCMS.CMS.Severity do
  @moduledoc """
  The change-severity rule: how much a *published* edit matters, asked for only
  when the edit touches a field the site lists as safety-relevant
  (`KilnCMS.CMS.SiteSafetyFields`).

  `severities/0` are the three answers. The answer is stored on the version row
  of the edit itself (`change_severity`), written by
  `KilnCMS.CMS.Changes.RecordChangeSeverity`:

    * **nil** — no safety field changed on that version (and every version
      written before this existed).
    * **the `change_severity` input** — when the caller gave one.
    * **`:notable`** — when a safety field changed and the caller did not say.
      Never `:routine`, never nil: an API, MCP or internal write that does not
      know about severity must not read as "routine".
    * **an error on `change_severity`** — only when the write carries the
      `require_change_severity` context marker (set by the admin editor, which
      shows the selector) and gave none.

  There is no batch endpoint: each request is one edit with one severity.

  ## Where it applies

  A live document's edit (`:update`, `:publish_changes`, `:restore_version`, and
  every internal writer) when a listed field's value differs from the live one,
  and a first publish (`:publish`, `:publish_scheduled`) when any listed field is
  non-empty. Not on Save of a working copy, autosave, or any edit of a draft.

  ## The settings

  `safety_fields_for/2` resolves the site's list for a content type. Empty
  settings resolve to `[]`: nothing prompts.
  """
  require Logger

  alias KilnCMS.CMS.SiteSafetyFields

  @severities [:critical, :notable, :routine]
  @ttl :timer.minutes(5)

  @doc "The severities a change can carry, most serious first."
  @spec severities() :: [:critical | :notable | :routine]
  def severities, do: @severities

  @doc "The severity written when a safety field changed and the caller gave none."
  @spec default() :: :notable
  def default, do: :notable

  @doc """
  The field names listed as safety-relevant for `type_name` (a
  `KilnCMS.CMS.ContentTypes.type_name_for/1` name) on `org_id`'s site. `[]`
  when the site listed none.

  A failed read answers `["*"]` (every field): recording a severity that was
  not strictly needed costs nothing, where silently recording none would hide a
  safety edit. The failure is logged and not cached.
  """
  @spec safety_fields_for(Ash.UUID.t() | nil, String.t() | nil) :: [String.t()]
  def safety_fields_for(nil, _type_name), do: []
  def safety_fields_for(_org_id, nil), do: []

  def safety_fields_for(org_id, type_name) do
    case resolve(org_id) do
      :error -> ["*"]
      map -> Map.get(map, type_name, [])
    end
  end

  # Cached outside a transaction (the cache fallback runs on another process,
  # which needs its own pool connection — a deadlock risk while the caller's
  # transaction holds the first); one single-row read inside one.
  defp resolve(org_id), do: resolve(org_id, KilnCMS.Repo.in_transaction?())

  defp resolve(org_id, true), do: read(org_id)

  # `Cache.fetch` declines to store a `nil`, so a failed read (`:error`) is
  # handed to it as `nil` and never cached.
  defp resolve(org_id, false) do
    KilnCMS.Cache.fetch(KilnCMS.Cache.safety_fields_key(org_id), @ttl, fn ->
      with :error <- read(org_id), do: nil
    end) || :error
  end

  defp read(org_id) do
    actor = KilnCMS.OrgSettings.system(:cms_settings)

    case KilnCMS.CMS.list_site_safety_fields(
           tenant: org_id,
           actor: actor,
           authorize_with: :error
         ) do
      {:ok, [%SiteSafetyFields{fields: fields} | _]} -> normalize(fields)
      {:ok, []} -> %{}
      {:error, reason} -> degrade(inspect(reason))
    end
  rescue
    error -> degrade(Exception.message(error))
  end

  defp degrade(detail) do
    Logger.warning(
      "safety fields lookup failed, treating every field as safety-relevant: #{detail}"
    )

    :error
  end

  defp normalize(fields) when is_map(fields) do
    Map.new(fields, fn {type, names} -> {to_string(type), Enum.map(names, &to_string/1)} end)
  end

  defp normalize(_other), do: %{}
end
