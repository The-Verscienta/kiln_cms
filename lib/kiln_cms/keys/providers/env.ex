defmodule KilnCMS.Keys.Providers.Env do
  @moduledoc """
  Key provider reading PEM material from an environment variable
  (config: `%{"var" => "DKIM_PRIVATE_KEY"}`).
  """
  @behaviour KilnCMS.Keys.Provider

  @default_var "DKIM_PRIVATE_KEY"

  @impl true
  def fetch(config) do
    var = var(config)

    case System.get_env(var) do
      value when value in [nil, ""] -> {:error, {:env_var_unset, var}}
      pem -> {:ok, pem}
    end
  end

  @impl true
  def writable?, do: false

  defp var(config), do: config["var"] || @default_var
end
