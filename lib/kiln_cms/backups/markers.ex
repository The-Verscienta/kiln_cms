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
    * A **hold marker**, `kiln-<stamp>.hold`, pins one component of one stamp
      the same way, for every unit a schedule's keep rules hold (#2219). The
      app writes and removes it alongside the last-good marker.

  Read on every render of the page, never stored: the markers are on disk by
  design (#2219), so they survive a database restore, and the backup directory
  may be one per host (#2218). Two `File.ls/1` calls. This never fails: a
  display of the markers must not take the page down with it.

  A directory that is **missing** has no markers. One that exists and can't be
  listed (permissions, an I/O error, a file where the directory should be) is
  **unreadable** (#2799): it contributes no markers either, but `unreadable/1`
  names it, so the page can say "couldn't read" rather than "none yet", which
  would be a claim about markers it never saw.

  Names are parsed with `KilnCMS.Backups.Artifact.parse_keep_name/1`,
  `parse_good_name/1` and `parse_hold_name/1`, so a marker-shaped name with a bad stamp is ignored here
  as it is by retention.
  """
  alias KilnCMS.Backups.Artifact

  @components [:db, :media]

  @type component :: :db | :media
  @type stamps :: %{db: MapSet.t(String.t()), media: MapSet.t(String.t())}
  @type t :: %{
          keep: stamps(),
          good: stamps(),
          hold: stamps(),
          unreadable: MapSet.t(component())
        }

  @typedoc "One directory's listing, as `list/2` returns it."
  @type listing :: {:ok, [String.t()]} | {:error, File.posix() | term()}

  @doc "No markers: what `read/1` returns for an empty or missing directory."
  @spec empty() :: t()
  def empty do
    none = Map.new(@components, &{&1, MapSet.new()})
    %{keep: none, good: none, hold: none, unreadable: MapSet.new()}
  end

  @doc "The `.keep`, `.good` and `.hold` stamps in `dir`'s `db/` and `media/`."
  @spec read(Path.t() | nil) :: t()
  def read(dir) when is_binary(dir),
    do: from_listing(Map.new(@components, &{&1, list(dir, &1)}))

  def read(_no_dir), do: empty()

  @doc """
  The names in `dir`'s `component` subdirectory. A directory that doesn't
  exist is empty (`{:ok, []}`); any other failure is returned as it came, so a
  caller can tell "nothing there" from "couldn't look".
  """
  # `dir` comes from application config, never from a request.
  # sobelow_skip ["Traversal.FileModule"]
  @spec list(Path.t(), component()) :: listing()
  def list(dir, component) when is_binary(dir) and component in @components do
    case File.ls(Path.join(dir, Artifact.subdir(component))) do
      {:ok, names} -> {:ok, names}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The markers in listings already taken (`%{db: listing, media: listing}`, as
  `list/2` returns them), so a caller that lists the directories for its own
  reasons doesn't list them twice. A component without a listing, or with a
  failed one, contributes no markers; a failed one is `unreadable/1`.
  """
  @spec from_listing(%{optional(component()) => listing()}) :: t()
  def from_listing(listing) when is_map(listing) do
    Enum.reduce(@components, empty(), fn component, acc ->
      case Map.get(listing, component, {:ok, []}) do
        {:ok, names} ->
          acc
          |> put_in([:keep, component], stamps(names, &Artifact.parse_keep_name/1))
          |> put_in([:good, component], stamps(names, &Artifact.parse_good_name/1))
          |> put_in([:hold, component], stamps(names, &Artifact.parse_hold_name/1))

        {:error, _reason} ->
          Map.update!(acc, :unreadable, &MapSet.put(&1, component))
      end
    end)
  end

  @doc "Whether `component`'s directory was listed (or is missing, so has none)."
  @spec readable?(t(), component()) :: boolean()
  def readable?(%{unreadable: unreadable}, component),
    do: not MapSet.member?(unreadable, component)

  def readable?(_markers, _component), do: true

  @doc "The components whose directory couldn't be listed, in `[:db, :media]` order."
  @spec unreadable(t()) :: [component()]
  def unreadable(%{unreadable: unreadable}),
    do: Enum.filter(@components, &MapSet.member?(unreadable, &1))

  def unreadable(_markers), do: []

  @doc """
  Whether `stamp` is a recovery point. A `.keep` in either directory pins the
  whole stamp, so this does not ask which.
  """
  @spec recovery_point?(t(), String.t() | nil) :: boolean()
  def recovery_point?(%{keep: keep}, stamp) when is_binary(stamp),
    do: Enum.any?(@components, &MapSet.member?(keep[&1], stamp))

  def recovery_point?(_markers, _stamp), do: false

  @doc "The components whose last-good marker names `stamp`, in `[:db, :media]` order."
  @spec last_good_components(t(), String.t() | nil) :: [component()]
  def last_good_components(%{good: good}, stamp) when is_binary(stamp),
    do: Enum.filter(@components, &MapSet.member?(good[&1], stamp))

  def last_good_components(_markers, _stamp), do: []

  @doc "The components whose hold marker names `stamp`, in `[:db, :media]` order."
  @spec held_components(t(), String.t() | nil) :: [component()]
  def held_components(%{hold: hold}, stamp) when is_binary(stamp),
    do: Enum.filter(@components, &MapSet.member?(hold[&1], stamp))

  def held_components(_markers, _stamp), do: []

  @doc """
  The stamp `component`'s last-good marker names, or `nil`. The app keeps one
  per directory; should there be more (an operator's copy, a removal that
  failed), the newest stamp is the one that answers. Stamps sort as text.
  """
  @spec last_good(t(), component()) :: String.t() | nil
  def last_good(%{good: good}, component) do
    case MapSet.to_list(Map.get(good, component, MapSet.new())) do
      [] -> nil
      stamps -> Enum.max(stamps)
    end
  end

  defp stamps(names, parse) do
    for name <- names, {:ok, stamp} <- [parse.(name)], into: MapSet.new(), do: stamp
  end
end
