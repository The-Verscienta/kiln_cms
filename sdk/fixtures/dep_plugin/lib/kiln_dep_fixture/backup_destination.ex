defmodule KilnDepFixture.BackupDestination do
  @moduledoc """
  A backup destination shipped from a dependency (kiln_cms#2220), so the
  core's suite proves one compiled before the core, against the SDK alone, is
  discovered. It copies files into the directory its `path` setting names,
  and needs a `token` secret only to show that one arrives decrypted.
  """
  use Kiln.BackupDestination

  alias Kiln.BackupDestination.Config

  @impl Kiln.BackupDestination
  def kind, do: "dep_fixture_dir"

  @impl Kiln.BackupDestination
  def label, do: "Dependency fixture directory"

  @impl Kiln.BackupDestination
  def fields do
    [
      %{name: "path", type: :string, required?: true, help: "An absolute directory."},
      %{name: "token", type: :secret, required?: true, help: nil}
    ]
  end

  @impl Kiln.BackupDestination
  def validate(%Config{settings: %{"path" => "/" <> _}}), do: :ok
  def validate(%Config{}), do: {:error, "path must be an absolute directory"}

  @impl Kiln.BackupDestination
  def test(%Config{secrets: %{"token" => token}} = config) when is_binary(token) do
    if File.dir?(root(config)), do: :ok, else: {:error, "#{root(config)} is not a directory"}
  end

  def test(%Config{}), do: {:error, "the token is missing"}

  @impl Kiln.BackupDestination
  def put(config, %{path: path, subdir: subdir, name: name}, _opts) do
    target = Path.join([root(config), subdir, name])
    partial = target <> ".partial"

    with :ok <- File.mkdir_p(Path.dirname(target)),
         {:ok, _bytes} <- File.copy(path, partial) do
      File.rename(partial, target)
    end
  end

  @impl Kiln.BackupDestination
  def list(config) do
    entries =
      for subdir <- ["db", "media"],
          name <- ls(Path.join(root(config), subdir)),
          {:ok, %File.Stat{type: :regular} = stat} <-
            [File.lstat(Path.join([root(config), subdir, name]), time: :posix)] do
        %{subdir: subdir, name: name, bytes: stat.size, mtime: DateTime.from_unix!(stat.mtime)}
      end

    {:ok, entries}
  end

  @impl Kiln.BackupDestination
  def get(config, %{subdir: subdir, name: name}, to) do
    case File.copy(Path.join([root(config), subdir, name]), to) do
      {:ok, _bytes} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Kiln.BackupDestination
  def delete(config, %{subdir: subdir, name: name}) do
    case File.rm(Path.join([root(config), subdir, name])) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Kiln.BackupDestination
  def describe(config), do: root(config)

  @impl Kiln.BackupDestination
  def supports, do: [:list, :delete]

  defp root(%Config{settings: settings}), do: Map.get(settings, "path", "")

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.sort(names)
      {:error, _reason} -> []
    end
  end
end
