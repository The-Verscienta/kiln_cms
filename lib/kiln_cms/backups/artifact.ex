defmodule KilnCMS.Backups.Artifact do
  @moduledoc """
  One file a backup run produced (#2217), embedded in `KilnCMS.Backups.Run`'s
  `artifacts`.

  `name` is the **filename only** (`kiln-db-20260805-031700.dump`); the local
  path is derived from `KilnCMS.Backups.dir/0` and the kind's subdirectory, so
  a Run stays true when the backup directory moves. `destinations` is keyed by
  `"local"` or `"rclone:<redacted remote>"`, each value a map with a `"status"`
  of `pending | ok | failed | pruned` and optional `"at"`, `"error"`, `"ref"`.

  `parts` is `[]` for a single file. A media set written in several parts
  (#2218) is ONE artifact: `name` is the logical `kiln-media-<stamp>` (never
  join it to a path directly; use `files/1`), `parts` lists
  `%{"name", "bytes", "sha256"}` maps in order (plus `"oversize"` and
  `"destinations"` where they apply), and `sha256` is the digest of the parts'
  bytes concatenated in order. `encrypted?` stays reserved for #2224.

  File names are built and parsed here and nowhere else: `parse_file/1`,
  `part_name/2`, `set_names/2`, `sidecar_name/2`, `parse_sidecar_name/1`,
  `keep_name/1`, `parse_keep_name/1`, `good_name/1`, `parse_good_name/1`.
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

  @name ~r/\Akiln-(db|media)-(\d{8}-\d{6})(?:\.part(\d{2,}))?\.(dump|tar\.gz)(\.partial)?\z/

  @typedoc "A parsed backup file name; `part` is `nil` for a single-file artifact."
  @type parsed :: %{
          kind: :db | :media,
          stamp: String.t(),
          part: pos_integer() | nil,
          partial?: boolean()
        }

  @doc """
  Parse a backup file name into `{:ok, %{kind, stamp, part, partial?}}`, or
  `:error`.

  Accepts `kiln-db-<stamp>.dump`, `kiln-media-<stamp>.tar.gz` and, for media,
  `kiln-media-<stamp>.partNN.tar.gz` (`part` is the integer; at least two
  digits, widening past 99), each with an optional `.partial` suffix. The kind
  and extension must agree, a db file has no parts, parts count from 1, and a
  padded `part0001` is refused so one part never has two names. The stamp is
  only checked for shape here; `parse_stamp/1` says whether it is a real
  instant.

  Sidecars (`kiln-media-<stamp>.sha256`) are not artifacts and return `:error`.
  """
  @spec parse_file(String.t()) :: {:ok, parsed()} | :error
  def parse_file(name) when is_binary(name) do
    case Regex.run(@name, name) do
      [_, "db", stamp, "", "dump" | rest] ->
        {:ok, %{kind: :db, stamp: stamp, part: nil, partial?: rest != []}}

      [_, "media", stamp, part, "tar.gz" | rest] ->
        with {:ok, part} <- part_number(part) do
          {:ok, %{kind: :media, stamp: stamp, part: part, partial?: rest != []}}
        end

      _ ->
        :error
    end
  end

  def parse_file(_other), do: :error

  defp part_number(""), do: {:ok, nil}

  defp part_number(digits) do
    case Integer.parse(digits) do
      {n, ""} when n >= 1 -> if digits == pad(n), do: {:ok, n}, else: :error
      _ -> :error
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  The pre-#2218 shape of `parse_file/1`: `{:ok, kind, stamp, partial?}`, or
  `:error`. A part of a media set parses like the file it is; callers that must
  tell parts from single files use `parse_file/1`.
  """
  @spec parse_name(String.t()) :: {:ok, atom(), String.t(), boolean()} | :error
  def parse_name(name) do
    with {:ok, %{kind: kind, stamp: stamp, partial?: partial?}} <- parse_file(name),
         do: {:ok, kind, stamp, partial?}
  end

  @doc """
  The file name of part `index` (1-based) of a media set:
  `kiln-media-<stamp>.part01.tar.gz`. Two digits at least, widening past 99
  (`part100`), so sorting by the parsed integer, never the string, is the rule.
  """
  @spec part_name(String.t(), pos_integer()) :: String.t()
  def part_name(stamp, index) when is_binary(stamp) and is_integer(index) and index >= 1,
    do: "kiln-media-#{stamp}.part#{pad(index)}.tar.gz"

  @doc """
  The file names of a media set of `total` parts, in order.

  A set of exactly one part keeps the legacy name `kiln-media-<stamp>.tar.gz`
  (what `scripts/backup.sh` writes, and what external globs and rclone filters
  already match); two or more use `part_name/2`.
  """
  @spec set_names(String.t(), pos_integer()) :: [String.t()]
  def set_names(stamp, 1) when is_binary(stamp), do: ["kiln-media-#{stamp}.tar.gz"]

  def set_names(stamp, total) when is_binary(stamp) and is_integer(total) and total >= 2,
    do: Enum.map(1..total, &part_name(stamp, &1))

  @doc """
  The checksum sidecar for a stamp's artifact (`kiln-db-<stamp>.sha256`,
  `kiln-media-<stamp>.sha256`), in `sha256sum -c` format (see `Checksum`).
  """
  @spec sidecar_name(:db | :media, String.t()) :: String.t()
  def sidecar_name(kind, stamp) when kind in @kinds and is_binary(stamp),
    do: "kiln-#{kind}-#{stamp}.sha256"

  @sidecar_name ~r/\Akiln-(db|media)-(\d{8}-\d{6})\.sha256(\.partial)?\z/

  @doc """
  Parse a checksum sidecar's name (`kiln-<kind>-<stamp>.sha256`, optionally
  `.partial` while it is being written) into `{:ok, %{kind, stamp, partial?}}`,
  or `:error`.
  """
  @spec parse_sidecar_name(String.t()) ::
          {:ok, %{kind: :db | :media, stamp: String.t(), partial?: boolean()}} | :error
  def parse_sidecar_name(name) when is_binary(name) do
    case Regex.run(@sidecar_name, name) do
      [_, kind, stamp | rest] ->
        {:ok, kind} = kind(kind)
        {:ok, %{kind: kind, stamp: stamp, partial?: rest != []}}

      nil ->
        :error
    end
  end

  def parse_sidecar_name(_other), do: :error

  @doc """
  The recovery-point marker for a stamp (#2219): `kiln-<stamp>.keep`. An entry
  of this name in `db/` or `media/` pins every component of that stamp against
  retention (`KilnCMS.Backups.Retention`, `scripts/backup.sh prune`). Only its
  presence counts; its contents are never read.
  """
  @spec keep_name(String.t()) :: String.t()
  def keep_name(stamp) when is_binary(stamp), do: "kiln-#{stamp}.keep"

  @keep_name ~r/\Akiln-(\d{8}-\d{6})\.keep\z/

  @doc "The stamp a `keep_name/1` marker names, as `{:ok, stamp}`, or `:error`."
  @spec parse_keep_name(String.t()) :: {:ok, String.t()} | :error
  def parse_keep_name(name) when is_binary(name) do
    case Regex.run(@keep_name, name) do
      [_, stamp] -> {:ok, stamp}
      nil -> :error
    end
  end

  def parse_keep_name(_other), do: :error

  @doc """
  The last-good marker for a stamp (#2219): `kiln-<stamp>.good`. Unlike a
  recovery point it lives in ONE component's directory and pins only that
  component of that stamp: `db/kiln-<stamp>.good` keeps the dump from
  `scripts/backup.sh prune`, never the media of the same stamp. The app keeps
  it on the newest verified backup of each kind (`Retention.sync_last_good/1`)
  so the cron prune, which has no run history, keeps that backup too. Only its
  presence counts; its contents are never read.
  """
  @spec good_name(String.t()) :: String.t()
  def good_name(stamp) when is_binary(stamp), do: "kiln-#{stamp}.good"

  @good_name ~r/\Akiln-(\d{8}-\d{6})\.good\z/

  @doc "The stamp a `good_name/1` marker names, as `{:ok, stamp}`, or `:error`."
  @spec parse_good_name(String.t()) :: {:ok, String.t()} | :error
  def parse_good_name(name) when is_binary(name) do
    case Regex.run(@good_name, name) do
      [_, stamp] -> {:ok, stamp}
      nil -> :error
    end
  end

  def parse_good_name(_other), do: :error

  @doc """
  The file names an artifact occupies in its kind's subdirectory, in order:
  `[name]` for a single file, else the names of its `parts`.
  """
  @spec files(%{name: String.t(), parts: list()} | map()) :: [String.t()]
  def files(%{parts: [_ | _] = parts}) do
    for %{} = part <- parts, name = part["name"] || part[:name], is_binary(name), do: name
  end

  def files(%{name: name}), do: [name]

  @doc """
  Fold flat per-file attribute maps (what `from_manifest/2` returns, one per
  manifest entry) into artifact attribute maps.

  The files of one media set (`.partNN` names sharing a stamp) become ONE
  artifact: logical name `kiln-media-<stamp>`, `parts` in numeric part order,
  `bytes` summed, `verified` only if every part is, `sha256` only when the
  set is a single file (the digest of concatenated parts cannot be derived from
  per-part digests). Anything else passes through unchanged, in first-seen
  order.
  """
  @spec group_files([map()]) :: [map()]
  def group_files(entries) when is_list(entries) do
    keyed =
      Enum.map(entries, fn entry ->
        case parse_file(entry.name) do
          {:ok, %{kind: :media, stamp: stamp, part: part}} when is_integer(part) ->
            {{:set, stamp}, part, entry}

          _other ->
            {{:single, make_ref()}, nil, entry}
        end
      end)

    keyed
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn
      {{:single, _}, _, entry} ->
        plain(entry)

      {{:set, stamp} = key, _, _} ->
        members = for {^key, part, entry} <- keyed, do: {part, entry}
        merge_set(stamp, members |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)))
    end)
  end

  defp merge_set(stamp, [only] = members) when is_map(only) do
    if only[:parts_total] in [nil, 1] and single_name?(only.name, stamp),
      do: plain(only),
      else: do_merge_set(stamp, members)
  end

  defp merge_set(stamp, members), do: do_merge_set(stamp, members)

  # Manifest-only keys never reach the embedded create action.
  defp plain(entry), do: Map.drop(entry, [:part, :parts_total, :oversize])

  defp single_name?(name, stamp), do: name == "kiln-media-#{stamp}.tar.gz"

  defp do_merge_set(stamp, members) do
    parts =
      Enum.map(members, fn m ->
        %{"name" => m.name, "bytes" => m.bytes, "sha256" => m[:sha256]}
        |> maybe_put("oversize", m[:oversize])
        |> maybe_put("destinations", m[:destinations])
      end)

    %{
      kind: :media,
      name: "kiln-media-#{stamp}",
      bytes: members |> Enum.map(& &1.bytes) |> Enum.sum(),
      verified: Enum.all?(members, &(&1.verified == true)),
      sha256: nil,
      parts: parts,
      destinations: set_destinations(members)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when value in [%{}, false], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # A destination counts for the set only if every part reached it.
  defp set_destinations(members) do
    maps = Enum.map(members, &(&1[:destinations] || %{}))
    keys = maps |> Enum.map(&MapSet.new(Map.keys(&1))) |> Enum.reduce(&MapSet.intersection/2)

    Map.new(keys, fn key ->
      per_part = Enum.map(maps, &Map.fetch!(&1, key))

      if Enum.all?(per_part, &(&1["status"] == "ok")),
        do: {key, %{"status" => "ok"}},
        else: {key, Enum.find(per_part, &(&1["status"] != "ok"))}
    end)
  end

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
  The attribute map for a `Manifest` artifact (`%{kind, path, bytes, verified}`
  plus the optional `sha256`, `part` and `parts_total` of #2218; invalid ones
  are dropped),
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
       }
       |> maybe_put(:sha256, sha256(Map.get(artifact, :sha256)))
       |> maybe_put(:part, count(Map.get(artifact, :part)))
       |> maybe_put(:parts_total, count(Map.get(artifact, :parts_total)))}
    else
      _ -> :error
    end
  end

  def from_manifest(_artifact, _offsite), do: :error

  defp sha256(value) when is_binary(value) do
    if value =~ ~r/\A[0-9a-fA-F]{64}\z/, do: String.downcase(value), else: nil
  end

  defp sha256(_other), do: nil

  defp count(value) when is_integer(value) and value >= 1, do: value
  defp count(_other), do: nil

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
