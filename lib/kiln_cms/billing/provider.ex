defmodule KilnCMS.Billing.Provider do
  @moduledoc """
  Payment-provider seam for paid memberships (#337 Phase 2).

  One implementation ships (`KilnCMS.Billing.Providers.Stripe`); the behaviour
  exists so a second gateway is an adapter rather than a rewrite, and so tests
  can swap a stub without HTTP. Selected via `KilnCMS.Billing.provider/0`
  (`config :kiln_cms, KilnCMS.Billing, provider: …`) — the same
  behaviour-plus-config-selection shape as `KilnCMS.Search.Meilisearch.Client`
  and `KilnCMS.Seo.Generator`.

  ## What is deliberately *not* on this behaviour

  No create-customer (hosted checkout creates one), no create-price/product (an
  operator configures prices in the provider's own dashboard and pastes the
  price id onto a `KilnCMS.Billing.MembershipTier`, so there is one source of
  truth for money, and currency/tax/trials stay out of our model), and no
  cancel-subscription (the hosted billing portal owns cancellation — a local
  cancel primitive would create a second, divergent cancellation path).

  Card data never reaches Kiln: both money-handling callbacks return a hosted
  URL we redirect to.
  """

  @typedoc """
  Resolved provider credentials. Assembled by `KilnCMS.Billing.credentials/0`
  from `KilnCMS.Keys`, never read from the resource directly.
  """
  @type config :: %{
          required(:secret_key) => String.t(),
          optional(:webhook_secret) => String.t()
        }

  @typedoc "A hosted-page handoff: where to send the member."
  @type session :: %{required(:url) => String.t(), optional(:id) => String.t()}

  @doc """
  Open a hosted checkout session for one subscription.

  `params` carries the price id, the member's email, the return URLs and the
  metadata that makes the resulting webhook events self-describing (see
  `KilnCMS.Billing.Providers.Stripe` for the metadata contract).
  """
  @callback create_checkout_session(params :: map(), config()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Open a hosted billing-portal session.

  #337 makes dunning, tax, invoices and card updates explicit non-goals, so the
  portal is not garnish: it is the entire self-service management surface, and
  the mechanism by which "cancellation revokes access without admin
  involvement" is reachable by the member at all.
  """
  @callback create_portal_session(params :: map(), config()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Fetch authoritative subscription state.

  Needed twice: immediately after a completed checkout, so the happy path
  activates in one event instead of waiting for a follow-up subscription event
  (this is what makes "read gated content immediately" true), and from the
  reconcile sweep that repairs state after a webhook is lost.
  """
  @callback retrieve_subscription(id :: String.t(), config()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Fetch a completed checkout session.

  Closes the return-from-provider race: the success redirect is
  attacker-suppliable so we never grant from it, but we can look the session up
  server-side and apply the same reconcile, so a member who lands back on
  `/account` before the webhook does isn't shown "activating…".
  """
  @callback retrieve_checkout_session(id :: String.t(), config()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Verify an inbound webhook against `raw_body` and return the decoded event.

  Local — no HTTP. On the behaviour because a second gateway brings a different
  scheme (header name, signed-payload construction, tolerance) and the receiver
  must not know which. Implementations MUST verify before decoding, so
  unauthenticated bytes never reach the JSON decoder.
  """
  @callback verify_webhook(
              raw_body :: binary(),
              signature_header :: String.t() | nil,
              secret :: String.t(),
              opts :: keyword()
            ) ::
              {:ok, map()}
              | {:error,
                 :invalid_signature
                 | :timestamp_out_of_tolerance
                 | :malformed_signature
                 | :malformed_payload}
end
