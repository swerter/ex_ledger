defmodule ExLedger.LedgerParserBalanceTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser

  @moduledoc """
  Tests for balance_postings, parse_ledger, and validation functions.
  """

  describe "balance_postings/1" do
    test "balances postings when second amount is nil" do
      postings = [
        %{
          account: "Expenses:Food",
          amount: %{value: Decimal.from_float(4.50), currency: "$", currency_position: :leading}
        },
        %{account: "Assets:Checking", amount: nil}
      ]

      result = LedgerParser.balance_postings(postings)
      balanced = Enum.at(result, 1).amount

      assert Decimal.eq?(balanced.value, Decimal.from_float(-4.50))
      assert balanced.currency == "$"
    end

    test "balances postings when first amount is nil" do
      postings = [
        %{account: "Assets:Checking", amount: nil},
        %{account: "Income", amount: %{value: Decimal.from_float(20.00), currency: "$", currency_position: :leading}}
      ]

      result = LedgerParser.balance_postings(postings)
      balanced = Enum.at(result, 0).amount

      assert Decimal.eq?(balanced.value, Decimal.from_float(-20.00))
      assert balanced.currency == "$"
    end

    test "does not modify postings when all amounts are specified" do
      postings = [
        %{
          account: "Expenses:Food",
          amount: %{value: Decimal.from_float(4.50), currency: "$", currency_position: :leading}
        },
        %{
          account: "Assets:Checking",
          amount: %{value: Decimal.from_float(-4.50), currency: "$", currency_position: :leading}
        }
      ]

      result = LedgerParser.balance_postings(postings)

      # Compare values individually since Decimal structs need Decimal.eq?
      assert Decimal.eq?(Enum.at(result, 0).amount.value, Enum.at(postings, 0).amount.value)
      assert Decimal.eq?(Enum.at(result, 1).amount.value, Enum.at(postings, 1).amount.value)
    end

    test "balances with multiple postings (one nil)" do
      postings = [
        %{
          account: "Expenses:Food",
          amount: %{value: Decimal.from_float(3.00), currency: "$", currency_position: :leading}
        },
        %{
          account: "Expenses:Drink",
          amount: %{value: Decimal.from_float(1.50), currency: "$", currency_position: :leading}
        },
        %{account: "Assets:Checking", amount: nil}
      ]

      result = LedgerParser.balance_postings(postings)
      balanced = Enum.at(result, 2).amount

      assert Decimal.eq?(balanced.value, Decimal.from_float(-4.50))
      assert balanced.currency == "$"
    end

    test "expands a missing multi-currency posting into one posting per currency" do
      postings = [
        %{account: "Assets:Cash", amount: %{value: Decimal.from_float(10.00), currency: "USD"}},
        %{account: "Expenses:Fees", amount: %{value: Decimal.from_float(-5.00), currency: "CHF"}},
        %{account: "Equity:Opening", amount: nil}
      ]

      result = LedgerParser.balance_postings(postings)

      assert length(result) == 4
      [_, _, equity1, equity2] = result
      assert equity1.account == "Equity:Opening"
      assert equity2.account == "Equity:Opening"

      by_currency = Map.new([equity1, equity2], &{&1.amount.currency, &1.amount.value})
      assert Decimal.eq?(by_currency["USD"], Decimal.from_float(-10.00))
      assert Decimal.eq?(by_currency["CHF"], Decimal.from_float(5.00))
    end
  end

  describe "validate_transaction/1" do
    test "validates balanced transaction" do
      transaction = %{
        date: ~D[2009-10-29],
        code: "XFER",
        description: "Panera Bread",
        postings: [
          %{account: "Expenses:Food", amount: %{value: 4.50, currency: "$"}},
          %{account: "Assets:Checking", amount: %{value: -4.50, currency: "$"}}
        ]
      }

      assert :ok = LedgerParser.validate_transaction(transaction)
    end

    test "returns error when multiple postings are missing amounts" do
      transaction = %{
        postings: [
          %{account: "Assets:Cash", amount: nil},
          %{account: "Expenses:Food", amount: nil},
          %{account: "Equity:Opening", amount: %{value: 5.00, currency: "$"}}
        ]
      }

      assert {:error, :multiple_nil_amounts} = LedgerParser.validate_transaction(transaction)
    end

    test "returns error for unbalanced transaction" do
      transaction = %{
        date: ~D[2009-10-29],
        code: "XFER",
        description: "Panera Bread",
        postings: [
          %{account: "Expenses:Food", amount: %{value: 4.50, currency: "$"}},
          %{account: "Assets:Checking", amount: %{value: -3.00, currency: "$"}}
        ]
      }

      assert {:error, :unbalanced} = LedgerParser.validate_transaction(transaction)
    end

    test "validates transaction with multiple postings summing to zero" do
      transaction = %{
        date: ~D[2009-10-29],
        code: "XFER",
        description: "Split purchase",
        postings: [
          %{account: "Expenses:Food", amount: %{value: 3.00, currency: "$"}},
          %{account: "Expenses:Drink", amount: %{value: 1.50, currency: "$"}},
          %{account: "Assets:Checking", amount: %{value: -4.50, currency: "$"}}
        ]
      }

      assert :ok = LedgerParser.validate_transaction(transaction)
    end
  end
end
