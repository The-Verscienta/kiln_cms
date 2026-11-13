defmodule KilnCMS.Backups.Markers do
  @moduledoc """
  The retention markers on this host's disk, as the Backups page shows them
  (#2542).

    * A **recovery point**, `kiln-<stamp>.keep` in `db/` or `media/`, pins
      every component of that stamp against retention.
    * The **last-good marker**, `kiln-<stamp>.good`, pins one component of one
      stamp: the one in `db/` keeps that dump from `scripts/backup.sh prune`,
      the one in `media/` that media set. The app moves it
      (`KilnCMS.Backups.Retention`, `KilnCMS.Backups.MarkerSyncWorker`).

  Read on every render of the page, never stored: the markers are on disk by
  design (#2219), so they survive a database restore, and the backup directory
  may be one per host (#2218). Two `File.ls/1` calls; a directory that is
  missing or can't be listed contributes no markers. This never fails: a
  display of the markers must not take the page down with it.

  Names are parsed with `KilnCMS.Backups.Artifact.parse_keep_name/1` and
  `parse_good_name/1`, so a marker-shaped name with a bad stamp is ignored here
  as it is by retention.
  """
  alias KilnCMS.Backups.Artifact

  @components [:db, :media]

  @type stamps :: %{db: MapSet.t(String.t()), media: MapSet.t(String.t())}
  @type t :: %{keep: stamps(), good: stamps()}

  @doc "No markers: what `read/1` returns for an empty or unreadable directory."
  @spec empty() :: t()
  def empty do
    none = Map.new(@components, &{&1, MapSet.new()})
    %{keep: none, good: none}
  end

  @doc "The `.keep` and `.good` stamps in `dir`'s `db/` and `media/`."
  @spec read(Path.t() | nil) :: t()
  def read(dir) when is_binary(dir) do
    Enum.reduce(@components, empty(), fn component, acc ->
      names = list(dir, component)

      acc
      |> put_in([:keep, component], stamps(names, &Artifact.parse_keep_name/1))
      |> put_in([:good, component], stamps(names, &Artifact.parse_good_name/1))
    end)
  end

  def read(_no_dir), do: empty()

  @doc """
  Whether `stamp` is a recovery point. A `.keep` in either directory pins the
  whole stamp, so this does not ask which.
  """
  @spec recovery_point?(t(), String.t() | nil) :: boolean()
  def recovery_point?(%{keep: keep}, stamp) when is_binary(stamp),
    do: Enum.any?(@components, &MapSet.member?(keep[&1], stamp))

  def recovery_point?(_markers, _stamp), do: false

  @doc "The components whose last-good marker names `stamp`, in `[:db, :media]` order."
  @spec last_good_components(t(), String.t() | nil) :: [:db | :media]
  def last_good_components(%{good: good}, stamp) when is_binary(stamp),
    do: Enum.filter(@components, &MapSet.member?(good[&1], stamp))

  def last_good_components(_markers, _stamp), do: []

  @doc """
  The stamp `component`'s last-good marker names, or `nil`. The app keeps one
  per directory; should there be more (an operator's copy, a removal that
  failed), the newest stamp is the one that answers. Stamps sort as text.
  """
  @spec last_good(t(), :db | :media) :: String.t() | nil
  def last_good(%{good: good}, component) do
    case MapSet.to_list(Map.get(good, component, MapSet.new())) do
      [] -> nil
      stamps -> Enum.max(stamps)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp list(dir, component) do
    case File.ls(Path.join(dir, Atom.to_string(component))) do
      {:ok, names} -> names
      {:error, _missing_or_unreadable} -> []
    end
  end

  defp stamps(names, parse) do
    for name <- names, {:ok, stamp} <- [parse.(name)], into: MapSet.new(), do: stamp
  end
end
