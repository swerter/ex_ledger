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

  test "formats a posting with a per-unit cost (@)" do
    transaction = %{
      kind: :regular,
      date: ~D[2024-01-15],
      aux_date: nil,
      state: :uncleared,
      code: "",
      payee: "Buy stock",
      comment: nil,
      predicate: nil,
      period: nil,
      postings: [
        %{
          account: "Assets:Investments:AAPL",
          amount: %{value: 10, currency: "AAPL", currency_position: :trailing},
          cost: %{
            type: :per_unit,
            amount: %{value: 150.00, currency: "$", currency_position: :leading}
          },
          metadata: %{},
          tags: [],
          comments: []
        },
        posting("Assets:Checking", %{value: -1500.00, currency: "$", currency_position: :leading})
      ]
    }

    assert EntryFormatter.format_entry(transaction) ==
             "2024/01/15 Buy stock\n" <>
               "    Assets:Investments:AAPL  10.00 AAPL @ $150.00\n" <>
               "    Assets:Checking  $-1500.00\n"
  end

  test "formats a posting with a total cost (@@)" do
    transaction = %{
      kind: :regular,
      date: ~D[2024-01-15],
      aux_date: nil,
      state: :uncleared,
      code: "",
      payee: "Currency exchange",
      comment: nil,
      predicate: nil,
      period: nil,
      postings: [
        %{
          account: "Assets:EUR",
          amount: %{value: 100, currency: "EUR", currency_position: :trailing},
          cost: %{
            type: :total,
            amount: %{value: 110, currency: "USD", currency_position: :trailing}
          },
          metadata: %{},
          tags: [],
          comments: []
        },
        posting("Assets:USD", %{value: -110, currency: "USD", currency_position: :trailing})
      ]
    }

    assert EntryFormatter.format_entry(transaction) ==
             "2024/01/15 Currency exchange\n" <>
               "    Assets:EUR  100.00 EUR @@ 110.00 USD\n" <>
               "    Assets:USD  -110.00 USD\n"
  end

  test "formats a posting with cost and balance assertion" do
    transaction = %{
      kind: :regular,
      date: ~D[2024-01-15],
      aux_date: nil,
      state: :uncleared,
      code: "",
      payee: "Buy stock",
      comment: nil,
      predicate: nil,
      period: nil,
      postings: [
        %{
          account: "Assets:Investments:AAPL",
          amount: %{value: 10, currency: "AAPL", currency_position: :trailing},
          cost: %{
            type: :per_unit,
            amount: %{value: 150.00, currency: "$", currency_position: :leading}
          },
          assertion: %{value: 20, currency: "AAPL", currency_position: :trailing},
          metadata: %{},
          tags: [],
          comments: []
        },
        posting("Assets:Checking", %{value: -1500.00, currency: "$", currency_position: :leading})
      ]
    }

    assert EntryFormatter.format_entry(transaction) ==
             "2024/01/15 Buy stock\n" <>
               "    Assets:Investments:AAPL  10.00 AAPL @ $150.00 = 20.00 AAPL\n" <>
               "    Assets:Checking  $-1500.00\n"
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
