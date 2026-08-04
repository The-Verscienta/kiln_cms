defmodule KilnCMS.Accounts.Preparations.ThrottleMagicLink do
  @moduledoc """
  Bounds `:request_magic_link` per client address (#724).

  Softer than registration — `KilnCMS.Accounts.AccountThrottle.allow_mail?/2`
  already caps outbound mail at five per address per hour, so the mailbomb is
  bounded whatever happens here. What was uncapped is the **request rate**: each
  one is a database read and, for an address that exists, a token mint, from a
  `/live` event that passes no pipeline.

  Shares the `:auth` bucket rather than taking one of its own, because this form
  sits on the sign-in page and is the same flow to the same person — and because
  `docs/threat-model.md` has always listed `/reset` and `/register` under
  `:auth`, which after #715 was true only of their GETs. This makes the row
  honest again for the magic-link and reset submits.
  """
  use Ash.Resource.Preparation

  alias Ash.Query
  alias KilnCMS.Accounts.ClientIpBudget

  @impl true
  def prepare(query, _opts, _context) do
    Query.before_action(query, fn query ->
      case ClientIpBudget.check(query.context, :auth) do
        :allow ->
          query

        {:deny, _retry_after} ->
          Query.add_error(query, ClientIpBudget.refusal(__MODULE__, :request_magic_link))
      end
    end)
  end
end
