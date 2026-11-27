defmodule KilnCMSWeb.BackupDownloadToken do
  @moduledoc """
  The one-minute token a backup download carries from the History page's
  click to the download request (part of #2225).

  Signed with the endpoint's secret under its own salt, and good for 60
  seconds: long enough for the browser to post it, too short to forward. It
  names the run, the file, the user and the browser session (`"j"`, the jti
  `KilnCMSWeb.SessionTracking` assigns, as the collab token does since
  #2490), and the backup-directory id the click saw (`"d"`, nil when that
  node had none), so `KilnCMSWeb.BackupDownloadController` refuses it for
  another user, another session, or a request that reached another server.

  Signed, not encrypted: it holds ids and a file name the page already
  shows. It is minted on click, never at render, and travels in a POST body
  (`token`), which `:filter_parameters` keeps out of the logs; never in a
  URL. Verifying it proves only that this application minted it: the
  controller still asks `KilnCMS.Backups.download/4`, which re-checks the
  name against the run.
  """

  @salt "backup download"
  @max_age 60
  @version 1

  @type claims :: %{
          run_id: String.t(),
          file: String.t(),
          user_id: String.t(),
          session_jti: String.t(),
          dir_id: String.t() | nil
        }

  @doc "How long a token is good for, in seconds."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc """
  A token for `user` to download `file` of the run `run_id`, from the session
  `session_jti`, minted on a node whose backup-directory id is `dir_id`.
  Options: `:signed_at` (seconds, for the tests).
  """
  @spec sign(%{id: String.t()}, String.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          String.t()
  def sign(%{id: user_id}, session_jti, run_id, file, dir_id, opts \\ [])
      when is_binary(session_jti) and is_binary(run_id) and is_binary(file) do
    Phoenix.Token.sign(
      KilnCMSWeb.Endpoint,
      @salt,
      %{
        "v" => @version,
        "r" => run_id,
        "f" => file,
        "u" => user_id,
        "j" => session_jti,
        "d" => dir_id
      },
      Keyword.take(opts, [:signed_at])
    )
  end

  @doc """
  The claims of `token`, or `{:error, :expired}` once it is older than
  `max_age/0`, or `{:error, :invalid}` for anything this application did not
  mint under this salt (a forged, tampered or truncated token, or not a
  string).
  """
  @spec verify(term()) :: {:ok, claims()} | {:error, :expired | :invalid}
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(KilnCMSWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, claims} -> claims(claims)
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_or_missing} -> {:error, :invalid}
    end
  end

  def verify(_token), do: {:error, :invalid}

  defp claims(%{
         "v" => @version,
         "r" => run_id,
         "f" => file,
         "u" => user_id,
         "j" => jti,
         "d" => dir_id
       })
       when is_binary(run_id) and is_binary(file) and is_binary(user_id) and is_binary(jti) and
              (is_binary(dir_id) or is_nil(dir_id)) do
    {:ok, %{run_id: run_id, file: file, user_id: user_id, session_jti: jti, dir_id: dir_id}}
  end

  defp claims(_other), do: {:error, :invalid}
end
