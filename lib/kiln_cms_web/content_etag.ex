defmodule KilnCMSWeb.ContentETag do
  @moduledoc """
  The `ETag` a single content record carries on the JSON:API surface, and the
  parsing of the `If-Match` a client sends back with it
  (`KilnCMSWeb.Plugs.IfMatch`, `KilnCMS.CMS.Changes.CheckExpectedVersion`).

  The tag is `"<lock_version>-<state>"`, e.g. `"4-draft"`. Opaque to clients,
  which should echo it rather than build it, but deliberately made of two
  things:

    * `lock_version` moves on every content edit (`optimistic_lock` on
      `:update` and the editor's saves);
    * `state` moves on every workflow transition, which does **not** bump
      `lock_version` — publishing changes the representation (`state`,
      `published_at`) without touching the content. A tag of `lock_version`
      alone would let a client that read a draft PATCH what had since gone
      live, believing it was still editing a draft.

  Strong, not weak (`W/`): `If-Match` uses the strong comparison, under which
  a weak tag never matches (RFC 9110 §13.1.1), and the two parts identify the
  stored state exactly.
  """

  @doc "The `ETag` value for a record, or `nil` when it lacks either part."
  @spec etag(map()) :: String.t() | nil
  def etag(%{lock_version: version, state: state})
      when is_integer(version) and is_atom(state) and not is_nil(state),
      do: ~s("#{version}-#{state}")

  def etag(_record), do: nil

  @doc """
  `AshJsonApi` `modify_conn` hook for the single-record routes: set `ETag`
  from the returned record. Absent when a sparse fieldset left out
  `lock_version` or `state` — a tag that could not be checked is worse than
  none.
  """
  def put_etag(conn, _subject, result, _request) do
    case etag(result) do
      nil -> conn
      tag -> Plug.Conn.put_resp_header(conn, "etag", tag)
    end
  end

  @doc """
  Parse an `If-Match` value: `:any` for `*`, a list of `{lock_version, state}`
  for tags this module issued, or `:mismatch` when nothing in it could ever
  match (a weak tag, a foreign tag, garbage) — which must fail the
  precondition, not be ignored, or a typo would turn a guarded write into an
  unguarded one.
  """
  @spec parse_if_match(String.t()) :: :any | :mismatch | [{integer(), String.t()}]
  def parse_if_match(value) do
    case String.trim(value) do
      "*" ->
        :any

      value ->
        value
        |> String.split(",")
        |> Enum.flat_map(&parse_tag/1)
        |> case do
          [] -> :mismatch
          tags -> tags
        end
    end
  end

  defp parse_tag(tag) do
    with "\"" <> rest <- String.trim(tag),
         {inner, "\""} <- String.split_at(rest, -1),
         [version, state] <- String.split(inner, "-", parts: 2),
         {version, ""} <- Integer.parse(version) do
      [{version, state}]
    else
      _ -> []
    end
  end
end
