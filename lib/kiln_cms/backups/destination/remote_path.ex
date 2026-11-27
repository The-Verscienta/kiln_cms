defmodule KilnCMS.Backups.Destination.RemotePath do
  @moduledoc """
  The path rules Kiln's own remote destinations share (#2221, #2222): what a
  folder setting may hold, which file references a call may touch, and which
  names a listing may answer.

    * `segments/2` — a folder setting (S3's `prefix`) as `/`-separated
      segments of `A-Z a-z 0-9 . _ -`, none of them `.` or `..`, slashes at
      either end dropped, at most 512 bytes. No other character reaches a
      remote path, so none needs quoting or can climb out;
    * `folder_segments/2` — a folder on a file server (SFTP's `path`, #3199),
      where share names such as `Backup Share` are common: the same, with
      the space, `+`, `@` and `,` allowed too, and no segment starting or
      ending with a space. Still ASCII only, and still no `~`, `\\`, NUL or
      control character: a path goes to the server as a length-prefixed
      string, never through a shell, so the separators and the names that
      climb are all that could do harm;
    * `safe_ref/2` — a file a call names: `subdir` is `"db"` or `"media"`,
      and `name` one segment of those characters;
    * `listed_name?/1` — a name a listing may answer: one segment, no NUL,
      and a whole backup file (`KilnCMS.Backups.Destination.backup_file?/1`).
  """

  alias KilnCMS.Backups.Destination

  @subdirs ["db", "media"]
  @segment ~r/\A[A-Za-z0-9._-]{1,255}\z/
  @folder_segment ~r/\A[A-Za-z0-9._+@,-](?:[A-Za-z0-9._+@, -]{0,253}[A-Za-z0-9._+@,-])?\z/
  @max_path 512

  @doc "The subdirectories a destination keeps backups in."
  @spec subdirs() :: [String.t()]
  def subdirs, do: @subdirs

  @doc """
  `raw` as segments, or `{:error, message}` naming the setting by `noun`
  (`"the prefix"`). `nil` is no segments. See the moduledoc.
  """
  @spec segments(String.t() | nil, String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def segments(raw, noun)

  def segments(nil, _noun), do: {:ok, []}

  def segments(raw, noun) when is_binary(raw) do
    trimmed = raw |> String.trim() |> String.trim("/")

    segments = if trimmed == "", do: [], else: String.split(trimmed, "/")

    cond do
      byte_size(trimmed) > @max_path ->
        {:error, "#{noun} is too long"}

      Enum.any?(segments, &(not segment?(&1))) ->
        {:error,
         "#{noun} must be folder names of letters, digits, dots, hyphens and underscores, " <>
           "separated by /"}

      true ->
        {:ok, segments}
    end
  end

  def segments(_raw, noun), do: {:error, "#{noun} must be text"}

  @doc """
  `raw` as the segments of a folder on a file server, or `{:error, message}`
  naming the setting by `noun` (`"the path"`). `nil` is no segments. The
  ends of `raw` are trimmed, but a segment may not start or end with a space
  (`"a /b"`): a name like that would not read back the way it was typed. See
  the moduledoc.
  """
  @spec folder_segments(String.t() | nil, String.t()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def folder_segments(raw, noun)

  def folder_segments(nil, _noun), do: {:ok, []}

  def folder_segments(raw, noun) when is_binary(raw) do
    trimmed = raw |> String.trim() |> String.trim("/")

    segments = if trimmed == "", do: [], else: String.split(trimmed, "/")

    cond do
      byte_size(trimmed) > @max_path ->
        {:error, "#{noun} is too long"}

      Enum.any?(segments, &(&1 != "" and String.trim(&1) != &1)) ->
        {:error, "#{noun} must not have a space at the start or end of a folder name"}

      Enum.any?(segments, &(not folder_segment?(&1))) ->
        {:error,
         "#{noun} must be folder names of letters, digits, spaces and . _ - + @ , " <>
           "separated by /"}

      true ->
        {:ok, segments}
    end
  end

  def folder_segments(_raw, noun), do: {:error, "#{noun} must be text"}

  defp folder_segment?(segment),
    do: segment not in [".", ".."] and Regex.match?(@folder_segment, segment)

  @doc "Whether `segment` is one folder or file name of the allowed characters."
  @spec segment?(term()) :: boolean()
  def segment?(segment) when is_binary(segment),
    do: segment not in [".", ".."] and Regex.match?(@segment, segment)

  def segment?(_segment), do: false

  @doc """
  `:ok` when `subdir`/`name` is a file a call may touch, else
  `{:error, message}`.
  """
  @spec safe_ref(term(), term()) :: :ok | {:error, String.t()}
  def safe_ref(subdir, name) do
    if subdir in @subdirs and segment?(name),
      do: :ok,
      else: {:error, "#{inspect(subdir)}/#{inspect(name)} is not a backup file"}
  end

  @doc """
  Whether a listing may answer `name`: a single segment with no NUL, and a
  whole backup file.
  """
  @spec listed_name?(term()) :: boolean()
  def listed_name?(name) when is_binary(name) do
    not String.contains?(name, ["/", <<0>>]) and name not in ["", ".", ".."] and
      Destination.backup_file?(name)
  end

  def listed_name?(_name), do: false
end
