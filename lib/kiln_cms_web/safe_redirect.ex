defmodule KilnCMSWeb.SafeRedirect do
  @moduledoc """
  Open-redirect guard for user-influenced redirect targets.

  Only **same-origin, absolute local paths** are allowed. Off-site targets —
  protocol-relative `//evil.com`, absolute `https://evil.com`, and backslash
  tricks like `/\\evil.com` that browsers treat as protocol-relative — fall back
  to a safe default. A bare `"/" <> _` check is insufficient because it admits
  `//evil.com`.
  """

  @doc """
  Return `path` when it is a safe same-origin local path, else `fallback`.
  """
  @spec local_path(term(), String.t()) :: String.t()
  def local_path(path, fallback \\ "/")

  def local_path(path, fallback) when is_binary(path) do
    if safe_local_path?(path), do: path, else: fallback
  end

  def local_path(_path, fallback), do: fallback

  @doc """
  True when `path` is an absolute, same-origin local path: it starts with a
  single `/`, carries no scheme or host, and uses no `//`/`/\\` escape that a
  browser would resolve off-origin.
  """
  @spec safe_local_path?(term()) :: boolean()
  def safe_local_path?("/" <> _ = path) do
    not String.starts_with?(path, "//") and
      not String.starts_with?(path, "/\\") and
      case URI.parse(path) do
        %URI{scheme: nil, host: nil} -> true
        _ -> false
      end
  end

  def safe_local_path?(_), do: false
end
