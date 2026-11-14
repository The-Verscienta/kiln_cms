defmodule KilnCMS.Accounts.Registrations do
  @moduledoc """
  Registration approval (#2251): the queue a site admin works through, and the
  two decisions.

  A self-registration on a site with `KilnCMS.CMS.SiteRegistration`
  `approval_required` on creates the account and a `:pending`
  `KilnCMS.Accounts.OrgMembership` on that site
  (`KilnCMS.Accounts.Changes.QueueRegistration`). `KilnCMS.Accounts.Scoping`
  grants nothing through a row that is not `:active`, so until it is approved
  the account can sign in and read only what anyone can. Approving makes the row
  an ordinary `:viewer` membership; rejecting keeps the account and marks the
  row `:rejected`, unless the site erases unconfirmed rejected accounts and
  this one qualifies (`Registrations.Erasure`, #2514).

  ## Who sees whom

  The queue is an admin of the org the rows belong to — the
  `:registration_queue` read's policy (`Checks.AdminOfMembershipOrg`) — and a
  standing platform admin. Each row carries the applicant's email address,
  name, whether they have confirmed the address and whether the account was
  since erased, and nothing else about the account: `queue/2` reads those
  columns for the queue's own users only.
  This is the one place a site admin sees an account they do not administer —
  and only someone who asked to join their site.
  """

  require Ash.Expr

  alias KilnCMS.Accounts

  @typedoc "One row of the queue: the membership, and what an admin needs to decide it."
  @type entry :: %{
          membership: Accounts.OrgMembership.t(),
          email: String.t() | nil,
          name: String.t() | nil,
          confirmed?: boolean(),
          erased?: boolean(),
          registered_at: DateTime.t()
        }

  @page_size 50
  @count_cap 100

  @doc "How many rows one page of the queue holds."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc "The most `pending_count/2` counts; at the cap, \"this many or more\"."
  @spec count_cap() :: pos_integer()
  def count_cap, do: @count_cap

  @doc """
  One page of `org`'s registrations in `status` (`:pending`, the default, or
  `:rejected`), oldest first, each with the applicant's address, name and
  confirmation, and whether more follow.

  Options: `:actor` (required), `:status`, `:confirmed` (`true` or `false`: only
  applicants who have, or have not, confirmed their address; omitted: both),
  `:limit` (default `page_size/0`) and `:after` — the last entry of the
  previous page, to continue from it (a keyset on `inserted_at, id`, so rows
  decided between pages shift nothing).

  The console pages confirmed and unconfirmed applicants separately, so a wave
  of unconfirmed sign-ups cannot push the ones an admin can approve off the
  first page. A caller
  who is not an admin of `org` gets `{:error, %Ash.Error.Forbidden{}}`, never an
  empty queue.
  """
  @spec page(Accounts.Organization.t() | Ash.UUID.t() | nil, keyword()) ::
          {:ok, %{entries: [entry()], more?: boolean()}} | {:error, term()}
  def page(org, opts) do
    {status, opts} = Keyword.pop(opts, :status, :pending)
    {limit, opts} = Keyword.pop(opts, :limit, @page_size)
    {after_entry, opts} = Keyword.pop(opts, :after)
    {confirmed, opts} = Keyword.pop(opts, :confirmed)

    query = [
      filter: Ash.Expr.expr(^after_filter(after_entry) and ^confirmed_filter(confirmed)),
      limit: limit + 1
    ]

    with {:ok, memberships} <-
           Accounts.list_registration_queue(
             Accounts.org_id(org),
             status,
             Keyword.merge(opts, authorize_with: :error, query: query)
           ) do
      {page, rest} = Enum.split(memberships, limit)
      applicants = applicants(Enum.map(page, & &1.user_id))

      {:ok,
       %{
         entries: Enum.map(page, &entry(&1, Map.get(applicants, &1.user_id))),
         more?: rest != []
       }}
    end
  end

  @doc "The first page of `page/2`, as a list."
  @spec queue(Accounts.Organization.t() | Ash.UUID.t() | nil, keyword()) ::
          {:ok, [entry()]} | {:error, term()}
  def queue(org, opts) do
    with {:ok, %{entries: entries}} <- page(org, opts), do: {:ok, entries}
  end

  @doc """
  How many registrations on `org` await a decision, for `opts[:actor]`, up to
  `count_cap/0` (a bounded read of ids, not the queue); 0 when refused.
  `:confirmed` narrows it as in `page/2`.
  """
  @spec pending_count(Accounts.Organization.t() | Ash.UUID.t() | nil, keyword()) ::
          non_neg_integer()
  def pending_count(org, opts) do
    {confirmed, opts} = Keyword.pop(opts, :confirmed)

    case Accounts.list_registration_queue(
           Accounts.org_id(org),
           :pending,
           Keyword.merge(opts,
             authorize_with: :error,
             query: [filter: confirmed_filter(confirmed), select: [:id], limit: @count_cap]
           )
         ) do
      {:ok, rows} -> length(rows)
      {:error, _refused} -> 0
    end
  end

  defp after_filter(nil), do: true

  defp after_filter(%{membership: %{inserted_at: at, id: id}}),
    do: Ash.Expr.expr(inserted_at > ^at or (inserted_at == ^at and id > ^id))

  # Whether the applicant confirmed their address, asked of the users table in
  # SQL: the deciding admin may not read `User` (self-only), and a filter
  # through the relationship would be authorized as them and match nothing.
  # Only a boolean about the queue's own rows comes out, as `applicants/1`
  # reads for them anyway.
  defp confirmed_filter(nil), do: true

  defp confirmed_filter(confirmed?) when is_boolean(confirmed?) do
    Ash.Expr.expr(
      fragment(
        "EXISTS (SELECT 1 FROM users u WHERE u.id = ? AND u.confirmed_at IS NOT NULL)",
        user_id
      ) == ^confirmed?
    )
  end

  @doc """
  The applicant of a registration `membership` just approved, with only the
  columns the two-step sign-in requirement reads (#2247), or `nil`. For the
  warning the approval gives: a registration may have waited past the grace
  period of a site that requires a second factor of everyone, which holds the
  new member at their first page (`KilnCMSWeb.PromotionWarning`).

  Call it only with the membership an authorized approval returned: it reads
  the one applicant unauthorized, as `page/2` reads the queue's, and the queue
  entries themselves stay as narrow as they are.
  """
  @spec approved_applicant(Accounts.OrgMembership.t()) :: Accounts.User.t() | nil
  def approved_applicant(%{user_id: user_id}) do
    case Accounts.list_users!(
           authorize?: false,
           query: [
             filter: [id: user_id],
             select: [
               :id,
               :email,
               :inserted_at,
               :anonymized_at,
               :totp_confirmed_at,
               :role,
               :granted_role,
               :granted_role_expires_at
             ]
           ]
         ) do
      [applicant] -> applicant
      [] -> nil
    end
  end

  defp applicants([]), do: %{}

  defp applicants(user_ids) do
    # authorize?: false — the queue's own applicants only, five columns; `User`
    # reads are self-only and a site-admin grant there would read every account
    # (the queue read above already required an admin of this org)
    Accounts.list_users!(
      authorize?: false,
      query: [
        filter: [id: [in: user_ids]],
        select: [:id, :email, :name, :confirmed_at, :anonymized_at]
      ]
    )
    |> Map.new(&{&1.id, &1})
  end

  defp entry(membership, user) do
    %{
      membership: membership,
      email: user && to_string(user.email),
      name: user && user.name,
      confirmed?: match?(%{confirmed_at: %DateTime{}}, user),
      # Erased since registering (#2251): approving is refused, and a
      # rejection mails nobody, so the console says so.
      erased?: match?(%{anonymized_at: %DateTime{}}, user),
      registered_at: membership.inserted_at
    }
  end
end
