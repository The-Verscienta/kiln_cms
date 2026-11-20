defmodule KilnCMS.Backups.Destination.RemotePath do
  @moduledoc """
  The path rules Kiln's own remote destinations share (#2221, #2222): what a
  folder setting may hold, which file references a call may touch, and which
  names a listing may answer.

    * `segments/2` — a folder setting (S3's `prefix`, SFTP's `path`) as
      `/`-separated segments of `A-Z a-z 0-9 . _ -`, none of them `.` or `..`,
      slashes at either end dropped, at most 512 bytes. No other character
      reaches a remote path, so none needs quoting or can climb out;
    * `safe_ref/2` — a file a call names: `subdir` is `"db"` or `"media"`,
      and `name` one segment of those characters;
    * `listed_name?/1` — a name a listing may answer: one segment, no NUL,
      and a whole backup file (`KilnCMS.Backups.Destination.backup_file?/1`).
  """

  alias KilnCMS.Backups.Destination

  @subdirs ["db", "media"]
  @segment ~r/\A[A-Za-z0-9._-]{1,255}\z/
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
