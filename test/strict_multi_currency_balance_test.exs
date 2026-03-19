defmodule ExLedger.StrictMultiCurrencyBalanceTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser
  import ExLedger.TransactionHelpers

  @moduledoc """
  Tests for multi-currency balance validation.

  Like ledger-cli, ExLedger allows multi-currency transactions where each currency
  is tracked separately. Currencies don't need to independently balance to zero -
  they can have non-zero totals which ledger tracks separately.

  Single-currency transactions still must balance to zero.
  """

  describe "multi-currency balance validation" do
    test "accepts multi-currency transaction with non-zero currency totals" do
      # This is a valid multi-currency transaction - ledger tracks each currency separately
      # EUR: 613.37 - 613.37 + 0 - 716.93 = non-zero (but that's OK for multi-currency)
      # Actually let's simplify the test case
      input = """
      2025-05-17 * OVH
          Ertrag:SomeAccount    613.37 EUR
          Sonstiger Aufwand:Account2    -716.93 USD
      """

      transaction = parse_transaction!(input)
      assert :ok = LedgerParser.validate_transaction(transaction)
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

      transaction = parse_transaction!(input)
      assert :ok = LedgerParser.validate_transaction(transaction)
    end

    test "accepts multi-currency transaction where currencies don't balance" do
      # Neither currency balances - but this is fine for multi-currency
      input = """
      2024/07/21 Payment
          Assets:Account1    USD -75
          Expenses:Fees    USD 1
          Expenses:Other   CHF 66
      """

      transaction = parse_transaction!(input)
      assert :ok = LedgerParser.validate_transaction(transaction)
    end

    test "rejects unbalanced single-currency transaction" do
      # Single-currency transactions must balance
      input = """
      2024/07/21 Payment
          Assets:Account1    USD -75
          Expenses:Fees    USD 1
          Expenses:Other   USD 50
      """

      # USD: -75 + 1 + 50 = -24 (not balanced)
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

      transaction = parse_transaction!(input)
      assert :ok = LedgerParser.validate_transaction(transaction)
    end

    test "accepts balanced currency conversion with total cost syntax" do
      # Currency conversion using @@ total cost syntax
      # Buying 100 EUR for 110 USD
      input = """
      2024/12/31 Currency conversion
          Assets:EUR    100 EUR @@ 110 USD
          Assets:USD    -110 USD
      """

      transaction = parse_transaction!(input)
      assert :ok = LedgerParser.validate_transaction(transaction)
    end
  end
end
