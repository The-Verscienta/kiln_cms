defmodule KilnCMS.Backups.Destination.Sftp.Credentials do
  @moduledoc """
  An SFTP destination's credentials (#2222): a `password`, a `private_key`,
  or both, from the destination's encrypted secrets.

  A private key is OpenSSH (`-----BEGIN OPENSSH PRIVATE KEY-----`) or PEM
  (PKCS#1, SEC1 or PKCS#8): Ed25519, Ed448, ECDSA P-256/384/521, or RSA of
  at least 2048 bits (signing with `rsa-sha2-512`/`rsa-sha2-256`). Refused:

    * a key with a passphrase. OTP can't open an OpenSSH key encrypted with
      `bcrypt`, and the key is stored encrypted anyway; the message says how
      to remove it (`ssh-keygen -p -N ""`);
    * a DSA key, and RSA under 2048 bits.

  Parsing never raises with the key in the error: every failure is one of a
  fixed set of sentences, so nothing of the key reaches a log line, a crash
  report or the Test result. Line endings are normalized first, so a key
  pasted from Windows reads.
  """

  @enforce_keys [:username]
  defstruct [:username, :password, :key, :key_algorithms]

  @typedoc """
  What a connection authenticates with. `key` is a zero-arity function
  answering the private key (see `KilnCMS.Backups.Destination.Sftp.HostKey`),
  `key_algorithms` the signature algorithms it signs with.
  """
  @type t :: %__MODULE__{
          username: String.t(),
          password: String.t() | nil,
          key: (-> tuple()) | nil,
          key_algorithms: [atom()]
        }

  # Neither the password nor the key, should one ever be inspected.
  defimpl Inspect do
    def inspect(%{username: username}, _opts),
      do: "#Credentials<#{username}>"
  end

  @encrypted_key "the private key has a passphrase; remove it with " <>
                   "ssh-keygen -p -N \"\" -f <key file> (the key is stored encrypted)"
  @unreadable_key "the private key couldn't be read; paste an OpenSSH or PEM private key"
  @dsa_key "DSA keys are not supported; use an Ed25519, ECDSA or RSA key"
  @short_rsa "the RSA key is shorter than 2048 bits; use a longer key or an Ed25519 key"

  @doc """
  Whether `secrets` hold a usable credential: `:ok`, or `{:error, message}`.
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(secrets) when is_map(secrets) do
    with {:ok, _credentials} <- from_secrets("check", secrets), do: :ok
  end

  @doc "The credentials `secrets` hold for `username`, or `{:error, message}`."
  @spec from_secrets(String.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def from_secrets(username, secrets) when is_map(secrets) do
    password = present(secrets["password"])

    case present(secrets["private_key"]) do
      nil when is_nil(password) ->
        {:error, "enter a password, a private key, or both"}

      nil ->
        {:ok, %__MODULE__{username: username, password: password, key_algorithms: []}}

      pem ->
        with {:ok, key, algorithms} <- private_key(pem) do
          {:ok,
           %__MODULE__{
             username: username,
             password: password,
             key: fn -> key end,
             key_algorithms: algorithms
           }}
        end
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  @doc """
  The private key in `pem` and the algorithms it signs with, or
  `{:error, message}` (one of a fixed set: never the key's own text).
  """
  @spec private_key(String.t()) :: {:ok, tuple(), [atom()]} | {:error, String.t()}
  def private_key(pem) when is_binary(pem) do
    pem = pem |> String.replace("\r\n", "\n") |> String.replace("\r", "\n") |> String.trim()

    with {:ok, key} <- decode(pem) do
      algorithms(key)
    end
  rescue
    _error -> {:error, @unreadable_key}
  catch
    _kind, _value -> {:error, @unreadable_key}
  end

  defp decode(pem) do
    cond do
      String.contains?(pem, "-----BEGIN OPENSSH PRIVATE KEY-----") -> openssh(pem)
      String.contains?(pem, ["ENCRYPTED", "Proc-Type: 4,"]) -> {:error, @encrypted_key}
      String.contains?(pem, "-----BEGIN") -> pem_entry(pem)
      true -> {:error, @unreadable_key}
    end
  end

  # The cipher is read first: OTP raises on a bcrypt-encrypted key.
  defp openssh(pem) do
    with {:ok, binary} <- openssh_body(pem),
         {:ok, "none"} <- openssh_cipher(binary),
         [_ | _] = keys <- :ssh_file.decode(pem, :openssh_key_v1),
         key when not is_nil(key) <- Enum.find_value(keys, &private_of/1) do
      {:ok, key}
    else
      {:ok, _cipher} -> {:error, @encrypted_key}
      _other -> {:error, @unreadable_key}
    end
  end

  defp openssh_body(pem) do
    pem
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "-----"))
    |> Enum.join()
    |> String.replace(~r/\s/, "")
    |> Base.decode64()
  end

  defp openssh_cipher(
         <<"openssh-key-v1", 0, length::32, cipher::binary-size(length), _::binary>>
       ),
       do: {:ok, cipher}

  defp openssh_cipher(_binary), do: :error

  defp private_of({key, _attributes})
       when elem(key, 0) in [:RSAPrivateKey, :ECPrivateKey, :DSAPrivateKey],
       do: key

  defp private_of(_entry), do: nil

  defp pem_entry(pem) do
    case Enum.find(:public_key.pem_decode(pem), &private_entry?/1) do
      {_type, _der, :not_encrypted} = entry -> {:ok, :public_key.pem_entry_decode(entry)}
      {_type, _der, _encrypted} -> {:error, @encrypted_key}
      nil -> {:error, @unreadable_key}
    end
  end

  defp private_entry?({type, _der, _cipher}),
    do: type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo, :DSAPrivateKey]

  defp algorithms(key) when elem(key, 0) == :DSAPrivateKey, do: {:error, @dsa_key}

  defp algorithms(key) when elem(key, 0) == :RSAPrivateKey do
    # `#RSAPrivateKey{version, modulus, …}`.
    modulus = elem(key, 2)

    if is_integer(modulus) and bit_size(:binary.encode_unsigned(modulus)) >= 2048,
      do: {:ok, key, [:"rsa-sha2-512", :"rsa-sha2-256"]},
      else: {:error, @short_rsa}
  end

  defp algorithms(key) when elem(key, 0) == :ECPrivateKey do
    # `#ECPrivateKey{version, privateKey, parameters, …}`.
    case elem(key, 3) do
      {:namedCurve, oid} ->
        case curve(oid) do
          nil -> {:error, @unreadable_key}
          algorithm -> {:ok, key, [algorithm]}
        end

      _other ->
        {:error, @unreadable_key}
    end
  end

  defp algorithms(_key), do: {:error, @unreadable_key}

  @curves %{
    {1, 3, 101, 112} => :"ssh-ed25519",
    {1, 3, 101, 113} => :"ssh-ed448",
    {1, 2, 840, 10_045, 3, 1, 7} => :"ecdsa-sha2-nistp256",
    {1, 3, 132, 0, 34} => :"ecdsa-sha2-nistp384",
    {1, 3, 132, 0, 35} => :"ecdsa-sha2-nistp521"
  }

  defp curve(oid), do: Map.get(@curves, oid)
end
