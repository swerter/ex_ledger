defmodule ExLedger.BalanceMultiCurrencyTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser

  @moduledoc """
  Tests demonstrating bugs in multi-currency balance calculations.

  ROOT CAUSE: lib/ex_ledger/ledger_parser.ex:2953-2963

  The balance() function incorrectly handles accounts with multiple currencies:

  ```elixir
  def balance(transactions) when is_list(transactions) do
    transactions
    |> regular_postings()
    |> Enum.group_by(fn posting -> posting.account end)
    |> Enum.map(fn {account, postings} ->
      total = postings |> Enum.map(& &1.amount.value) |> Enum.sum()
      currency = hd(postings).amount.currency  # <-- BUG: Takes currency from FIRST posting only!
      {account, %{value: total, currency: currency}}
    end)
    |> Map.new()
  end
  ```

  When an account has postings in multiple currencies (like currency conversion transactions),
  this function:
  1. Sums ALL amount values together (regardless of currency)
  2. Takes the currency from the FIRST posting only

  This causes incorrect output like:
  - Expected: CHF 90.00 (after converting USD -100 to CHF 90)
  - Actual:   USD -10.00 (sum of -100 + 90 = -10, using first posting's USD)

  Compare with ledger CLI which correctly tracks currencies separately.
  """

  describe "balance() function bug with multi-currency accounts" do
    @tag :failing
    test "currency conversion transaction - simple case" do
      input = """
      2024/01/01 Initial USD transaction
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Paypal USD Conversion @ 0.90
        Assets:Paypal:USD    USD -100.00
        Assets:Paypal:USD    CHF 90.00
      """

      {:ok, transactions, _accounts} = LedgerParser.parse_ledger(input)
      balances = LedgerParser.balance(transactions)

      # Expected: Should track currencies separately
      #   - USD: 100 - 100 = 0
      #   - CHF: 90

      assets_balance = Map.get(balances, "Assets:Paypal:USD")

      # After fix: Returns [%{amount: 90.0, currency: "CHF"}, %{amount: 0.0, currency: "USD"}]

      chf_amount = Enum.find(assets_balance, fn a -> a.currency == "CHF" end)
      usd_amount = Enum.find(assets_balance, fn a -> a.currency == "USD" end)

      assert chf_amount.amount == 90.0, """
      Expected CHF balance to be 90.0 but got #{inspect(chf_amount)}

      Full balance: #{inspect(assets_balance)}

      Run these commands to compare:
        ledger -f test/fixtures/currency_conversion.ledger balance
        ./bin/exledger -f test/fixtures/currency_conversion.ledger balance
      """

      assert usd_amount.amount == 0.0, """
      Expected USD balance to be 0.0 but got #{inspect(usd_amount)}

      After the conversion transaction, USD should net to zero.
      Full balance: #{inspect(assets_balance)}
      """
    end

    @tag :failing
    test "balance report output matches ledger CLI" do
      input = """
      2024/01/01 Paypal payment
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Paypal USD Conversion @ 0.90
        Assets:Paypal:USD    USD -100.00
        Assets:Paypal:USD    CHF 90.00
      """

      {:ok, transactions, _accounts} = LedgerParser.parse_ledger(input)
      report = LedgerParser.balance_report(transactions)

      # Expected output (from ledger CLI):
      #        CHF 90.00  Assets:Paypal:USD
      #      USD -100.00  Income:Sales:USD
      # --------------------
      #        CHF 90.00
      #      USD -100.00

      # Actual buggy output (from exledger):
      #        USD -10.00  Assets:Paypal:USD
      #      USD -100.00  Income:Sales:USD
      # --------------------
      #       USD -110.00

      assert report =~ "CHF 90.00", """
      BUG DEMONSTRATED: Output should contain 'CHF 90.00' but doesn't.

      exledger output:
      #{report}

      Compare with ledger CLI:
      $ ledger -f test/fixtures/currency_conversion.ledger balance
      """

      refute report =~ "USD -10.00", """
      BUG DEMONSTRATED: Output incorrectly shows 'USD -10.00'

      This is the result of summing -100 (USD) + 90 (CHF) = -10
      and incorrectly treating the result as USD.

      exledger output:
      #{report}
      """
    end

    @tag :failing
    test "complete currency conversion should balance to zero in CHF" do
      # This simulates a complete year-end conversion where all USD is converted to CHF
      input = """
      2024/01/01 Revenue in USD
        Assets:Paypal:USD    USD 100.00
        Income:Sales:USD     USD -100.00

      2024/12/31 Convert asset USD to CHF @ 0.90
        Assets:Paypal:USD    USD -100.00
        Assets:Paypal:USD    CHF 90.00

      2024/12/31 Convert income USD to CHF @ 0.90
        Income:Sales:USD     USD 100.00
        Income:Sales:USD     CHF -90.00
      """

      {:ok, transactions, _accounts} = LedgerParser.parse_ledger(input)
      report = LedgerParser.balance_report(transactions)

      # After full conversion:
      # - All USD should be at 0
      # - CHF should balance to 0 (balanced books)
      # Expected total: CHF 0.00 and USD 0.00

      # Check that CHF balances to zero
      assert report =~ ~r/CHF\s+0\.00/, """
      CHF should balance to 0.00 after conversion.

      exledger output:
      #{report}
      """

      # Check that USD balances to zero
      assert report =~ ~r/USD\s+0\.00/, """
      USD should balance to 0.00 after conversion.

      exledger output:
      #{report}

      Compare with ledger CLI for correct behavior.
      """
    end
  end

  describe "comparison with actual bilanz-24.ledger file" do
    @tag :skip
    @tag :integration
    test "matches ledger CLI output for bilanz-24.ledger" do
      # This test requires the actual file from the user's system
      ledger_file = "../accountguru/repo/admin_accountguru_com/2025/bilanz-24.ledger"

      if File.exists?(ledger_file) do
        # Get expected output from ledger CLI
        {ledger_output, 0} = System.cmd("ledger", ["-f", ledger_file, "balance"])

        # Get actual output from exledger
        {:ok, content} = File.read(ledger_file)
        {:ok, transactions, _accounts} = LedgerParser.parse_ledger(content)
        exledger_output = LedgerParser.balance_report(transactions)

        # Key differences to check:
        # 1. Total should be 0, not multi-currency imbalance
        assert exledger_output =~ ~r/----\s*\n\s*0\s*\n/, """
        exledger does not balance to zero like ledger CLI does.

        Ledger CLI shows balanced books (total = 0)
        exledger shows: #{exledger_output |> String.split("----") |> List.last()}
        """

        # 2. Account names should match
        # 3. Currency amounts should match

        IO.puts("Expected (ledger CLI):\n#{ledger_output}")
        IO.puts("Actual (exledger):\n#{exledger_output}")
      else
        IO.puts("Skipping: #{ledger_file} not found")
        :ok
      end
    end
  end
end
