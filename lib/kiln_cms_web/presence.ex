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

  @doc "Presence topic for open pop-out preview windows of a content item."
  def preview_topic(kind, id), do: "previewing:#{kind}:#{id}"

  @doc "PubSub topic remote cursor positions are broadcast on for a preview."
  def preview_cursor_topic(kind, id), do: "preview_cursor:#{kind}:#{id}"

  @doc """
  Track an open pop-out preview window for `{kind, id}`. The editor subscribes
  to diffs on this topic so it can skip building preview payloads when no
  window is listening.
  """
  def track_preview(pid, kind, id) do
    topic = preview_topic(kind, id)
    track(pid, topic, "viewer", %{online_at: System.system_time(:second)})
    topic
  end

  @doc """
  Track one identified viewer of a shared preview (#343) under a per-window
  `viewer_key`, carrying the display name + a stable colour so co-viewers see
  who else is watching (and whose cursor is whose). Still lands on
  `preview_topic/2`, so the editor's `previews_open?/2` keeps working.
  """
  def track_preview_viewer(pid, kind, id, viewer_key, user) do
    topic = preview_topic(kind, id)

    track(pid, topic, viewer_key, %{
      viewer_key: viewer_key,
      name: display_name(user),
      color: viewer_color(viewer_key),
      online_at: System.system_time(:second)
    })

    topic
  end

  @doc "The identified viewers currently on a preview, as `%{key, name, color}` maps."
  def preview_viewers(kind, id) do
    kind
    |> preview_topic(id)
    |> list()
    |> Enum.map(fn {key, %{metas: [meta | _]}} ->
      %{key: key, name: Map.get(meta, :name, "Someone"), color: Map.get(meta, :color, "#64748b")}
    end)
    |> Enum.sort_by(& &1.name)
  end

  # A stable colour per viewer key, from a small accessible palette — deterministic
  # so a viewer's colour is the same in every co-viewer's window.
  @palette ~w(#e11d48 #d97706 #16a34a #0891b2 #4f46e5 #9333ea #db2777 #0d9488)
  @doc "A stable display colour for a viewer key."
  def viewer_color(key), do: Enum.at(@palette, :erlang.phash2(key, length(@palette)))

  @doc "Whether any pop-out preview window is open for `{kind, id}`."
  def previews_open?(kind, id) do
    kind |> preview_topic(id) |> list() |> map_size() > 0
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

  @doc """
  Rename a tracked preview viewer in place (#379 — a token-preview guest picking
  a display name). Co-viewers see the change via the normal presence diff.
  """
  def rename_preview_viewer(pid, kind, id, viewer_key, name) do
    update(pid, preview_topic(kind, id), viewer_key, fn meta ->
      %{meta | name: display_name(%{name: name})}
    end)
  end

  # Privacy (#214): show the user's chosen display name to other editors, never
  # their email local-part (which leaks the address / naming convention). Falls
  # back to a neutral handle when no name is set — identity stays keyed by user
  # id, so unnamed editors are still tracked distinctly.
  @doc "A display name for a user — their `name`, or a neutral fallback."
  def display_name(%{name: name}) when is_binary(name) and name != "", do: name
  def display_name(_), do: "Someone"
end
