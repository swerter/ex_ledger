defmodule ExLedger.EntryFormatterTest do
  use ExUnit.Case

  alias ExLedger.EntryFormatter

  test "formats a ledger entry with code, comment, and postings" do
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
        posting("Expenses:Food", %{value: 5.0, currency: "$"}),
        posting("Assets:Cash", %{value: -5.0, currency: "$"})
      ]
    }

    assert EntryFormatter.format_entry(transaction) ==
             "2024/01/01 (ABC) Coffee Shop  ; note\n" <>
               "    Expenses:Food  $5.00\n" <>
               "    Assets:Cash  $-5.00\n"
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
