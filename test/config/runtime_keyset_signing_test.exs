defmodule KilnCMS.Config.RuntimeKeysetSigningTest do
  @moduledoc """
  Pins the keyset signing secret `config/runtime.exs` writes in prod (#3272,
  EEF-CVE-2026-124283): derived from `SECRET_KEY_BASE`, so every node that
  shares it accepts the others' cursors, and never `SECRET_KEY_BASE` itself.
  Without a secret, Ash 3.38 cannot build a cursor for a custom-field sort.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  @prod_env %{
    "DATABASE_URL" => "ecto://u:p@localhost/db",
    "SECRET_KEY_BASE" => String.duplicate("k", 64),
    "TOKEN_SIGNING_SECRET" => String.duplicate("t", 64)
  }

  setup do
    original = Map.new(@prod_env, fn {k, _} -> {k, System.get_env(k)} end)

    on_exit(fn ->
      Enum.each(original, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    Enum.each(@prod_env, fn {k, v} -> System.put_env(k, v) end)
    :ok
  end

  test "prod signs keysets with a key derived from SECRET_KEY_BASE" do
    parent = self()

    capture_io(:stderr, fn ->
      secret =
        @runtime
        |> Config.Reader.read!(env: :prod)
        |> get_in([:ash, :keyset_signing_secret])

      send(parent, {:secret, secret})
    end)

    assert_received {:secret, secret}

    skb = @prod_env["SECRET_KEY_BASE"]
    assert secret == :crypto.mac(:hmac, :sha256, skb, "ash keyset signing")
    refute secret == skb
  end
end
