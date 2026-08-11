defmodule KilnCMS.CountlessVersions do
  @moduledoc """
  A stand-in content resource whose `Version` store can be read but never
  counted: `Ash.DataLayer.Simple` supports plain reads (fed from
  `:persistent_term`) and refuses aggregates, so `Ash.count!` raises.

  `KilnCMS.Governance.Chain` tests pass this module as the `resource`
  argument to exercise the covered-count rescue (#705): the range-count
  closure's queries must be able to fail without taking the verdict down
  with them. Seed rows with `put_rows/1` (they stand in for version rows of
  whatever real document the anchors belong to) and clean up with
  `clear_rows/0`.
  """

  def put_rows(rows), do: :persistent_term.put(__MODULE__, rows)
  def clear_rows, do: :persistent_term.erase(__MODULE__)
  def rows, do: :persistent_term.get(__MODULE__, [])

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource KilnCMS.CountlessVersions.Version
    end
  end

  defmodule Version do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.CountlessVersions.Domain,
      data_layer: Ash.DataLayer.Simple

    actions do
      read :read do
        primary? true

        prepare fn query, _context ->
          Ash.DataLayer.Simple.set_data(query, KilnCMS.CountlessVersions.rows())
        end
      end
    end

    attributes do
      uuid_primary_key :id

      attribute :version_source_id, :uuid, public?: true
      attribute :version_action_name, :string, public?: true
      # The attribution fold (#713) reads these off a version too, so the stand-in
      # carries them like a real PaperTrail version does.
      attribute :version_action_type, :atom, public?: true
      attribute :user_id, :uuid, public?: true
      attribute :version_inserted_at, :utc_datetime_usec, public?: true
      attribute :changes, :map, public?: true
    end
  end
end
