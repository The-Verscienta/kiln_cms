defmodule KilnCMS.Federation.SeenSignatureSweeper do
  @moduledoc """
  Deletes expired rows from the replay nonce store (#967) — hourly by default,
  `config :kiln_cms, :federation_nonce_sweep_cron`
  (`KILN_FEDERATION_NONCE_SWEEP_CRON`; `false` disables). A row past its
  `expires_at` cannot verify anyway (`HttpSignature` refuses the `Date`), so
  the sweep is hygiene, not security: without it the table grows by one row
  per inbound activity forever.
  """
  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 3_000]

  alias KilnCMS.Federation.SeenSignature

  @impl Oban.Worker
  def perform(_job), do: {:ok, run()}

  @doc "One sweep; returns how many rows were removed."
  @spec run() :: non_neg_integer()
  def run do
    expired = Ash.Query.for_read(SeenSignature, :expired)
    count = Ash.count!(expired, authorize?: false)

    if count > 0 do
      Ash.bulk_destroy!(expired, :destroy, %{}, authorize?: false, strategy: :atomic)
    end

    count
  end
end
