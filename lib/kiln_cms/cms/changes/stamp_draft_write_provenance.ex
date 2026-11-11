defmodule KilnCMS.CMS.Changes.StampDraftWriteProvenance do
  @moduledoc """
  Records, on a draft a `:draft_write` API key creates, which key made it and
  who the service says it acted for (#2273).

    * `created_via_key_id` / `created_via_key_name` — copied from the
      authenticating key. Plain values with no foreign key, so they survive the
      key being revoked or deleted.
    * `on_behalf_of` — the opaque string the service sent in
      `X-Kiln-On-Behalf-Of` (`KilnCMSWeb.Plugs.OnBehalfOf` puts it in the action
      context as `:kiln_on_behalf_of`). Control and format characters are
      stripped and it is cut to `max_length/0` characters. **Stored for display
      only: nothing authorizes on it**, and the service, not Kiln, vouches for it.

  A no-op for every other actor, so an editor's draft carries none of it. No
  action accepts these attributes, so a client cannot write them directly; a
  later update leaves them alone.
  """
  use Ash.Resource.Change

  alias KilnCMS.Accounts.ApiKey
  alias KilnCMS.Accounts.Checks.DraftWriteKey

  @max_length 200

  @doc "Longest `on_behalf_of` that is stored, in characters."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @impl true
  def change(changeset, _opts, context) do
    case context.actor do
      %{__metadata__: %{api_key: %ApiKey{} = key}} = actor ->
        if DraftWriteKey.draft_write?(actor), do: stamp(changeset, key), else: changeset

      _ ->
        changeset
    end
  end

  defp stamp(changeset, key) do
    changeset
    |> Ash.Changeset.force_change_attribute(:created_via_key_id, key.id)
    |> Ash.Changeset.force_change_attribute(
      :created_via_key_name,
      truncate(key.name, KilnCMS.Limits.line())
    )
    |> Ash.Changeset.force_change_attribute(
      :on_behalf_of,
      sanitize(changeset.context[:kiln_on_behalf_of])
    )
  end

  @doc """
  Reduce a header value to what is stored: no control, format or separator
  characters, trimmed, at most `max_length/0` characters; `nil` when nothing is
  left or the value is not text.
  """
  @spec sanitize(term()) :: String.t() | nil
  def sanitize(value) when is_binary(value) do
    if String.valid?(value) do
      value
      |> String.replace(~r/[\p{C}\p{Zl}\p{Zp}]/u, "")
      |> String.trim()
      |> truncate(@max_length)
      |> case do
        "" -> nil
        text -> text
      end
    end
  end

  def sanitize(_value), do: nil

  defp truncate(text, max), do: String.slice(text, 0, max)
end
