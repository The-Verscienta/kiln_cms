defmodule KilnCMS.Accounts.TokenExpungeTest do
  @moduledoc """
  The nightly AshOban `:expunge_expired` trigger deletes auth tokens whose
  `expires_at` has passed, and leaves still-valid tokens alone (#224).
  """
  use KilnCMS.DataCase, async: true

  alias KilnCMS.Accounts.Token

  defp token(expires_at) do
    Ash.Seed.seed!(Token, %{
      jti: "jti-#{System.unique_integer([:positive])}",
      subject: "user?id=#{Ash.UUID.generate()}",
      purpose: "user",
      expires_at: expires_at
    })
  end

  defp stored_jtis do
    Token |> Ash.read!(authorize?: false) |> Enum.map(& &1.jti)
  end

  test "the trigger expunges expired tokens but keeps valid ones" do
    expired = token(DateTime.add(DateTime.utc_now(), -1, :day))
    valid = token(DateTime.add(DateTime.utc_now(), 1, :day))

    AshOban.schedule_and_run_triggers(Token,
      drain_queues?: true,
      with_recursion: true,
      with_scheduled: true
    )

    jtis = stored_jtis()
    refute expired.jti in jtis
    assert valid.jti in jtis
  end
end
