defmodule KilnCMS.Config.MediaRoot do
  @moduledoc """
  `KILN_MEDIA_ROOT` — a stable directory for the Local storage adapter (#1529).

  Left unset, `KilnCMS.Storage.Local` writes under the release's own
  `priv/uploads`, which in a release is `/app/lib/kiln_cms-<version>/priv/…`:
  a path that moves with every version, so no volume can be mounted there, and
  that a PaaS wipes on every restart. Setting `KILN_MEDIA_ROOT` to a mounted
  volume (`/app/media` in the one-click templates) keeps media across restarts
  and upgrades. One directory holds both halves:

      <KILN_MEDIA_ROOT>/public    served at /uploads (Plug.Static)
      <KILN_MEDIA_ROOT>/private   never served — see KilnCMS.Storage.Local

  so a single volume, and a single backup archive of it, covers everything.

  Two runtime fragments read it, which is why it is a module rather than an
  inline read: `runtime/prod/storage.exs` points the adapter at it, and
  `runtime/prod/backups.exs` defaults `MEDIA_DIR` (what the in-app backup
  archives) to it. The same argument `KilnCMS.Config.Host` makes: two
  hand-written copies of one rule do not stay identical.

  It is ignored on an S3 deployment (`S3_BUCKET` set): media is not on disk
  there, and backups must not archive a directory that holds nothing.
  """

  @var "KILN_MEDIA_ROOT"

  @doc "The environment variable this module reads."
  @spec var() :: String.t()
  def var, do: @var

  @doc """
  Reads `KILN_MEDIA_ROOT`.

  `{:ok, dir}` for an absolute path; `:unset` when it is unset, blank, or S3
  is the storage adapter; `{:error, raw}` for a relative path, which would
  resolve against whatever the release's working directory happens to be.
  """
  @spec fetch() :: {:ok, Path.t()} | :unset | {:error, String.t()}
  def fetch do
    raw = System.get_env(@var, "")
    dir = String.trim(raw)

    cond do
      dir == "" -> :unset
      # Presence, not content — the rule runtime/prod/storage.exs uses to pick
      # the S3 adapter, so the two cannot disagree about which one is live.
      System.get_env("S3_BUCKET") != nil -> :unset
      Path.type(dir) != :absolute -> {:error, raw}
      true -> {:ok, String.trim_trailing(dir, "/")}
    end
  end

  @doc "Where public blobs live under `root`."
  @spec public_dir(Path.t()) :: Path.t()
  def public_dir(root), do: Path.join(root, "public")

  @doc "Where private blobs live under `root`."
  @spec private_dir(Path.t()) :: Path.t()
  def private_dir(root), do: Path.join(root, "private")
end
