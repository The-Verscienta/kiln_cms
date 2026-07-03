defmodule KilnCMS.Keys.Providers.File do
  @moduledoc """
  Key provider reading PEM material from a file on disk
  (config: `%{"path" => "/run/secrets/dkim.pem"}`) — the natural fit for
  Docker/Kubernetes mounted secrets. Prefer a path outside any bind-mounted
  content directory.
  """
  @behaviour KilnCMS.Keys.Provider

  # Reading an operator-chosen path is this provider's purpose; the path is
  # admin-only configuration (KilnCMS.Mail.Settings policies), never
  # request-derived input.
  # sobelow_skip ["Traversal.FileModule"]
  @impl true
  def fetch(config) do
    case config["path"] do
      path when path in [nil, ""] ->
        {:error, :no_path_configured}

      path ->
        case File.read(path) do
          {:ok, pem} -> {:ok, pem}
          {:error, posix} -> {:error, {:unreadable, path, posix}}
        end
    end
  end

  @impl true
  def check(config) do
    with {:ok, pem} <- fetch(config) do
      KilnCMS.Keys.validate_private_key_pem(pem)
    end
  end

  @impl true
  def writable?, do: false
end
