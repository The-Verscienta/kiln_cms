# A throwaway resource the Security.Changes.Record test runs the change on.
defmodule KilnCMS.Test.SecurityRecorder.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource KilnCMS.Test.SecurityRecorder.Thing
  end
end

defmodule KilnCMS.Test.SecurityRecorder.Thing do
  @moduledoc false
  use Ash.Resource,
    domain: KilnCMS.Test.SecurityRecorder.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    create :in_txn do
      accept [:name]

      change {KilnCMS.Security.Changes.Record,
              type: :passkey_added,
              target: fn record, _cs -> {"thing", record.id} end,
              metadata: fn record, _cs -> %{"name" => record.name} end}
    end

    create :committed do
      accept [:name]
      change {KilnCMS.Security.Changes.Record, type: :passkey_removed, mode: :after_commit}
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end
end
