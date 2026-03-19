defmodule ExLedger.CurrencyConversionTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser

  @moduledoc """
  Tests to demonstrate inconsistencies between exledger and ledger CLI
  when handling multi-currency transactions and currency conversions.

  These tests currently FAIL and demonstrate bugs that need to be fixed.
  """

  describe "currency conversion transactions" do
    test "handles same account with different currencies in one transaction" do
      # Currency conversions must use cost syntax to balance properly
      # Using per-unit cost syntax: @ rate
      input = """
      2024/01/01 Initial USD transaction
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Paypal USD Conversion
        Assets:Paypal:USD    -100.00 USD @ 0.90 CHF
        Assets:Paypal:USD    CHF 90.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      # Calculate balance
      balances = calculate_balances(transactions)

      # Expected: Assets:Paypal:USD should have CHF 90.00 and USD 0.00
      account_balance = Map.get(balances, "Assets:Paypal:USD")

      assert Decimal.eq?(account_balance["CHF"], Decimal.from_float(90.00)), """
      Expected CHF 90.00 for Assets:Paypal:USD
      Got: #{inspect(account_balance)}

      To verify correct behavior, run:
      ledger -f test/fixtures/currency_conversion.ledger balance
      """

      assert Decimal.eq?(account_balance["USD"], Decimal.new(0)), """
      Expected USD 0.00 for Assets:Paypal:USD after conversion
      Got: #{inspect(account_balance)}
      """
    end

    test "balance totals should account for all currencies separately" do
      # Currency conversions must use cost syntax to balance properly
      input = """
      2024/01/01 Initial USD transaction
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Paypal USD Conversion
        Assets:Paypal:USD    -100.00 USD @ 0.90 CHF
        Assets:Paypal:USD    CHF 90.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      # Calculate total balance across all accounts by currency
      totals = calculate_total_balance(transactions)

      # Expected behavior (from ledger CLI):
      # - CHF total should be 90.00
      # - USD total should be -100.00
      # These don't balance to zero because they're different currencies

      assert Decimal.eq?(Map.get(totals, "CHF"), Decimal.from_float(90.00)), """
      FAILED: CHF total should be 90.00
      This shows exledger is not tracking CHF amounts correctly.
      """

      assert Decimal.eq?(Map.get(totals, "USD"), Decimal.from_float(-100.00)), """
      FAILED: USD total should be -100.00
      """
    end

    test "complex multi-currency scenario from real ledger file" do
      # This simulates the pattern from bilanz-24.ledger
      # Currency conversions must use cost syntax to balance properly
      input = """
      ; Initial USD revenue
      2024/01/01 Paypal payment
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      ; More USD transactions
      2024/06/01 Paypal payment
        Assets:Paypal:USD    USD 50.00
        Income:Sales:USD     USD -50.00

      ; Year-end currency conversion
      2024/12/31 Paypal USD Conversion
        Assets:Paypal:USD    -150.00 USD @ 0.88 CHF
        Assets:Paypal:USD    CHF 132.00

      ; Convert income account too
      2024/12/31 Income USD Conversion
        Income:Sales:USD     150.00 USD @ 0.88 CHF
        Income:Sales:USD     CHF -132.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      # After conversion, the books should balance to zero in CHF terms
      balances = calculate_balances(transactions)
      totals = calculate_total_balance(transactions)

      # Assets should be CHF 132.00, USD 0.00
      assets = Map.get(balances, "Assets:Paypal:USD")

      assert Decimal.eq?(assets["CHF"], Decimal.from_float(132.00)),
             "Assets account should have CHF 132.00 after conversion, got: #{inspect(assets)}"

      assert Decimal.eq?(assets["USD"], Decimal.new(0)),
             "Assets account should have USD 0.00 after conversion, got: #{inspect(assets)}"

      # Income should be CHF -132.00, USD 0.00
      income = Map.get(balances, "Income:Sales:USD")

      assert Decimal.eq?(income["CHF"], Decimal.from_float(-132.00)),
             "Income account should have CHF -132.00 after conversion, got: #{inspect(income)}"

      assert Decimal.eq?(income["USD"], Decimal.new(0)),
             "Income account should have USD 0.00 after conversion, got: #{inspect(income)}"

      # Total should balance to zero in CHF
      assert Decimal.eq?(Map.get(totals, "CHF"), Decimal.new(0)), """
      FAILED: Total CHF balance should be zero (balanced books)
      This is the main issue seen in the bilanz-24.ledger comparison.
      """

      # Total USD should also be zero after full conversion
      assert Decimal.eq?(Map.get(totals, "USD"), Decimal.new(0)), """
      FAILED: Total USD balance should be zero after conversion
      """
    end
  end

  # Helper functions to calculate balances
  defp calculate_balances(transactions) do
    transactions
    |> Enum.flat_map(fn tx -> tx.postings end)
    |> Enum.reduce(%{}, fn posting, acc ->
      account = posting.account

      case posting.amount do
        nil ->
          acc

        amount_map ->
          currency = amount_map.currency
          amount = amount_map.value

          current = Map.get(acc, account, %{})
          current_amount = Map.get(current, currency, Decimal.new(0))
          updated = Map.put(current, currency, Decimal.add(current_amount, amount))
          Map.put(acc, account, updated)
      end
    end)
  end

  defp calculate_total_balance(transactions) do
    transactions
    |> Enum.flat_map(fn tx -> tx.postings end)
    |> Enum.reduce(%{}, fn posting, acc ->
      case posting.amount do
        nil ->
          acc

        amount_map ->
          currency = amount_map.currency
          amount = amount_map.value

          current_amount = Map.get(acc, currency, Decimal.new(0))
          Map.put(acc, currency, Decimal.add(current_amount, amount))
      end
    end)
  end
end
