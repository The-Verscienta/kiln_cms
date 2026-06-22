defmodule KilnCMSWeb.Presence do
  @moduledoc """
  Tracks which editors currently have a given Page/Post open in the block
  editor, so the UI can show a live "who's editing" indicator and surface
  potential conflicts before two people clobber each other's work.

  Each open editor `track/3`s itself on the per-item topic `editing:<kind>:<id>`
  keyed by user id; metadata carries the display name. Joins/leaves arrive as
  `%Phoenix.Socket.Broadcast{event: "presence_diff"}` to subscribers of that
  topic.
  """
  use Phoenix.Presence,
    otp_app: :kiln_cms,
    pubsub_server: KilnCMS.PubSub

  @doc "PubSub/Presence topic for a content item's editing session."
  def topic(kind, id), do: "editing:#{kind}:#{id}"

  @doc """
  Track the given user as editing `{kind, id}` on the LiveView's transport pid.
  Returns the topic so the caller can also subscribe to diffs.
  """
  def track_editor(pid, kind, id, user) do
    topic = topic(kind, id)

    track(pid, topic, user.id, %{
      name: display_name(user),
      online_at: System.system_time(:second)
    })

    topic
  end

  @doc "The distinct editors currently on a content item, as `%{id, name}` maps."
  def editors(kind, id) do
    kind
    |> topic(id)
    |> list()
    |> Enum.map(fn {user_id, %{metas: [meta | _]}} ->
      %{id: user_id, name: meta.name}
    end)
  end

  # `email` is an `Ash.CiString`, so normalise via `to_string/1` rather than
  # guarding on `is_binary/1`.
  defp display_name(%{email: email}) when not is_nil(email),
    do: email |> to_string() |> String.split("@") |> hd()

  defp display_name(_), do: "Someone"
end
