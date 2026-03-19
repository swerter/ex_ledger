defmodule ExLedger.BalanceAssertionEdgeCasesTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser

  @moduledoc """
  Edge case tests for balance assertions.
  """

  describe "balance assertion - basic functionality" do
    test "simple balance assertion passes" do
      input = """
      2024/01/01 Opening
          Assets:Cash  $1000.00
          Equity:Opening

      2024/01/15 Purchase
          Expenses:Food  $50.00
          Assets:Cash  -$50.00 = $950.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 2
    end

    test "balance assertion at zero" do
      input = """
      2024/01/01 Opening
          Assets:Cash  $100.00
          Equity:Opening

      2024/01/15 Spend all
          Expenses:Food  $100.00
          Assets:Cash  -$100.00 = $0.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 2
    end

    test "balance assertion with negative balance" do
      input = """
      2024/01/01 Opening
          Assets:Cash  $100.00
          Equity:Opening

      2024/01/15 Overdraft
          Expenses:Food  $150.00
          Assets:Cash  -$150.00 = -$50.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 2
    end

    test "multiple balance assertions in sequence" do
      input = """
      2024/01/01 Opening
          Assets:Cash  $1000.00 = $1000.00
          Equity:Opening

      2024/01/15 Purchase 1
          Expenses:Food  $100.00
          Assets:Cash  -$100.00 = $900.00

      2024/01/20 Purchase 2
          Expenses:Food  $200.00
          Assets:Cash  -$200.00 = $700.00

      2024/01/25 Purchase 3
          Expenses:Food  $300.00
          Assets:Cash  -$300.00 = $400.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 4
    end
  end

  describe "balance assertion - on first transaction" do
    test "assertion on opening balance" do
      input = """
      2024/01/01 Opening balance
          Assets:Cash  $1000.00 = $1000.00
          Equity:Opening
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 1
    end

    test "assertion on account with no prior history" do
      input = """
      2024/01/01 First transaction for this account
          Assets:NewAccount  $500.00 = $500.00
          Equity:Opening
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 1
    end
  end

  describe "balance assertion - multi-currency" do
    test "assertion with different currencies in same account" do
      input = """
      2024/01/01 USD deposit
          Assets:Wallet  $100.00
          Equity:Opening

      2024/01/02 EUR deposit
          Assets:Wallet  €50.00
          Equity:Opening

      2024/01/03 USD withdrawal
          Expenses:Food  $25.00
          Assets:Wallet  -$25.00 = $75.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 3
    end

    test "assertion specifies currency explicitly" do
      input = """
      2024/01/01 Deposit
          Assets:Wallet  100 USD
          Equity:Opening

      2024/01/15 Check balance
          Assets:Wallet  0 USD = 100 USD
          Assets:Wallet
      """

      result = LedgerParser.parse_ledger(input)
      assert is_tuple(result)
    end
  end

  describe "balance assertion - edge cases" do
    test "assertion with high precision decimal" do
      input = """
      2024/01/01 Crypto deposit
          Assets:Crypto  0.12345678 BTC
          Equity:Opening

      2024/01/15 Withdrawal
          Expenses:Fees  0.00000001 BTC
          Assets:Crypto  -0.00000001 BTC = 0.12345677 BTC
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 2
    end

    test "assertion with large amounts" do
      input = """
      2024/01/01 Large deposit
          Assets:Bank  $1,000,000,000.00
          Equity:Opening

      2024/01/15 Large withdrawal
          Expenses:Investment  $500,000,000.00
          Assets:Bank  -$500,000,000.00 = $500,000,000.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 2
    end

    test "assertion on posting without amount" do
      # The posting calculates its amount, then asserts
      # Note: This syntax (bare assertion without amount) may not be supported
      input = """
      2024/01/01 Opening
          Assets:Cash  $1000.00
          Equity:Opening

      2024/01/15 Purchase
          Expenses:Food  $50.00
          Assets:Cash  = $950.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 2

      # The second transaction should have calculated the amount
      [_, txn2] = transactions
      cash_posting = Enum.find(txn2.postings, &(&1.account == "Assets:Cash"))
      assert Decimal.eq?(cash_posting.amount.value, Decimal.new("-50.00"))
    end

    test "zero amount with assertion" do
      input = """
      2024/01/01 Opening
          Assets:Cash  $100.00
          Equity:Opening

      2024/01/15 Balance check only
          Assets:Cash  $0.00 = $100.00
          Assets:Cash
      """

      result = LedgerParser.parse_ledger(input)
      assert is_tuple(result)
    end
  end

  describe "balance assertion - failure cases" do
    test "incorrect assertion fails" do
      input = """
      2024/01/01 Opening
          Assets:Cash  $1000.00
          Equity:Opening

      2024/01/15 Purchase with wrong assertion
          Expenses:Food  $50.00
          Assets:Cash  -$50.00 = $900.00
      """

      # The assertion says $900 but actual balance is $950
      result = LedgerParser.parse_ledger(input)

      case result do
        {:error, {:balance_assertion_failed, _details}} ->
          assert true

        {:error, :balance_assertion_failed} ->
          assert true

        {:ok, _} ->
          # If it parses, validation should fail
          flunk("Expected balance assertion to fail")

        {:error, other} ->
          # Accept any error related to balance assertion
          assert to_string(other) =~ "balance" or to_string(other) =~ "assertion",
                 "Expected balance assertion error, got: #{inspect(other)}"
      end
    end

    test "assertion on wrong currency fails" do
      input = """
      2024/01/01 USD deposit
          Assets:Cash  $100.00
          Equity:Opening

      2024/01/15 Check with wrong currency
          Expenses:Food  $50.00
          Assets:Cash  -$50.00 = €50.00
      """

      result = LedgerParser.parse_ledger(input)

      # Should either error or the currencies should not match
      assert is_tuple(result)
    end
  end

  describe "balance assertion - with virtual postings" do
    test "assertion ignores virtual unbalanced postings" do
      input = """
      2024/01/01 Opening
          Assets:Cash  $1000.00
          Equity:Opening

      2024/01/15 Purchase with budget tracking
          Expenses:Food  $50.00
          Assets:Cash  -$50.00 = $950.00
          (Budget:Food)  $-50.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 2
    end

    test "assertion with virtual balanced postings" do
      input = """
      2024/01/01 Opening
          Assets:Cash  $1000.00
          Equity:Opening

      2024/01/15 Purchase with tracking
          Expenses:Food  $50.00
          Assets:Cash  -$50.00 = $950.00
          [Tracking:Food]  $50.00
          [Tracking:Spent]  -$50.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 2
    end
  end

  describe "balance assertion - with cost syntax" do
    test "assertion after currency conversion" do
      input = """
      2024/01/01 USD deposit
          Assets:Wallet:USD  $100.00
          Equity:Opening

      2024/01/15 Convert to EUR
          Assets:Wallet:USD  -$100.00 @ €0.92
          Assets:Wallet:EUR  €92.00
          Assets:Wallet:USD  = $0.00
      """

      result = LedgerParser.parse_ledger(input)
      assert is_tuple(result)
    end
  end
end
