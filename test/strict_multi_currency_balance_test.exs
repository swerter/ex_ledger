defmodule ExLedger.StrictMultiCurrencyBalanceTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser

  @moduledoc """
  Tests for strict multi-currency balance validation.

  Like ledger-cli, ExLedger should require ALL currencies to independently
  balance within a transaction. A multi-currency transaction is only valid
  if each currency sums to zero.
  """

  describe "strict multi-currency balance validation" do
    test "rejects transaction where one currency doesn't balance" do
      # This is the exact case from the bug report
      # EUR balances (613.37 - 613.37 = 0)
      # USD does NOT balance (-716.93 + 716.93 - 716.93 = -716.93)
      input = """
      2025-05-17 * OVH
          Ertrag:SomeAccount    613.37 EUR
          Sonstiger Aufwand:Account1    -613.37 EUR
          Sonstiger Aufwand:Account2    -716.93 USD
          Sonstiger Aufwand:Account3    716.93 USD
          Sonstiger Aufwand:Account4    -716.93 USD
      """

      result = LedgerParser.parse_transaction(input)

      case result do
        {:ok, transaction} ->
          assert {:error, :unbalanced} = LedgerParser.validate_transaction(transaction)

        {:error, :unbalanced} ->
          # Parse-time validation caught it - acceptable
          assert true

        {:error, error} ->
          flunk("Expected :unbalanced error but got: #{inspect(error)}")
      end
    end

    test "accepts transaction where all currencies balance independently" do
      # Both EUR and USD balance to zero
      input = """
      2025-05-17 * Valid multi-currency
          Assets:EUR    100.00 EUR
          Expenses:EUR    -100.00 EUR
          Assets:USD    50.00 USD
          Expenses:USD    -50.00 USD
      """

      result = LedgerParser.parse_transaction(input)

      case result do
        {:ok, transaction} ->
          assert :ok = LedgerParser.validate_transaction(transaction)

        {:error, error} ->
          flunk("Transaction should be valid but got: #{inspect(error)}")
      end
    end

    test "rejects simple unbalanced multi-currency transaction" do
      # Neither currency balances
      input = """
      2024/07/21 Payment
          Assets:Account1    USD -75
          Expenses:Fees    USD 1
          Expenses:Other   CHF 66
      """

      result = LedgerParser.parse_transaction(input)

      case result do
        {:ok, transaction} ->
          assert {:error, :unbalanced} = LedgerParser.validate_transaction(transaction)

        {:error, :unbalanced} ->
          assert true

        {:error, error} ->
          flunk("Expected :unbalanced error but got: #{inspect(error)}")
      end
    end

    test "accepts balanced currency conversion with cost syntax" do
      # Currency conversion using @ cost syntax should balance
      # 100 USD @ 0.90 CHF/USD means 100 USD costs 90 CHF total
      input = """
      2024/12/31 Currency conversion
          Assets:USD    -100.00 USD @ 0.90 CHF
          Assets:CHF    90.00 CHF
      """

      result = LedgerParser.parse_transaction(input)

      case result do
        {:ok, transaction} ->
          assert :ok = LedgerParser.validate_transaction(transaction)

        {:error, error} ->
          flunk("Transaction with cost syntax should be valid but got: #{inspect(error)}")
      end
    end

    test "accepts balanced currency conversion with total cost syntax" do
      # Currency conversion using @@ total cost syntax
      # Buying 100 EUR for 110 USD
      input = """
      2024/12/31 Currency conversion
          Assets:EUR    100 EUR @@ 110 USD
          Assets:USD    -110 USD
      """

      result = LedgerParser.parse_transaction(input)

      case result do
        {:ok, transaction} ->
          assert :ok = LedgerParser.validate_transaction(transaction)

        {:error, error} ->
          flunk("Transaction with total cost syntax should be valid but got: #{inspect(error)}")
      end
    end
  end
end
