defmodule KilnCMSWeb.EnumerationPasskeyTest do
  @moduledoc """
  Passkey sign-in does not say whether a credential, or an account, exists
  (#2255).

  `POST /auth/passkey/options` takes no identifier at all and asks for a
  discoverable credential (`allowCredentials` is empty), so there is nothing in
  it to probe with. `POST /auth/passkey/verify` answers one 401 and one sentence
  whether the credential is unknown, known but failing verification, known with
  a regressed counter, malformed, or arrived without a parked challenge: those
  are compared whole by `KilnCMS.EnumerationAssertions`.

  Not provable here: that an unknown credential skips a signature check a known
  one pays for. The credential id is a random value the authenticator holds, not
  an address a stranger can guess, so that is the passkey's own entropy and not
  an enumeration of accounts.
  """
  use KilnCMSWeb.ConnCase, async: true

  import KilnCMS.EnumerationAssertions
  import KilnCMS.PasskeyFixtures

  defp verify(payload) do
    conn = post(build_conn(), ~p"/auth/passkey/options")
    post(conn, ~p"/auth/passkey/verify", payload)
  end

  defp known_credential(name) do
    {:ok, _} = enroll(passkey_user(:editor), name)
    name
  end

  describe "verify" do
    test "an unknown credential and a known one that fails verification answer alike" do
      known = known_credential("enum-known-#{System.unique_integer([:positive])}")

      seen =
        assert_indistinguishable(
          fn -> verify(assertion(known, signature: "bad")) end,
          fn -> verify(assertion("enum-ghost-#{System.unique_integer([:positive])}")) end,
          []
        )

      assert seen.status == 401
      assert seen.body =~ "Passkey sign-in failed"
    end

    test "a known credential whose counter regressed answers like an unknown one" do
      known = known_credential("enum-count-#{System.unique_integer([:positive])}")

      # First use moves the stored counter to 5; a second at 3 is a regression.
      assert post(
               post(build_conn(), ~p"/auth/passkey/options"),
               ~p"/auth/passkey/verify",
               assertion(known, auth_data: "count:5")
             ).status == 200

      assert_indistinguishable(
        fn -> verify(assertion(known, auth_data: "count:3")) end,
        fn -> verify(assertion("enum-ghost-#{System.unique_integer([:positive])}")) end,
        []
      )
    end

    test "a malformed payload and an absent challenge answer alike too" do
      known = known_credential("enum-shape-#{System.unique_integer([:positive])}")

      assert_indistinguishable(
        fn -> verify(%{"credential_id" => "***not base64***"}) end,
        fn -> verify(assertion("enum-ghost-#{System.unique_integer([:positive])}")) end,
        []
      )

      assert_indistinguishable(
        fn -> post(build_conn(), ~p"/auth/passkey/verify", assertion(known)) end,
        fn ->
          post(build_conn(), ~p"/auth/passkey/verify", assertion("enum-ghost-x"))
        end,
        []
      )
    end
  end

  describe "options" do
    test "ignores whatever identifier is sent and offers no credential list" do
      known = "enum-opt-#{System.unique_integer([:positive])}@example.com"

      shape = fn params ->
        conn = post(build_conn(), ~p"/auth/passkey/options", params)
        %{"publicKey" => options} = json_response(conn, 200)
        options |> Map.delete("challenge") |> Map.put(:status, conn.status)
      end

      assert shape.(%{"email" => known}) == shape.(%{"email" => "nobody-at-all@example.com"})
      assert shape.(%{}) == shape.(%{"email" => known})
      assert %{"allowCredentials" => []} = shape.(%{"email" => known})
    end
  end
end
