defmodule KilnCMS.Security.Posture.Checks.TransportTest do
  @moduledoc """
  `core.transport` (#2252): not applicable off production; on a production
  build, judged from what the running endpoint was compiled with. The test
  endpoint serves plain HTTP, so the one real read fails; `assess/1` is
  flipped one value at a time from a production-shaped baseline.
  """
  use ExUnit.Case, async: true

  import KilnCMS.PostureFixtures, only: [context: 2]

  alias KilnCMS.Security.Posture.Checks.Transport

  @prod %{
    force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: [hosts: ["localhost"]]],
    url: [host: "cms.example.com", port: 443, scheme: "https"],
    session_options: KilnCMSWeb.SessionCookie.options(true)
  }

  test "is not applicable on a non-production build" do
    assert %{status: :n_a} = Transport.run(context(nil, build_env: :test))
    assert %{status: :n_a} = Transport.run(context(nil, build_env: :dev))
  end

  test "on a production build, reads the running endpoint (plain HTTP here) and fails" do
    result = Transport.run(context(nil, build_env: :prod))

    assert result.status == :fail

    assert result.facts == %{
             force_ssl: false,
             hsts: false,
             https_url: false,
             secure_cookie: false
           }
  end

  test "a production-shaped endpoint passes" do
    assert %{status: :pass, details: [], facts: facts} = Transport.assess(@prod)
    assert facts == %{force_ssl: true, hsts: true, https_url: true, secure_cookie: true}
  end

  test "each value turned off fails, and says which" do
    cases = [
      {%{@prod | force_ssl: nil}, :force_ssl, "force_ssl"},
      {%{@prod | force_ssl: Keyword.put(@prod.force_ssl, :hsts, false)}, :hsts, "HSTS"},
      {%{@prod | url: Keyword.put(@prod.url, :scheme, "http")}, :https_url, "https"},
      {%{@prod | session_options: KilnCMSWeb.SessionCookie.options(false)}, :secure_cookie,
       "Secure"}
    ]

    for {values, fact, word} <- cases do
      result = Transport.assess(values)
      assert result.status == :fail, "#{fact} off still passed"
      assert result.facts[fact] == false
      # No force_ssl means no HSTS either, so that case names both.
      assert Enum.any?(result.details, &(&1 =~ word))
      assert length(result.details) == if(fact == :force_ssl, do: 2, else: 1)
    end
  end
end
