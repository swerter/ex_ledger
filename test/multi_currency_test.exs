defmodule ExLedger.MultiCurrencyTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser

  @moduledoc """
  Tests for multi-currency transactions and currency conversions.

  Covers:
  - Currency conversion with cost syntax (@ and @@)
  - Multi-currency balance calculations
  - Account balances with multiple currencies
  """

  describe "currency conversion transactions" do
    test "handles same account with different currencies in one transaction" do
      input = """
      2024/01/01 Initial USD transaction
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Paypal USD Conversion
        Assets:Paypal:USD    -100.00 USD @ 0.90 CHF
        Assets:Paypal:USD    CHF 90.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)
      balances = calculate_balances(transactions)

      account_balance = Map.get(balances, "Assets:Paypal:USD")

      assert Decimal.eq?(account_balance["CHF"], Decimal.from_float(90.00)), """
      Expected CHF 90.00 for Assets:Paypal:USD
      Got: #{inspect(account_balance)}
      """

      assert Decimal.eq?(account_balance["USD"], Decimal.new(0)), """
      Expected USD 0.00 for Assets:Paypal:USD after conversion
      Got: #{inspect(account_balance)}
      """
    end

    test "balance totals should account for all currencies separately" do
      input = """
      2024/01/01 Initial USD transaction
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Paypal USD Conversion
        Assets:Paypal:USD    -100.00 USD @ 0.90 CHF
        Assets:Paypal:USD    CHF 90.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)
      totals = calculate_total_balance(transactions)

      assert Decimal.eq?(Map.get(totals, "CHF"), Decimal.from_float(90.00)), """
      FAILED: CHF total should be 90.00
      """

      assert Decimal.eq?(Map.get(totals, "USD"), Decimal.from_float(-100.00)), """
      FAILED: USD total should be -100.00
      """
    end

    test "complex multi-currency scenario with year-end conversion" do
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

      # Total should balance to zero in both currencies after full conversion
      assert Decimal.eq?(Map.get(totals, "CHF"), Decimal.new(0)),
             "Total CHF balance should be zero (balanced books)"

      assert Decimal.eq?(Map.get(totals, "USD"), Decimal.new(0)),
             "Total USD balance should be zero after conversion"
    end
  end

  describe "balance() function with multi-currency accounts" do
    test "currency conversion transaction returns separate currency balances" do
      input = """
      2024/01/01 Initial USD transaction
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Paypal USD Conversion
        Assets:Paypal:USD    -100.00 USD @ 0.90 CHF
        Assets:Paypal:USD    CHF 90.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)
      balances = LedgerParser.balance(transactions)

      assets_balance = Map.get(balances, "Assets:Paypal:USD")

      chf_amount = Enum.find(assets_balance, fn a -> a.currency == "CHF" end)
      usd_amount = Enum.find(assets_balance, fn a -> a.currency == "USD" end)

      assert Decimal.eq?(chf_amount.amount, Decimal.from_float(90.0)), """
      Expected CHF balance to be 90.0 but got #{inspect(chf_amount)}
      Full balance: #{inspect(assets_balance)}
      """

      assert Decimal.eq?(usd_amount.amount, Decimal.new(0)), """
      Expected USD balance to be 0.0 but got #{inspect(usd_amount)}
      Full balance: #{inspect(assets_balance)}
      """
    end

    test "balance_report output matches expected format" do
      input = """
      2024/01/01 Paypal payment
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Paypal USD Conversion
        Assets:Paypal:USD    -100.00 USD @ 0.90 CHF
        Assets:Paypal:USD    CHF 90.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)
      report = LedgerParser.balance_report(transactions)

      # Expected output:
      #        CHF 90.00  Assets:Paypal:USD
      #      USD -100.00  Income:Sales:USD

      assert report =~ "CHF 90.00",
             "Output should contain 'CHF 90.00' but got:\n#{report}"

      refute report =~ "USD -10.00",
             "Output should NOT show incorrect 'USD -10.00':\n#{report}"
    end

    test "complete conversion balances to zero" do
      input = """
      2024/01/01 Revenue in USD
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Convert asset USD to CHF
        Assets:Paypal:USD    -100.00 USD @ 0.90 CHF
        Assets:Paypal:USD    CHF 90.00

      2024/12/31 Convert income USD to CHF
        Income:Sales:USD     100.00 USD @ 0.90 CHF
        Income:Sales:USD     CHF -90.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)
      report = LedgerParser.balance_report(transactions)

      assert report =~ ~r/CHF\s+0\.00/,
             "CHF should balance to 0.00 after conversion:\n#{report}"

      assert report =~ ~r/USD\s+0\.00/,
             "USD should balance to 0.00 after conversion:\n#{report}"
    end
  end

  # Helper functions to calculate balances (track each currency separately)
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
