defmodule KilnCMS.SecurityTxtTest do
  @moduledoc """
  A site's `security.txt` (#1873): who may write it, what a value may contain,
  and that the renderer never writes a value that could forge a line.

  `async: false` — the resolver writes the shared Cachex.
  """
  use KilnCMS.DataCase, async: false

  import KilnCMS.OrgFixtures, only: [org: 1]

  alias KilnCMS.Accounts.User
  alias KilnCMS.CMS
  alias KilnCMS.CMS.SiteSecurityTxt
  alias KilnCMS.SecurityTxt

  setup do
    org = org("sectxt")
    on_exit(fn -> KilnCMS.Cache.bust_security_txt(org.id) end)
    %{org: org, admin: user(:admin)}
  end

  defp user(role) do
    Ash.Seed.seed!(User, %{
      email: "sectxt-#{role}-#{System.unique_integer([:positive])}@example.com",
      hashed_password: "x",
      confirmed_at: DateTime.utc_now(),
      role: role
    })
  end

  defp valid(attrs \\ %{}) do
    Map.merge(
      %{contacts: ["mailto:security@example.com"], expires_on: Date.add(Date.utc_today(), 90)},
      attrs
    )
  end

  defp save(attrs, ctx), do: CMS.save_site_security_txt(attrs, actor: ctx.admin, tenant: ctx.org)

  defp error_text({:error, error}), do: Exception.message(error)

  describe "policies" do
    test "an admin may write it", ctx do
      assert {:ok, _row} = save(valid(), ctx)
    end

    test "an editor, a viewer and an anonymous visitor may not", %{org: org} do
      for actor <- [user(:editor), user(:viewer), nil] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 CMS.save_site_security_txt(valid(), actor: actor, tenant: org)
      end

      assert {:ok, []} = CMS.list_site_security_txt(tenant: org, authorize?: false)
    end

    test "an editor may not remove it", ctx do
      row = CMS.save_site_security_txt!(valid(), actor: ctx.admin, tenant: ctx.org)

      assert {:error, %Ash.Error.Forbidden{}} =
               CMS.reset_site_security_txt(row, actor: user(:editor), tenant: ctx.org)
    end

    test "anyone may read it — the row is the public file", ctx do
      CMS.save_site_security_txt!(valid(), actor: ctx.admin, tenant: ctx.org)
      assert {:ok, [_row]} = CMS.list_site_security_txt(actor: nil, tenant: ctx.org)
    end
  end

  describe "a line break cannot forge a field" do
    test "CR/LF in a single-line URL is refused", ctx do
      forged = "https://example.com/policy\r\nContact: mailto:attacker@evil.test"

      for field <- [:policy_url, :acknowledgments_url, :encryption_url] do
        result = save(valid(%{field => forged}), ctx)
        assert {:error, _} = result, "#{field} accepted a CRLF"
        assert error_text(result) =~ "must be one line"
      end

      assert {:ok, []} = CMS.list_site_security_txt(tenant: ctx.org, authorize?: false)
    end

    test "a bare LF, a bare CR and Unicode line breaks are refused in a contact", ctx do
      for sep <- ["\n", "\r", "\u2028", "\u0085"] do
        contact = "mailto:security@example.com#{sep}Expires: 2099-01-01T00:00:00Z"
        assert {:error, _} = save(valid(%{contacts: [contact]}), ctx), inspect(sep)
      end
    end

    test "a line break in a language tag is refused", ctx do
      assert {:error, _} =
               save(valid(%{preferred_languages: ["en\nPolicy: https://x.test"]}), ctx)
    end

    test "the renderer drops a value that reached the table around the validation", ctx do
      # Seeded straight into the table, skipping the validation — a restore,
      # a console write. The forged line must still not reach the file.
      Ash.Seed.seed!(
        SiteSecurityTxt,
        %{
          contacts: [
            "mailto:ok@example.com",
            "mailto:x@example.com\nContact: mailto:evil@x.test"
          ],
          expires_on: Date.add(Date.utc_today(), 30),
          policy_url: "https://example.com/p\r\nHiring: https://evil.test"
        },
        tenant: ctx.org.id
      )

      assert {:ok, settings} = SecurityTxt.resolve(ctx.org)
      body = SecurityTxt.render(settings, "https://example.com/.well-known/security.txt")

      assert body =~ "Contact: mailto:ok@example.com\n"
      refute body =~ "evil"
      refute body =~ "Policy:"

      # Every line is a field the renderer wrote.
      for line <- String.split(body, "\n", trim: true) do
        assert line =~
                 ~r/\A(Contact|Expires|Encryption|Acknowledgments|Preferred-Languages|Canonical|Policy): \S+\z/
      end
    end
  end

  describe "values" do
    test "a contact must be mailto:, https:// or tel:", ctx do
      for bad <- ["security@example.com", "http://example.com/report", "ftp://x", "mailto:nobody"] do
        assert {:error, _} = save(valid(%{contacts: [bad]}), ctx), "accepted #{inspect(bad)}"
      end

      for good <- ["mailto:a@b.test", "https://example.com/report", "tel:+1-201-555-0123"] do
        assert {:ok, _} = save(valid(%{contacts: [good]}), ctx), "refused #{inspect(good)}"
      end
    end

    test "the policy URL must be https://", ctx do
      assert {:error, _} = save(valid(%{policy_url: "http://example.com/policy"}), ctx)
      assert {:error, _} = save(valid(%{policy_url: "javascript:alert(1)"}), ctx)
      assert {:ok, _} = save(valid(%{policy_url: "https://example.com/policy"}), ctx)
    end

    test "encryption takes https://, openpgp4fpr: or dns:", ctx do
      fingerprint = "openpgp4fpr:5f2de5521c63a801ab59ccb603d49de44b29100f"
      assert {:ok, _} = save(valid(%{encryption_url: fingerprint}), ctx)
      assert {:error, _} = save(valid(%{encryption_url: "ldap://example.com"}), ctx)
    end

    test "Expires is required with a contact, and may not be in the past", ctx do
      result = save(%{contacts: ["mailto:a@b.test"]}, ctx)
      assert error_text(result) =~ "is required when a contact is set"

      result = save(valid(%{expires_on: Date.add(Date.utc_today(), -1)}), ctx)
      assert error_text(result) =~ "must not be in the past"

      assert {:ok, _} = save(valid(%{expires_on: Date.utc_today()}), ctx)
    end
  end

  describe "render/2" do
    test "writes the RFC 9116 fields in order, Expires as RFC 3339" do
      settings = %SecurityTxt.Settings{
        contacts: ["mailto:security@example.com", "https://example.com/report"],
        expires_on: ~D[2027-03-31],
        policy_url: "https://example.com/policy",
        preferred_languages: ["en", "pt-BR"],
        encryption_url: "https://example.com/key.txt",
        acknowledgments_url: "https://example.com/thanks"
      }

      assert SecurityTxt.render(settings, "https://example.com/.well-known/security.txt") == """
             Contact: mailto:security@example.com
             Contact: https://example.com/report
             Expires: 2027-03-31T23:59:59Z
             Encryption: https://example.com/key.txt
             Acknowledgments: https://example.com/thanks
             Preferred-Languages: en, pt-BR
             Canonical: https://example.com/.well-known/security.txt
             Policy: https://example.com/policy
             """
    end
  end

  test "expiry_status/2 warns past, within 30 days, and beyond a year" do
    today = ~D[2026-10-04]
    assert SecurityTxt.expiry_status(nil, today) == :unset
    assert SecurityTxt.expiry_status(~D[2026-10-03], today) == :expired
    assert SecurityTxt.expiry_status(~D[2026-11-03], today) == :expiring
    assert SecurityTxt.expiry_status(~D[2027-04-01], today) == :ok
    assert SecurityTxt.expiry_status(~D[2027-12-01], today) == :too_far
  end
end
