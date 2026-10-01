defmodule KilnCMSWeb.MailSettingsUnconfiguredLiveTest do
  @moduledoc """
  `/editor/mail` with no outgoing mail server, and with job errors left by an
  adapter crash (#1843).

  `async: false`: it swaps the operator's mailer adapter and the `:swoosh`
  `:local` flag, both application-global.
  """
  use KilnCMSWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias KilnCMS.Accounts.User

  @password "password123456"

  setup do
    mailer = Application.get_env(:kiln_cms, KilnCMS.Mailer)
    local = Application.fetch_env(:swoosh, :local)

    on_exit(fn ->
      Application.put_env(:kiln_cms, KilnCMS.Mailer, mailer)

      case local do
        {:ok, value} -> Application.put_env(:swoosh, :local, value)
        :error -> Application.delete_env(:swoosh, :local)
      end
    end)

    :ok
  end

  defp mount_as_admin(conn) do
    email = "mail-unconf-#{System.unique_integer([:positive])}@example.com"

    Ash.Seed.seed!(User, %{
      email: email,
      hashed_password: Bcrypt.hash_pwd_salt(@password),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })

    {:ok, user} =
      User
      |> AshAuthentication.Info.strategy!(:password)
      |> AshAuthentication.Strategy.action(:sign_in, %{"email" => email, "password" => @password})

    {:ok, lv, html} =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> live(~p"/editor/mail")

    {lv, html}
  end

  test "a test send says no mail server is set up", %{conn: conn} do
    # What a release ships: the stock local adapter and no mailbox for it.
    Application.put_env(:kiln_cms, KilnCMS.Mailer, adapter: Swoosh.Adapters.Local)
    Application.put_env(:swoosh, :local, false)

    {lv, _html} = mount_as_admin(conn)

    lv
    |> form(~s{form[phx-submit="send_test"]}, test: %{to: "probe@example.com"})
    |> render_submit()

    render_async(lv, 2_000)

    assert has_element?(
             lv,
             ~s{[data-test-result="fail"]},
             "No outgoing mail server is set up, so nothing can be sent."
           )
  end

  test "the failures panel never shows a link from a stored crash", %{conn: conn} do
    job =
      %{"to" => ["", "reader@example.com"]}
      |> KilnCMS.Mail.DeliveryWorker.new()
      |> KilnCMS.Repo.insert!()

    crash =
      ~s|** (exit) exited in: GenServer.call({:global, Swoosh.Adapters.Local.Storage.Memory}, | <>
        ~s|{:push, %Swoosh.Email{html_body: "<a href=\\"https://cms.example/password-reset/LEAKED\\">"}}, 5000)|

    KilnCMS.Repo.update_all(
      from(j in Oban.Job, where: j.id == ^job.id),
      set: [
        state: "discarded",
        attempted_at: DateTime.utc_now(),
        errors: [%{"attempt" => 8, "at" => "2026-09-30T00:00:00Z", "error" => crash}]
      ]
    )

    {_lv, html} = mount_as_admin(conn)

    assert html =~ "details held the message and were removed"
    refute html =~ "LEAKED"
    refute html =~ "password-reset"
  end
end
