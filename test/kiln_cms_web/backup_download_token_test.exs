defmodule KilnCMSWeb.BackupDownloadTokenTest do
  @moduledoc """
  The one-minute token a backup download carries (part of #2225): it says
  what it was minted for, expires, and is refused when it isn't this
  application's under this salt.
  """
  use ExUnit.Case, async: true

  alias KilnCMSWeb.BackupDownloadToken

  @user %{id: "4d6a1b5e-9f7c-4c4e-8a51-1b2c3d4e5f60"}
  @run "0b9f9a1e-2c3d-4e5f-8a9b-0c1d2e3f4a5b"
  @file_name "kiln-db-20261118-031700.dump"
  @dir "7e1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b"

  test "round-trips what it was minted for" do
    token = BackupDownloadToken.sign(@user, "jti-1", @run, @file_name, @dir)

    assert BackupDownloadToken.verify(token) ==
             {:ok,
              %{
                run_id: @run,
                file: @file_name,
                user_id: @user.id,
                session_jti: "jti-1",
                dir_id: @dir
              }}

    token = BackupDownloadToken.sign(@user, "jti-1", @run, @file_name, nil)
    assert {:ok, %{dir_id: nil}} = BackupDownloadToken.verify(token)
  end

  test "is good for 60 seconds" do
    assert BackupDownloadToken.max_age() == 60
    now = System.system_time(:second)

    fresh = BackupDownloadToken.sign(@user, "j", @run, @file_name, nil, signed_at: now - 50)
    assert {:ok, _} = BackupDownloadToken.verify(fresh)

    stale = BackupDownloadToken.sign(@user, "j", @run, @file_name, nil, signed_at: now - 61)
    assert BackupDownloadToken.verify(stale) == {:error, :expired}
  end

  test "another salt's token, a tampered one and rubbish are :invalid" do
    other_salt = Phoenix.Token.sign(KilnCMSWeb.Endpoint, "collab", %{"v" => 1, "r" => @run})
    assert BackupDownloadToken.verify(other_salt) == {:error, :invalid}

    token = BackupDownloadToken.sign(@user, "j", @run, @file_name, nil)
    [protected, payload, signature] = String.split(token, ".")

    # Another file in the payload, under the old signature.
    forged_payload =
      payload
      |> Base.url_decode64!(padding: false)
      |> String.replace(@file_name, "kiln-db-20261117-031700.dump")
      |> Base.url_encode64(padding: false)

    for tampered <- [
          Enum.join([protected, forged_payload, signature], "."),
          Enum.join([protected, payload, String.reverse(signature)], ".")
        ] do
      assert BackupDownloadToken.verify(tampered) == {:error, :invalid}
    end

    for rubbish <- ["", "abc", "abc%2F..%2Fetc", nil, 1, %{}] do
      assert BackupDownloadToken.verify(rubbish) == {:error, :invalid}
    end
  end

  test "a token of the right salt with another shape is :invalid" do
    wrong =
      Phoenix.Token.sign(KilnCMSWeb.Endpoint, "backup download", %{
        "v" => 2,
        "r" => @run,
        "f" => @file_name,
        "u" => @user.id,
        "j" => "j",
        "d" => nil
      })

    assert BackupDownloadToken.verify(wrong) == {:error, :invalid}

    no_session =
      Phoenix.Token.sign(KilnCMSWeb.Endpoint, "backup download", %{
        "v" => 1,
        "r" => @run,
        "f" => @file_name,
        "u" => @user.id,
        "j" => nil,
        "d" => nil
      })

    assert BackupDownloadToken.verify(no_session) == {:error, :invalid}
  end
end
