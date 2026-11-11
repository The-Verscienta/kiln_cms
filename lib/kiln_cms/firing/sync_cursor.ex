defmodule KilnCMS.Firing.SyncCursor do
  @moduledoc """
  The signed cursor of the sync API (`GET /api/sync`, `KilnCMS.Firing.Sync`),
  and the event id of the change feed's SSE transport (`GET /api/feed`,
  `KilnCMSWeb.FeedStream`), which is the same token: an id the stream hands out
  is a cursor `/api/sync` accepts, and the other way round.

  Signed, not encrypted: nothing in it is secret (instants, a type name and
  the last id already sent), but every part of it steers a query, so the
  client must not be able to edit it. Bound to the org it was issued for.

  A token carries `%{"o" => org id, "t" => type name or nil, "s" => surface,
  "p" => position}`, the position encoded as `["i", started_at, after]` or
  `["d", since, until, after]` (microseconds since the epoch). Signed with the
  endpoint's secret, so rotating `SECRET_KEY_BASE` invalidates every cursor.
  """

  @salt "kiln sync cursor"
  @endpoint KilnCMSWeb.Endpoint

  @surfaces KilnCMS.Firing.Surfaces.name_map()

  @typedoc "What a cursor scopes a sync to, and where it stands."
  @type t :: %{
          type: String.t() | nil,
          surface: atom(),
          position: KilnCMS.Firing.Sync.position()
        }

  @doc "Sign `position` for `org_id`, scoped to `type` (or every type) and `surface`."
  @spec sign(Ash.UUID.t(), String.t() | nil, atom() | String.t(), KilnCMS.Firing.Sync.position()) ::
          String.t()
  def sign(org_id, type, surface, position) do
    Phoenix.Token.sign(@endpoint, @salt, %{
      "o" => org_id,
      "t" => type,
      "s" => to_string(surface),
      "p" => encode_position(position)
    })
  end

  @doc """
  Verify `token` as a cursor of `org_id`. `:error` for anything else: tampered
  with, issued for another site, signed under a rotated secret, or naming a
  surface or position this build does not know.
  """
  @spec verify(String.t(), Ash.UUID.t()) :: {:ok, t()} | :error
  def verify(token, org_id) when is_binary(token) do
    with {:ok, %{"o" => ^org_id, "t" => type, "s" => surface, "p" => position}} <-
           Phoenix.Token.verify(@endpoint, @salt, token, max_age: :infinity),
         {:ok, surface} <- Map.fetch(@surfaces, surface),
         {:ok, position} <- decode_position(position) do
      {:ok, %{type: type, surface: surface, position: position}}
    else
      _invalid -> :error
    end
  end

  def verify(_token, _org_id), do: :error

  defp encode_position({:initial, started_at, after_key}),
    do: ["i", usec(started_at), encode_after(after_key)]

  defp encode_position({:delta, since, until, after_key}),
    do: ["d", usec(since), usec(until), encode_after(after_key)]

  defp encode_after(nil), do: nil
  defp encode_after({name, id}), do: [name, id]

  defp decode_position(["i", started_at, after_key]) when is_integer(started_at) do
    with {:ok, after_key} <- decode_after(after_key),
         do: {:ok, {:initial, from_usec(started_at), after_key}}
  end

  defp decode_position(["d", since, until, after_key]) when is_integer(since) do
    with {:ok, after_key} <- decode_after(after_key),
         do: {:ok, {:delta, from_usec(since), until && from_usec(until), after_key}}
  end

  defp decode_position(_other), do: :error

  defp decode_after(nil), do: {:ok, nil}
  defp decode_after([name, id]) when is_binary(name) and is_binary(id), do: {:ok, {name, id}}
  defp decode_after(_other), do: :error

  defp usec(nil), do: nil
  defp usec(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defp from_usec(usec), do: DateTime.from_unix!(usec, :microsecond)
end
