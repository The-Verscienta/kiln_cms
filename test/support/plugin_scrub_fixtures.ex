defmodule KilnCMS.PluginScrubFixtures do
  @moduledoc """
  Plugin-owned tables for the staging scrub's plugin rule (#2975),
  `test/kiln_cms/staging/plugin_scrub_test.exs`.

  AshPostgres resources on domains no config lists, so nothing outside the
  test that names them sees them. Their tables are not migrated: a test
  creates the ones it needs inside its sandbox (`create_table!/2`), with no
  foreign key to a core table (one would lock it), and they vanish with the
  test's transaction. A table a test does not create does not exist, which the
  scrub treats as a plugin installed but not migrated.

  The resources are never read or written through Ash; the scrub works at the
  repo level, and the tests seed rows with SQL.
  """

  alias KilnCMS.Repo

  @doc "Create `table` (a `psf_*` table below) in the test's sandbox."
  def create_table!(table, opts \\ [])

  # A plugin table in a schema of its own, named like a core table.
  def create_table!("psf_crm.users", _opts) do
    Repo.query!("CREATE SCHEMA psf_crm")
    Repo.query!("CREATE TABLE psf_crm.users (id uuid PRIMARY KEY DEFAULT gen_random_uuid())")
  end

  def create_table!(table, opts), do: Repo.query!(ddl(table, opts))

  # Options shape `guests` and `name` the way a plugin's own migration might,
  # past what its Ash resource says: `guests: :check` (must be positive),
  # `guests: :generated`, `name: :unique`, `email: :not_null`.
  defp ddl("psf_bookings", opts) do
    guests =
      case Keyword.get(opts, :guests) do
        :check -> "guests bigint CHECK (guests > 0)"
        :generated -> "guests bigint GENERATED ALWAYS AS (4) STORED"
        nil -> "guests bigint"
      end

    name = if opts[:name] == :unique, do: "name text NOT NULL UNIQUE", else: "name text NOT NULL"
    email = if opts[:email] == :not_null, do: "email text NOT NULL", else: "email text"

    """
    CREATE TABLE psf_bookings (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      code text NOT NULL UNIQUE,
      #{email},
      #{name},
      #{guests}
    )
    """
  end

  # A table no resource describes (a raw migration's), referencing a plugin's.
  defp ddl("psf_foreign", _opts) do
    """
    CREATE TABLE psf_foreign (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      booking_id uuid CONSTRAINT psf_foreign_booking_fkey
        REFERENCES psf_bookings(id) ON DELETE RESTRICT
    )
    """
  end

  defp ddl("psf_bookings_versions", _opts) do
    """
    CREATE TABLE psf_bookings_versions (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      version_source_id uuid NOT NULL,
      changes jsonb
    )
    """
  end

  # `on_delete:` is the SQL of the key to psf_bookings (default NO ACTION).
  defp ddl("psf_booking_notes", opts) do
    """
    CREATE TABLE psf_booking_notes (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      body text,
      booking_id uuid CONSTRAINT psf_booking_notes_booking_fkey
        REFERENCES psf_bookings(id) ON DELETE #{Keyword.get(opts, :on_delete, "NO ACTION")}
    )
    """
  end

  defp ddl("psf_venues", _opts),
    do: "CREATE TABLE psf_venues (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text)"

  defp ddl("psf_undeclared", _opts),
    do: "CREATE TABLE psf_undeclared (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), secret text)"

  defp ddl("psf_events", _opts),
    do: "CREATE TABLE psf_events (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), title text)"

  defp ddl("psf_contacts", _opts),
    do: "CREATE TABLE psf_contacts (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), email text)"

  defp ddl("psf_links", _opts),
    do: "CREATE TABLE psf_links (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), position bigint)"

  defp ddl("psf_overlay_things", _opts),
    do:
      "CREATE TABLE psf_overlay_things (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), note text)"

  defp ddl("psf_view", _opts), do: "CREATE VIEW psf_view AS SELECT 1 AS id"

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource KilnCMS.PluginScrubFixtures.Booking
      resource KilnCMS.PluginScrubFixtures.Booking.Version
      resource KilnCMS.PluginScrubFixtures.BookingAlias
      resource KilnCMS.PluginScrubFixtures.BookingNote
      resource KilnCMS.PluginScrubFixtures.Venue
      resource KilnCMS.PluginScrubFixtures.Undeclared
      resource KilnCMS.PluginScrubFixtures.Event
      resource KilnCMS.PluginScrubFixtures.Contact
      resource KilnCMS.PluginScrubFixtures.Link
      resource KilnCMS.PluginScrubFixtures.Tenanted
    end
  end

  defmodule Booking do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshPaperTrail.Resource]

    postgres do
      table "psf_bookings"
      repo KilnCMS.Repo
    end

    paper_trail do
      change_tracking_mode(:changes_only)
      reference_source?(false)
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
      attribute :code, :string, allow_nil?: false, public?: true
      attribute :email, :string, public?: true
      attribute :name, :string, allow_nil?: false, public?: true
      attribute :guests, :integer, public?: true
    end

    identities do
      identity :unique_code, [:code]
    end
  end

  # A second resource over psf_bookings (a read model, say).
  defmodule BookingAlias do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "psf_bookings"
      repo KilnCMS.Repo
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
      attribute :code, :string, allow_nil?: false, public?: true
    end
  end

  defmodule BookingNote do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "psf_booking_notes"
      repo KilnCMS.Repo
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
      attribute :body, :string, public?: true
    end

    relationships do
      belongs_to :booking, KilnCMS.PluginScrubFixtures.Booking, public?: true
    end
  end

  defmodule Venue do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "psf_venues"
      repo KilnCMS.Repo
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end
  end

  defmodule Undeclared do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "psf_undeclared"
      repo KilnCMS.Repo
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
      attribute :secret, :string, public?: true
    end
  end

  # A content type as far as the scrub can tell: it exports the hook
  # `KilnCMS.CMS.Content` defines.
  defmodule Event do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.Domain,
      data_layer: AshPostgres.DataLayer

    def __kiln_content_type__, do: :psf_event

    postgres do
      table "psf_events"
      repo KilnCMS.Repo
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, public?: true
    end
  end

  # A content type with an address column, which content does not excuse.
  defmodule Contact do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.Domain,
      data_layer: AshPostgres.DataLayer

    def __kiln_content_type__, do: :psf_contact

    postgres do
      table "psf_contacts"
      repo KilnCMS.Repo
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
      attribute :email, :string, public?: true
    end
  end

  # A graduated join as far as the scrub can tell (`KilnCMS.CMS.JoinGraduation`).
  defmodule Link do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.Domain,
      data_layer: AshPostgres.DataLayer

    def __kiln_join__, do: %{}

    postgres do
      table "psf_links"
      repo KilnCMS.Repo
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
      attribute :position, :integer, public?: true
    end
  end

  defmodule Tenanted do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.Domain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "psf_tenanted"
      repo KilnCMS.Repo
    end

    multitenancy do
      strategy :attribute
      attribute :org_id
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
      attribute :org_id, :uuid, allow_nil?: false, public?: true
      attribute :label, :string, public?: true
    end
  end

  # An overlay's own domain: in `:ash_domains` (when a test passes it), and
  # in no plugin's `domains/0`.
  defmodule Overlay do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource KilnCMS.PluginScrubFixtures.OverlayThing
    end
  end

  defmodule OverlayThing do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.Overlay,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "psf_overlay_things"
      repo KilnCMS.Repo
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
      attribute :note, :string, public?: true
    end
  end

  defmodule ContextDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource KilnCMS.PluginScrubFixtures.ContextThing
    end
  end

  # A schema per tenant: the scrub cannot list those schemas.
  defmodule ContextThing do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.ContextDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "psf_context_things"
      repo KilnCMS.Repo
    end

    multitenancy do
      strategy :context
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule CrmDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource KilnCMS.PluginScrubFixtures.CrmUser
    end
  end

  # `users`, but in the plugin's own schema: not the core's table.
  defmodule CrmUser do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.CrmDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "users"
      schema "psf_crm"
      repo KilnCMS.Repo
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
    end
  end

  defmodule ViewDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource KilnCMS.PluginScrubFixtures.OverView
    end
  end

  # A resource over a view: no rows of its own to scrub.
  defmodule OverView do
    @moduledoc false
    use Ash.Resource,
      domain: KilnCMS.PluginScrubFixtures.ViewDomain,
      data_layer: AshPostgres.DataLayer

    postgres do
      table "psf_view"
      repo KilnCMS.Repo
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id
    end
  end

  # The plugin a site would write for the domain above: every table it can
  # create declared, one way each.
  defmodule DeclaringPlugin do
    @moduledoc false
    use Kiln.Plugin

    alias KilnCMS.PluginScrubFixtures, as: F

    @impl true
    def name, do: "booking"

    @impl true
    def domains, do: [F.Domain]

    @impl true
    def staging_scrub,
      do: [
        {:purge, F.BookingNote},
        {:rewrite, F.Booking, set: [email: nil, name: "Scrubbed guest", guests: 0]},
        {:purge, F.Booking.Version},
        {:keep, F.Venue, "venue opening hours, no visitors"}
      ]
  end
end
