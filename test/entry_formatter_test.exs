defmodule ExLedger.EntryFormatterTest do
  use ExUnit.Case

  alias ExLedger.EntryFormatter

  test "formats a ledger entry with notes and trailing currency" do
    transaction = %{
      kind: :regular,
      date: ~D[2024-01-01],
      aux_date: nil,
      state: :uncleared,
      code: "ABC",
      payee: "Coffee Shop",
      comment: "note",
      predicate: nil,
      period: nil,
      postings: [
        %{
          account: "Expenses:Food",
          amount: %{value: 100.0, currency: "CHF", currency_position: :trailing},
          metadata: %{"Type" => "Dining"},
          tags: ["Eating"],
          comments: ["extra note"]
        },
        posting("Assets:Cash", %{value: -100.0, currency: "CHF", currency_position: :trailing})
      ]
    }

    assert EntryFormatter.format_entry(transaction) ==
             "2024/01/01 (ABC) Coffee Shop  ; note\n" <>
               "    ; Type: Dining\n" <>
               "    ; :Eating:\n" <>
               "    ; extra note\n" <>
               "    Expenses:Food  100.00 CHF\n" <>
               "    Assets:Cash  -100.00 CHF\n"
  end

  test "formats a ledger entry with an override date" do
    transaction = %{
      kind: :regular,
      date: ~D[2024-01-01],
      aux_date: nil,
      state: :uncleared,
      code: "",
      payee: "Transfer",
      comment: nil,
      predicate: nil,
      period: nil,
      postings: [posting("Assets:Bank", nil)]
    }

    assert EntryFormatter.format_entry(transaction, ~D[2024-02-02]) ==
             "2024/02/02 Transfer\n" <>
               "    Assets:Bank\n"
  end

  defp posting(account, amount) do
    %{
      account: account,
      amount: amount,
      metadata: %{},
      tags: [],
      comments: []
    }
  end
end
