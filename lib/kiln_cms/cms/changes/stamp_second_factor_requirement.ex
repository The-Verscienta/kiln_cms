defmodule KilnCMS.CMS.Changes.StampSecondFactorRequirement do
  @moduledoc """
  Writes the derived columns of a `KilnCMS.CMS.SiteSecondFactorPolicy` on every
  write (#2247): when each tier became covered, and when the row changed.

  For each tier (`admin`, `editor`, `viewer`):

    * newly covered — stamped now;
    * still covered — the stored stamp is kept, so lengthening the grace or
      covering more tiers never restarts a tier's clock;
    * not covered — cleared.

  The row as it stood is read in the transaction, as the `:accounts` system
  actor with `authorize_with: :error`: an upsert `:save` lands on the existing
  row without loading it, so `changeset.data` cannot say. A read that fails
  fails the write; the stamps must not guess.

  It also puts what the write did into the changeset context for the audit
  event (`KilnCMS.CMS.Changes.RecordSecondFactorPolicyChange`):
  `:second_factor_previous` (`%{required_for:, grace_days:}`, or `nil` with no
  row) and `:second_factor_change` — `"weakened"` when fewer tiers are covered
  or the grace is longer, else `"strengthened"` when more tiers are covered or
  the grace is shorter, else `"unchanged"`.

  The server's clock, unless the changeset context carries `:now` (a
  `DateTime`), which tests set. No request path does.
  """
  use Ash.Resource.Change

  alias KilnCMS.CMS.SiteSecondFactorPolicy

  @previous :second_factor_previous
  @change :second_factor_change

  @doc false
  def previous_key, do: @previous

  @doc false
  def change_key, do: @change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &stamp/1)
  end

  defp stamp(changeset) do
    case KilnCMS.CMS.list_site_second_factor_policy(
           tenant: changeset.tenant,
           actor: KilnCMS.OrgSettings.system(:accounts),
           authorize_with: :error
         ) do
      {:ok, rows} -> stamp(changeset, List.first(rows))
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp stamp(changeset, previous) do
    now = now(changeset)
    required_for = Ash.Changeset.get_attribute(changeset, :required_for) || :off
    grace_days = Ash.Changeset.get_attribute(changeset, :grace_days)
    covered = SiteSecondFactorPolicy.covered_tiers(required_for)

    changeset =
      Enum.reduce(SiteSecondFactorPolicy.tiers(), changeset, fn tier, changeset ->
        field = since_field(tier)

        since =
          cond do
            tier not in covered -> nil
            previous_since(previous, tier) -> previous_since(previous, tier)
            true -> now
          end

        Ash.Changeset.force_change_attribute(changeset, field, since)
      end)

    changeset
    |> Ash.Changeset.force_change_attribute(:policy_changed_at, now)
    |> Ash.Changeset.set_context(%{
      @previous =>
        previous && %{required_for: previous.required_for, grace_days: previous.grace_days},
      @change => direction(previous, covered, grace_days)
    })
  end

  @doc false
  def since_field(:admin), do: :admin_required_since
  def since_field(:editor), do: :editor_required_since
  def since_field(:viewer), do: :viewer_required_since

  # A stamp carries over only while the tier was covered before too.
  defp previous_since(nil, _tier), do: nil

  defp previous_since(previous, tier) do
    if tier in SiteSecondFactorPolicy.covered_tiers(previous.required_for),
      do: Map.get(previous, since_field(tier))
  end

  # Weakening wins over strengthening: a write that covers one more tier but
  # doubles the grace still gave someone longer.
  defp direction(nil, covered, _grace_days),
    do: if(covered == [], do: "unchanged", else: "strengthened")

  defp direction(previous, covered, grace_days) do
    before = SiteSecondFactorPolicy.covered_tiers(previous.required_for)
    grace = if before == [], do: :eq, else: compare(grace_days, previous.grace_days)

    cond do
      before -- covered != [] or grace == :gt -> "weakened"
      covered -- before != [] or grace == :lt -> "strengthened"
      true -> "unchanged"
    end
  end

  defp compare(now, before) when now > before, do: :gt
  defp compare(now, before) when now < before, do: :lt
  defp compare(_now, _before), do: :eq

  defp now(changeset) do
    case changeset.context[:now] do
      %DateTime{} = now -> now
      _none -> DateTime.utc_now()
    end
  end
end
