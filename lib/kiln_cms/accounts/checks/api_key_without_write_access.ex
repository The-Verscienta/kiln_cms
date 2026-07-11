defmodule KilnCMS.Accounts.Checks.ApiKeyWithoutWriteAccess do
  @moduledoc """
  Matches an actor authenticated with an API key whose `access` scope does not
  include writes — i.e. a `:read` key (or a key record we can't inspect, which
  fails closed to read-only).

  The API-key sign-in preparation stamps the matched `ApiKey` record into
  `actor.__metadata__.api_key` alongside `using_api_key?`, so the key's scope is
  available to policies without an extra query. Content resources `forbid_if`
  this check on create/update, which keeps `:read` keys exactly as powerless as
  the old blanket `UsingApiKey` forbid while letting `:read_write` keys fall
  through to the role policies (an LLM key on an editor account can author
  drafts; publishing still needs an admin — see `KilnCMS.Accounts.ApiKey`).

  JWT- or session-authenticated actors never match: their write access is
  governed by the role policies alone.
  """
  use Ash.Policy.SimpleCheck

  @impl Ash.Policy.Check
  def describe(_opts), do: "using an API key without write access"

  @impl Ash.Policy.SimpleCheck
  def match?(%{__metadata__: %{using_api_key?: true} = metadata}, _context, _opts) do
    case metadata[:api_key] do
      %KilnCMS.Accounts.ApiKey{access: :read_write} -> false
      _ -> true
    end
  end

  def match?(_actor, _context, _opts), do: false
end
