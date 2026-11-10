defmodule KilnCMSWeb.ApiKeyRotationController do
  @moduledoc """
  `POST /api/keys/rotate` — a `:draft_write` API key exchanges itself for a
  fresh one (ADR 0012, "Rotation").

  The request is `Authorization: Bearer kiln_…` and an empty body. The answer
  is `201` with the new plaintext key, shown once:

      {"data": {"id": "…", "api_key": "kiln_…", "expires_at": "…",
                "rotatable_until": "…", "rotated_from_id": "…"}}

  The presenting key is revoked in the same transaction. Store the new key
  before you stop using the old one, and rotate from one place: the old key
  stops working the moment this answers.

  This route authenticates the key itself rather than through
  `KilnCMSWeb.Plugs.ApiKeyAuth`, because a key that fails here is the one case
  worth looking at twice: a rotated-away key presented again is evidence that
  two parties held it (`KilnCMS.Accounts.ApiKeyReuse`). It is authenticated-only
  whatever `KILN_API_REJECT_INVALID_BEARER` says (#2161): no header, a non-`kiln_`
  bearer, or a bad key is a `401`.

  | Status | `code` | When |
  |---|---|---|
  | 201 | | rotated |
  | 401 | `invalid_api_key` | no `Bearer kiln_…`, or it does not verify (revoked, expired, unknown) |
  | 403 | `forbidden` | the key is not a `:draft_write` key with an open rotation window |
  | 409 | `not_rotatable` | the key was revoked or rotated by a concurrent request, or its owner may now edit or publish |
  | 500 | `internal_server_error` | a database or server failure; the key is unchanged, retry later |

  Answers are `Cache-Control: no-store`: the body is a credential.
  """
  use KilnCMSWeb, :controller

  alias KilnCMS.Accounts
  alias KilnCMS.Accounts.ApiKeyReuse
  alias KilnCMSWeb.ApiError

  require Logger

  @bearer "Bearer " <> KilnCMS.Accounts.ApiKey.prefix() <> "_"

  def rotate(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case presented_key(conn) do
      {:ok, plaintext} -> authenticate_and_rotate(conn, plaintext)
      :error -> unauthorized(conn)
    end
  end

  defp authenticate_and_rotate(conn, plaintext) do
    case Accounts.actor_from_api_key(plaintext) do
      {:ok, actor} ->
        rotate_as(conn, actor)

      :error ->
        ApiKeyReuse.check(plaintext, KilnCMS.Security.Recorder.context(conn))
        unauthorized(conn)
    end
  end

  defp presented_key(conn) do
    case get_req_header(conn, "authorization") do
      [@bearer <> _ = "Bearer " <> plaintext | _] -> {:ok, plaintext}
      _ -> :error
    end
  end

  defp rotate_as(conn, actor) do
    case Accounts.rotate_api_key(
           actor: actor,
           context: KilnCMS.Security.AuthEvents.context(conn)
         ) do
      {:ok, key} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            id: key.id,
            api_key: Ash.Resource.get_metadata(key, :plaintext_api_key),
            expires_at: key.expires_at,
            rotatable_until: key.rotatable_until,
            rotated_from_id: key.rotated_from_id
          }
        })

      {:error, %Ash.Error.Forbidden{}} ->
        ApiError.send(
          conn,
          :forbidden,
          "forbidden",
          "Only a drafts-only key with an open rotation window can rotate itself."
        )

      {:error, %Ash.Error.Invalid{}} ->
        ApiError.send(
          conn,
          :conflict,
          "not_rotatable",
          "This key can no longer rotate. Ask an administrator for a new key."
        )

      # A database or framework failure is not a verdict on the key: answer 500
      # so the service retries later rather than giving up on a key that still works.
      {:error, error} ->
        Logger.error("API key rotation failed: #{Exception.message(error)}")

        ApiError.send(
          conn,
          :internal_server_error,
          "internal_server_error",
          "The key could not be rotated. Try again later."
        )
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", ~s(Bearer error="invalid_token"))
    |> ApiError.send(:unauthorized, "invalid_api_key", "A valid API key is required.")
  end
end
