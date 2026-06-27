# Dialyzer warnings to ignore. Keep this list tight — only third-party /
# version-specific noise, never bugs in our own logic.
[
  # The regex catches `Ash.Resource.record/0` references in ash_authentication_phoenix
  # (and similar) typespecs. Dialyzer can't resolve it on some OTP/Elixir combos
  # (e.g. OTP 29 / 1.20). Third-party noise only; keep the list tight.
  ~r/Unknown type: Ash\.Resource\.record/
]
