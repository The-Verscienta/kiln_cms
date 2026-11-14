defmodule KilnCMSWeb.SocketLogRedactionTest do
  @moduledoc """
  Phoenix logs a socket's connect params at `:info`, the production level.
  The credentials Kiln's sockets take there must come out `[FILTERED]`.
  """
  # async: false — the log level is raised for `Phoenix.Logger`, which is
  # global, and the connects charge the shared join budget.
  use KilnCMS.DataCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.ChannelTest

  alias KilnCMSWeb.CollabSocket
  alias KilnCMSWeb.GraphqlSocket

  @endpoint KilnCMSWeb.Endpoint

  setup do
    previous = Logger.get_module_level(Phoenix.Logger)
    Logger.put_module_level(Phoenix.Logger, :info)

    on_exit(fn ->
      case previous do
        [{Phoenix.Logger, level}] -> Logger.put_module_level(Phoenix.Logger, level)
        _none -> Logger.delete_module_level(Phoenix.Logger)
      end
    end)

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    :ok
  end

  defp secret, do: "S#{System.unique_integer([:positive])}ecretToken"

  test "the collab socket's token is filtered from its connect line" do
    token = secret()

    log =
      capture_log([level: :info], fn ->
        connect(CollabSocket, %{"token" => token})
      end)

    assert log =~ "KilnCMSWeb.CollabSocket", "the connect line was not logged:\n#{log}"
    assert log =~ ~s("token" => "[FILTERED]")
    refute log =~ token
  end

  test "the GraphQL socket's token and Authorization are filtered from its connect line" do
    token = secret()

    log =
      capture_log([level: :info], fn ->
        connect(GraphqlSocket, %{
          "token" => token,
          "Authorization" => "Bearer #{token}",
          "authorization" => "Bearer #{token}",
          "api_key" => token
        })
      end)

    assert log =~ "KilnCMSWeb.GraphqlSocket", "the connect line was not logged:\n#{log}"
    refute log =~ token
  end
end
