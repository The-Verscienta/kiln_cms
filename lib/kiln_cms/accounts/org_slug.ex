defmodule KilnCMS.Accounts.OrgSlug do
  @moduledoc """
  What an `Organization.slug` may be (#1710): a DNS label, because it is one.

  The slug is the org's subdomain (`<slug>.<base host>`) and, with
  `KILN_CONSOLE_HOST` set, names its console host too. Tenant resolution
  downcases the request host before it looks the slug up, and the lookup is an
  exact match — so a slug like `Acme`, `my_site` or `a.b` could be stored but
  never reached. A slug is therefore:

    * lowercase `a-z`, `0-9` and `-`, 1 to 63 characters;
    * not starting or ending with `-`;
    * not one of the labels the system keeps for its own hosts (`reserved/0`).

  `normalize/1` trims and downcases, and the create and update actions run it
  before they validate, so `Acme` is stored as `acme` rather than refused.
  Rows written before this rule are left alone: renaming a live tenant's host
  is the operator's call, not a migration's — see `KilnCMS.Accounts.OrgSlugAudit`.
  """

  @label ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  # Hosts the system already answers on, or that a deployment conventionally
  # points somewhere other than a tenant. `console` and the console host's own
  # first label are the ones Kiln itself resolves specially (#740, #1688).
  @reserved ~w(www console api mail)

  @doc "Trim and downcase a slug; anything that is not a string passes through."
  @spec normalize(term()) :: term()
  def normalize(slug) when is_binary(slug), do: slug |> String.trim() |> String.downcase()
  def normalize(other), do: other

  @doc "Whether `slug` is a valid DNS label, exactly as given (no normalizing)."
  @spec label?(term()) :: boolean()
  def label?(slug) when is_binary(slug), do: Regex.match?(@label, slug)
  def label?(_other), do: false

  @doc """
  The labels no organization may take: a fixed few, plus the first label of
  `KILN_CONSOLE_HOST` when that host sits directly under the tenant base host
  (`console.example.com` → `console`) — an org with that slug would name the
  console host itself.
  """
  @spec reserved() :: [String.t()]
  def reserved do
    case console_label() do
      nil -> @reserved
      label -> Enum.uniq(@reserved ++ [label])
    end
  end

  defp console_label do
    with console when is_binary(console) <- KilnCMSWeb.Plugs.ConsoleHost.console_host(),
         suffix = "." <> KilnCMSWeb.Tenant.base_host(),
         true <- String.ends_with?(console, suffix),
         label = String.replace_suffix(console, suffix, ""),
         true <- label != "" and not String.contains?(label, ".") do
      label
    else
      _ -> nil
    end
  end

  @doc """
  Check a slug as it would be stored: `:ok`, `{:error, :format}` when it is
  not a DNS label, or `{:error, :reserved}`.
  """
  @spec check(String.t()) :: :ok | {:error, :format | :reserved}
  def check(slug) when is_binary(slug) do
    cond do
      not label?(slug) -> {:error, :format}
      slug in reserved() -> {:error, :reserved}
      true -> :ok
    end
  end

  @doc "The error message for a `check/1` failure — an `errors`-domain msgid."
  @spec message(:format | :reserved) :: String.t()
  def message(:format),
    do:
      "must be 1 to 63 lowercase letters, digits or hyphens, " <>
        "and cannot start or end with a hyphen"

  def message(:reserved), do: "is reserved"
end
