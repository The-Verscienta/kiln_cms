defmodule KilnCMS.Backups.Artifact do
  @moduledoc """
  One file a backup run produced (#2217), embedded in `KilnCMS.Backups.Run`'s
  `artifacts`.

  `name` is the **filename only** (`kiln-db-20260805-031700.dump`); the local
  path is derived from `KilnCMS.Backups.dir/0` and the kind's subdirectory, so
  a Run stays true when the backup directory moves. `destinations` is keyed by
  `"local"` or `"rclone:<redacted remote>"`, each value a map with a `"status"`
  of `pending | ok | failed | pruned` and optional `"at"`, `"error"`, `"ref"`.

  `parts`, `sha256`, `verified` and `encrypted?` are reserved for the follow-ons
  that fill them (#2218 split/verify, #2224 encryption); today `parts` is `[]`
  (a single file) and `sha256` is `nil`.
  """
  use Ash.Resource, data_layer: :embedded

  alias KilnCMS.Backups.Artifact.ValidateDestinations

  @kinds [:db, :media]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:kind, :name, :bytes, :sha256, :verified, :parts, :encrypted?, :destinations]
      validate ValidateDestinations
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:kind, :name, :bytes, :sha256, :verified, :parts, :encrypted?, :destinations]
      validate ValidateDestinations
    end
  end

  attributes do
    attribute :kind, :atom do
      allow_nil? false
      constraints one_of: @kinds
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      constraints max_length: 255
      public? true
    end

    attribute :bytes, :integer do
      allow_nil? false
      default 0
      constraints min: 0
      public? true
    end

    attribute :sha256, :string, public?: true

    attribute :verified, :boolean, allow_nil?: false, default: false, public?: true

    # `[]` = a single file. Else maps of `"name"`, `"bytes"`, `"sha256"`.
    attribute :parts, {:array, :map}, allow_nil?: false, default: [], public?: true

    attribute :encrypted?, :boolean, allow_nil?: false, default: false, public?: true

    attribute :destinations, :map, allow_nil?: false, default: %{}, public?: true
  end

  @doc "The artifact kinds."
  def kinds, do: @kinds

  @doc "The subdirectory under the backup directory a kind lives in."
  @spec subdir(atom()) :: String.t()
  def subdir(:db), do: "db"
  def subdir(:media), do: "media"

  @name ~r/\Akiln-(db|media)-(\d{8}-\d{6})\.(dump|tar\.gz)(\.partial)?\z/

  @doc """
  Parse a backup file name (`kiln-db-<stamp>.dump`, `kiln-media-<stamp>.tar.gz`,
  either with a `.partial` suffix) into `{:ok, kind, stamp, partial?}`, or
  `:error`.

  The kind and extension must agree: `kiln-db-<stamp>.tar.gz` is not something
  either backup path writes, so it is not an artifact. The stamp is only
  checked for shape here; `parse_stamp/1` says whether it is a real instant.
  """
  @spec parse_name(String.t()) :: {:ok, atom(), String.t(), boolean()} | :error
  def parse_name(name) when is_binary(name) do
    case Regex.run(@name, name) do
      [_, "db", stamp, "dump" | rest] -> {:ok, :db, stamp, rest != []}
      [_, "media", stamp, "tar.gz" | rest] -> {:ok, :media, stamp, rest != []}
      _ -> :error
    end
  end

  def parse_name(_other), do: :error

  @doc """
  The stamp for an instant: `YYYYMMDD-HHMMSS` in UTC.

  Byte-identical to `scripts/backup.sh`'s `date -u +%Y%m%d-%H%M%S`, so both
  paths sort together in a directory listing and `restore.sh`'s "newest
  matching glob" picks up whichever ran last regardless of which wrote it.
  """
  @spec stamp(DateTime.t()) :: String.t()
  def stamp(%DateTime{} = at) do
    at
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%d-%H%M%S")
  end

  @doc """
  The instant a stamp names (UTC), or `:error` for a stamp of the right shape
  that is not a real moment (`20261340-996199`) or outside 1970-9999.
  """
  @spec parse_stamp(String.t()) :: {:ok, DateTime.t()} | :error
  def parse_stamp(
        <<y::binary-size(4), mo::binary-size(2), d::binary-size(2), ?-, h::binary-size(2),
          mi::binary-size(2), s::binary-size(2)>>
      ) do
    with {year, ""} when year >= 1970 <- Integer.parse(y),
         [month, day, hour, minute, second] <- Enum.map([mo, d, h, mi, s], &String.to_integer/1),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second) do
      DateTime.from_naive(naive, "Etc/UTC")
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def parse_stamp(_other), do: :error

  @doc """
  The attribute map for a `Manifest` artifact (`%{kind, path, bytes, verified}`),
  or `:error` when it is not one this module can represent (unknown kind, no
  usable file name). `offsite` is the manifest's off-site remote, if any; it is
  redacted before it becomes a destination key.

  Pure: no I/O, so a manifest that names a missing file still maps. Cron input
  is untrusted — the name is reduced to its basename and the bytes clamped.
  """
  @spec from_manifest(map(), String.t() | nil) :: {:ok, map()} | :error
  def from_manifest(artifact, offsite \\ nil)

  def from_manifest(%{kind: kind, path: path} = artifact, offsite)
      when is_binary(kind) and is_binary(path) do
    with {:ok, kind} <- kind(kind),
         name when name not in ["", ".", ".."] <- Path.basename(path) do
      bytes = artifact |> Map.get(:bytes) |> bytes()

      {:ok,
       %{
         kind: kind,
         name: String.slice(name, 0, 255),
         bytes: bytes,
         verified: Map.get(artifact, :verified) == true,
         destinations: destinations(offsite)
       }}
    else
      _ -> :error
    end
  end

  def from_manifest(_artifact, _offsite), do: :error

  defp kind("db"), do: {:ok, :db}
  defp kind("media"), do: {:ok, :media}
  defp kind(_other), do: :error

  defp bytes(bytes) when is_integer(bytes) and bytes >= 0, do: bytes
  defp bytes(_other), do: 0

  defp destinations(nil), do: %{"local" => %{"status" => "ok"}}
  defp destinations(""), do: destinations(nil)

  defp destinations(remote) when is_binary(remote) do
    %{
      "local" => %{"status" => "ok"},
      ("rclone:" <> KilnCMS.Backups.Redact.text(remote)) => %{"status" => "ok"}
    }
  end

  defp destinations(_other), do: destinations(nil)
end
