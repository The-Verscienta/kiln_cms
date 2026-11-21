defmodule KilnCMS.Backups.Destination.Sftp.HostKey do
  @moduledoc """
  The SFTP server's host key (#2222, ADR 0079): how it is checked on every
  connection, and how it is read once so a platform admin can trust it.

  This module is the `:ssh` client's `key_cb` (`:ssh_client_key_api`).
  OTP calls `is_host_key/5` after the server has signed the key exchange
  with the key it offers, and **before user authentication**: a key that is
  refused here ends the connection with no password and no signature sent.

    * `{:verify, type, fingerprint}` — the key must be of the trusted type
      and have the trusted SHA-256 fingerprint, compared in constant time.
      Anything else answers `{:error, :host_key_mismatch}`;
    * `:scan` — the offered key is reported to the caller and refused
      (`{:error, :scanned}`), so a scan sends no credential at all.

  Never `false`: OTP answers `false` with an interactive yes/no prompt on the
  group leader (`ssh_transport:known_host_key/3`), which a server must never
  reach. Every connection also passes `user_interaction: false`,
  `silently_accept_hosts: false` and `save_accepted_host: false`
  (`KilnCMS.Backups.Destination.Sftp.Session`).

  Either way, the offered key's type and fingerprint are sent to the
  connecting process as `{tag, :offered, type, fingerprint}`, so a mismatch
  can say what was offered.

  The client's own private key is handed to `user_key/2` through a
  zero-arity function in the key_cb options, never as a term: OTP keeps the
  options in its connection state and prints them in crash reports, and a
  function prints as `#Function<…>`.
  """

  @behaviour :ssh_client_key_api

  @types ~w(ssh-ed25519 ssh-ed448 ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521 ssh-rsa)

  @fingerprint ~r/\ASHA256:[A-Za-z0-9+\/]{43}\z/

  @doc """
  The host key types Kiln trusts, most preferred first. `ssh-rsa` is the RSA
  key *type*; it is only ever used with the SHA-2 signatures
  (`rsa-sha2-512`, `rsa-sha2-256`), never SHA-1.
  """
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "Whether `fingerprint` is an OpenSSH SHA-256 fingerprint, `SHA256:<base64>`."
  @spec fingerprint?(term()) :: boolean()
  def fingerprint?(fingerprint) when is_binary(fingerprint),
    do: Regex.match?(@fingerprint, fingerprint)

  def fingerprint?(_fingerprint), do: false

  @doc """
  A pasted fingerprint as stored: `SHA256:` (any case) and the base64 with
  its padding dropped, as `ssh-keygen -lf` prints it. `:error` when it is
  not one.
  """
  @spec normalize_fingerprint(term()) :: {:ok, String.t()} | :error
  def normalize_fingerprint(text) when is_binary(text) do
    text = text |> String.trim() |> String.trim_trailing("=")

    candidate =
      case String.split(text, ":", parts: 2) do
        [prefix, b64] -> if String.downcase(prefix) == "sha256", do: "SHA256:" <> b64
        [b64] -> "SHA256:" <> b64
      end

    if fingerprint?(candidate), do: {:ok, candidate}, else: :error
  end

  def normalize_fingerprint(_text), do: :error

  @doc "The SHA-256 fingerprint of a public key, as `ssh-keygen -lf` prints it."
  @spec fingerprint(:public_key.public_key()) :: String.t()
  def fingerprint(public_key),
    do: :sha256 |> :ssh.hostkey_fingerprint(public_key) |> to_string()

  @doc ~s[The type of a public key (`"ssh-ed25519"`, `"ssh-rsa"`, …).]
  @spec type(:public_key.public_key()) :: String.t()
  def type(public_key), do: public_key |> :ssh_transport.public_algo() |> Atom.to_string()

  @doc """
  The host key algorithms to offer for a trusted `type`: the type itself, or
  for RSA its SHA-2 signature algorithms.
  """
  @spec algorithms(String.t()) :: [atom()]
  def algorithms("ssh-rsa"), do: [:"rsa-sha2-512", :"rsa-sha2-256"]
  def algorithms(type) when type in @types, do: [String.to_existing_atom(type)]

  @doc "Whether two fingerprints are the same, in time independent of where they differ."
  @spec same?(String.t(), String.t()) :: boolean()
  def same?(a, b) when is_binary(a) and is_binary(b),
    do: byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)

  ## :ssh_client_key_api

  @impl :ssh_client_key_api
  def is_host_key(key, _host, _port, _algorithm, options) do
    private = Keyword.get(options, :key_cb_private, [])

    try do
      type = type(key)
      offered = fingerprint(key)
      send(private[:reply_to], {private[:tag], :offered, type, offered})
      decide(private[:mode], type, offered)
    rescue
      # A key of a shape this release can't read is refused, never trusted.
      _error -> {:error, :host_key_mismatch}
    end
  end

  defp decide({:verify, trusted_type, trusted}, type, offered) do
    if type == trusted_type and same?(offered, trusted),
      do: true,
      else: {:error, :host_key_mismatch}
  end

  defp decide(_scan_or_unknown, _type, _offered), do: {:error, :scanned}

  @impl :ssh_client_key_api
  def add_host_key(_host, _port, _key, _options), do: :ok

  @impl :ssh_client_key_api
  def user_key(algorithm, options) do
    private = Keyword.get(options, :key_cb_private, [])

    with fun when is_function(fun, 0) <- private[:user_key],
         key when is_tuple(key) <- fun.(),
         true <- :ssh_transport.valid_key_sha_alg(:private, key, algorithm) do
      {:ok, key}
    else
      _ -> {:error, :no_key}
    end
  end
end
