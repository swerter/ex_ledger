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
      input = """
      2024/01/01 Initial USD transaction
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Paypal USD Conversion @ 0.90
        Assets:Paypal:USD    USD -100.00
        Assets:Paypal:USD    CHF 90.00
      """

      {:ok, transactions, _accounts} = LedgerParser.parse_ledger(input)

      # Calculate balance
      balances = calculate_balances(transactions)

      # Expected: Assets:Paypal:USD should have CHF 90.00 and USD 0.00
      account_balance = Map.get(balances, "Assets:Paypal:USD")

      assert account_balance["CHF"] == 90.00, """
      Expected CHF 90.00 for Assets:Paypal:USD
      Got: #{inspect(account_balance)}

      To verify correct behavior, run:
      ledger -f test/fixtures/currency_conversion.ledger balance
      """

      assert account_balance["USD"] == 0.00, """
      Expected USD 0.00 for Assets:Paypal:USD after conversion
      Got: #{inspect(account_balance)}
      """
    end

    test "balance totals should account for all currencies separately" do
      input = """
      2024/01/01 Initial USD transaction
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Paypal USD Conversion @ 0.90
        Assets:Paypal:USD    USD -100.00
        Assets:Paypal:USD    CHF 90.00
      """

      {:ok, transactions, _accounts} = LedgerParser.parse_ledger(input)

      # Calculate total balance across all accounts by currency
      totals = calculate_total_balance(transactions)

      # Expected behavior (from ledger CLI):
      # - CHF total should be 90.00
      # - USD total should be -100.00
      # These don't balance to zero because they're different currencies

      assert Map.get(totals, "CHF") == 90.00, """
      FAILED: CHF total should be 90.00
      This shows exledger is not tracking CHF amounts correctly.
      """

      assert Map.get(totals, "USD") == -100.00, """
      FAILED: USD total should be -100.00
      """
    end

    test "complex multi-currency scenario from real ledger file" do
      # This simulates the pattern from bilanz-24.ledger
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
      2024/12/31 Paypal USD Conversion @ 0.88
        Assets:Paypal:USD    USD -150.00
        Assets:Paypal:USD    CHF 132.00

      ; Convert income account too
      2024/12/31 Income USD Conversion @ 0.88
        Income:Sales:USD     USD 150.00
        Income:Sales:USD     CHF -132.00
      """

      {:ok, transactions, _accounts} = LedgerParser.parse_ledger(input)

      # After conversion, the books should balance to zero in CHF terms
      balances = calculate_balances(transactions)
      totals = calculate_total_balance(transactions)

      # Assets should be CHF 132.00, USD 0.00
      assets = Map.get(balances, "Assets:Paypal:USD")

      assert assets["CHF"] == 132.00,
             "Assets account should have CHF 132.00 after conversion, got: #{inspect(assets)}"

      assert assets["USD"] == 0.00,
             "Assets account should have USD 0.00 after conversion, got: #{inspect(assets)}"

      # Income should be CHF -132.00, USD 0.00
      income = Map.get(balances, "Income:Sales:USD")

      assert income["CHF"] == -132.00,
             "Income account should have CHF -132.00 after conversion, got: #{inspect(income)}"

      assert income["USD"] == 0.00,
             "Income account should have USD 0.00 after conversion, got: #{inspect(income)}"

      # Total should balance to zero in CHF
      assert Map.get(totals, "CHF") == 0.00, """
      FAILED: Total CHF balance should be zero (balanced books)
      This is the main issue seen in the bilanz-24.ledger comparison.
      """

      # Total USD should also be zero after full conversion
      assert Map.get(totals, "USD") == 0.00, """
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
          current_amount = Map.get(current, currency, 0.0)
          updated = Map.put(current, currency, current_amount + amount)
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

          current_amount = Map.get(acc, currency, 0.0)
          Map.put(acc, currency, current_amount + amount)
      end
    end)
  end
end
