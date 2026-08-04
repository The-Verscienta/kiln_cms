defmodule KilnCMS.Analytics.FunnelReportTest do
  @moduledoc """
  Deriving a funnel's step traffic from `ContentViewDay` buckets (#622): the
  targeted per-type read, the low-count-suppressed display, and the
  population-ratio labelling (never computed from a suppressed count).
  """
  use KilnCMS.DataCase, async: false

  alias KilnCMS.Analytics
  alias KilnCMS.Analytics.ContentViewDay
  alias KilnCMS.Analytics.FunnelReport

  defp admin do
    Ash.Seed.seed!(KilnCMS.Accounts.User, %{
      email: "funrep-#{System.unique_integer([:positive])}@example.com",
      hashed_password: Bcrypt.hash_pwd_salt("password123456"),
      confirmed_at: DateTime.utc_now(),
      role: :admin
    })
  end

  defp today, do: Date.utc_today()

  defp org, do: KilnCMS.Accounts.default_org()

  defp bucket!(content_type, content_id, day, views) do
    Ash.Seed.seed!(ContentViewDay, %{
      content_type: content_type,
      content_id: content_id,
      day: day,
      views: views
    })
  end

  defp funnel_with_steps!(steps) do
    admin = admin()

    funnel =
      Analytics.create_funnel!(
        %{name: "Signup", slug: "funrep-#{System.unique_integer([:positive])}"},
        actor: admin
      )

    for {content_type, content_id, position} <- steps do
      Analytics.create_funnel_step!(
        %{
          funnel_id: funnel.id,
          content_type: content_type,
          content_id: content_id,
          position: position
        },
        actor: admin
      )
    end

    {funnel, admin}
  end

  test "sums each step's views within the window, in position order" do
    landing = Ash.UUID.generate()
    pricing = Ash.UUID.generate()

    bucket!("page", landing, today(), 20)
    bucket!("page", landing, Date.add(today(), -1), 10)
    bucket!("page", pricing, today(), 6)
    # Outside the window — must not count.
    bucket!("page", pricing, Date.add(today(), -10), 100)

    {funnel, admin} =
      funnel_with_steps!([{"page", landing, 0}, {"page", pricing, 1}])

    [step1, step2] =
      FunnelReport.report(funnel, Date.add(today(), -2), today(), org(), admin)

    assert step1.count == 30
    assert step2.count == 6
    assert step1.ratio == nil
    assert step2.ratio == Float.round(6 / 30 * 100, 1)
  end

  test "a step with no buckets in the window reports zero, ratio nil after a zero denominator" do
    landing = Ash.UUID.generate()
    pricing = Ash.UUID.generate()

    {funnel, admin} = funnel_with_steps!([{"page", landing, 0}, {"page", pricing, 1}])

    [step1, step2] = FunnelReport.report(funnel, today(), today(), org(), admin)

    assert step1.count == 0
    assert step1.display == 0
    assert step2.count == 0
    # No denominator to divide by — not "0%", which would misreport as a real
    # measured drop, but an honest "can't say".
    assert step2.ratio == nil
  end

  test "the ratio can exceed 100% — a later step is not capped by an earlier one" do
    landing = Ash.UUID.generate()
    pricing = Ash.UUID.generate()

    bucket!("page", landing, today(), 5)
    bucket!("page", pricing, today(), 50)

    {funnel, admin} = funnel_with_steps!([{"page", landing, 0}, {"page", pricing, 1}])

    [_step1, step2] = FunnelReport.report(funnel, today(), today(), org(), admin)

    assert step2.ratio == 1000.0
  end

  test "a suppressed count never leaks into a computed ratio" do
    landing = Ash.UUID.generate()
    pricing = Ash.UUID.generate()

    threshold = Analytics.low_count_threshold()
    bucket!("page", landing, today(), threshold + 10)
    # Below threshold — this step's own count is suppressed.
    bucket!("page", pricing, today(), threshold - 1)

    {funnel, admin} = funnel_with_steps!([{"page", landing, 0}, {"page", pricing, 1}])

    [step1, step2] = FunnelReport.report(funnel, today(), today(), org(), admin)

    assert is_binary(step2.display)
    assert step1.ratio == nil
    assert step2.ratio == nil
  end

  test "a deleted step's content still gets a row, titled as deleted" do
    gone_id = Ash.UUID.generate()
    bucket!("page", gone_id, today(), 5)

    {funnel, admin} = funnel_with_steps!([{"page", gone_id, 0}])

    [step] = FunnelReport.report(funnel, today(), today(), org(), admin)

    assert step.title == "(deleted)"
    assert step.count == 5
  end
end
