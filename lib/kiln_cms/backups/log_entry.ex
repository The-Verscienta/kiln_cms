defmodule KilnCMS.Backups.LogEntry do
  @moduledoc """
  One line of a backup run's structured log (#2217), embedded in
  `KilnCMS.Backups.Run`'s `log`.

  The message is capped at 500 characters and passes through
  `KilnCMS.Backups.Redact` before it is stored; `KilnCMS.Backups.Log.cap/1` does
  both for a whole log, so a writer cannot forget either.
  """
  use Ash.Resource, data_layer: :embedded

  @levels [:info, :warn, :error]

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:at, :level, :step, :message]
    end

    update :update do
      primary? true
      accept [:at, :level, :step, :message]
    end
  end

  attributes do
    attribute :at, :utc_datetime_usec do
      allow_nil? false
      default &DateTime.utc_now/0
      public? true
    end

    attribute :level, :atom do
      allow_nil? false
      default :info
      constraints one_of: @levels
      public? true
    end

    # Which stage wrote it ("dump", "media", "offsite", "prune", "truncated").
    #
    # `step` (64) and `message` (500) are bounded by `Backups.Log.cap/1`, which
    # `Run`'s `Normalize` change applies, rather than by constraints here: a
    # constraint rejects an over-long entry while it is cast, before any change
    # runs, and the right answer to a chatty rclone is to truncate, not to lose
    # the whole log write.
    attribute :step, :string, allow_nil?: false, public?: true

    attribute :message, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true],
      public?: true
  end

  @doc "The levels a log line may carry."
  def levels, do: @levels
end
