defmodule KilnCMS.MailDkimCacheTest do
  @moduledoc """
  The `:persistent_term` DKIM cache is process-global, so it's disabled for
  the async suite (config/test.exs) and exercised here alone, synchronously:
  compute → cached term exists; settings mutation → invalidated → fresh value.
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Accounts.User
  alias KilnCMS.Mail

  @cache_key {KilnCMS.Mail, :dkim_config}

  setup do
    previous = Application.get_env(:kiln_cms, KilnCMS.Mail, [])
    Application.put_env(:kiln_cms, KilnCMS.Mail, Keyword.put(previous, :cache_dkim?, true))

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Mail, previous)
      Mail.invalidate_dkim_cache()
    end)

    :ok
  end

  test "dkim_config caches its result and key mutations invalidate it" do
    admin =
      Ash.Seed.seed!(User, %{
        email: "cache-#{System.unique_integer([:positive])}@example.com",
        hashed_password: Bcrypt.hash_pwd_salt("password123456"),
        confirmed_at: DateTime.utc_now(),
        role: :admin
      })

    settings = Mail.generate_dkim!(Mail.ensure_settings!(), actor: admin)

    assert :persistent_term.get(@cache_key, :missing) == :missing

    first = Mail.dkim_config()
    assert first[:s] == settings.dkim_selector
    assert :persistent_term.get(@cache_key, :missing) == first

    rotated = Mail.rotate_dkim!(Mail.get_settings(), actor: admin)

    # Rotation invalidated the cached term; the next call recomputes.
    assert :persistent_term.get(@cache_key, :missing) == :missing
    assert Mail.dkim_config()[:s] == rotated.dkim_selector
  end
end
