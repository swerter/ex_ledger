defmodule ExLedger.BalanceAssertionsTest do
  use ExUnit.Case, async: true

  alias ExLedger.LedgerParser
  alias ExLedger.Parser.BalanceAssertions

  describe "parsing balance assertions" do
    test "parses simple assertion syntax with trailing currency" do
      input = """
      2026/09/30 Balance Check
          Assets:Bank:Checking  0 = 45000.00 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: [transaction]}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      [checking_posting, _] = transaction.postings

      assert Decimal.eq?(checking_posting.assertion.value, Decimal.from_float(45000.00))
      assert checking_posting.assertion.currency == "CHF"
    end

    test "parses assertion with leading currency" do
      input = """
      2026/09/30 Balance Check
          Assets:Bank:Checking  0 = $45000.00
          Equity:Adjustments  0
      """

      {:ok, %{transactions: [transaction]}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      [checking_posting, _] = transaction.postings

      assert Decimal.eq?(checking_posting.assertion.value, Decimal.from_float(45000.00))
      assert checking_posting.assertion.currency == "$"
    end

    test "parses assertion with non-zero posting amount" do
      input = """
      2026/09/30 Deposit with check
          Assets:Bank:Checking  100 CHF = 45100.00 CHF
          Income:Salary  -100 CHF
      """

      {:ok, %{transactions: [transaction]}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      [checking_posting, _] = transaction.postings

      assert Decimal.eq?(checking_posting.amount.value, Decimal.new(100))
      assert checking_posting.amount.currency == "CHF"

      assert Decimal.eq?(checking_posting.assertion.value, Decimal.from_float(45100.00))
      assert checking_posting.assertion.currency == "CHF"
    end

    test "posting without assertion has nil assertion field" do
      input = """
      2026/09/30 Regular transaction
          Assets:Bank:Checking  100 CHF
          Income:Salary  -100 CHF
      """

      {:ok, %{transactions: [transaction]}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      [checking_posting, salary_posting] = transaction.postings

      assert checking_posting.assertion == nil
      assert salary_posting.assertion == nil
    end
  end

  describe "validating balance assertions" do
    test "validates correct assertion" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Check Balance
          Assets:Cash  0 = 100 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end

    test "validates assertion after multiple transactions" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/10 Purchase
          Expenses:Food  20 CHF
          Assets:Cash  -20 CHF

      2026/01/15 Check Balance
          Assets:Cash  0 = 80 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end

    test "fails on incorrect assertion" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Wrong Balance Check
          Assets:Cash  0 = 200 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert {:error, [failure]} = BalanceAssertions.validate_assertions(transactions)

      assert failure.account == "Assets:Cash"
      assert Decimal.eq?(failure.expected.value, Decimal.new(200))
      assert Decimal.eq?(failure.actual.value, Decimal.new(100))
      assert failure.transaction_date == ~D[2026-01-15]
      assert failure.transaction_payee == "Wrong Balance Check"
    end

    test "reports multiple failures" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Assets:Bank  500 CHF
          Equity:Opening  -600 CHF

      2026/01/15 Wrong Balance Check
          Assets:Cash  0 = 200 CHF
          Assets:Bank  0 = 1000 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert {:error, failures} = BalanceAssertions.validate_assertions(transactions)

      assert length(failures) == 2
      accounts = Enum.map(failures, & &1.account) |> Enum.sort()
      assert accounts == ["Assets:Bank", "Assets:Cash"]
    end

    test "skip_assertions option bypasses validation" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Wrong Balance Check
          Assets:Cash  0 = 200 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions, skip_assertions: true)
    end
  end

  describe "bare amount inheriting currency from assertion" do
    test "bare zero inherits currency from trailing currency assertion" do
      # When posting amount is bare "0" but assertion has a currency,
      # the assertion should check the correct currency bucket
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Check Balance
          Assets:Cash  0 = 100 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end

    test "bare zero inherits currency from leading currency assertion" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  $100.00
          Equity:Opening  -$100.00

      2026/01/15 Check Balance
          Assets:Cash  0 = $100.00
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end

    test "bare zero with assertion fails when balance is wrong" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Wrong Balance Check
          Assets:Cash  0 = 200 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert {:error, [failure]} = BalanceAssertions.validate_assertions(transactions)

      assert failure.account == "Assets:Cash"
      assert Decimal.eq?(failure.expected.value, Decimal.new(200))
      assert Decimal.eq?(failure.actual.value, Decimal.new(100))
    end

    test "bare zero is treated as zero of assertion currency" do
      # When there's no prior balance in the currency, bare 0 with assertion should
      # add 0 to that currency's balance (not to "default" bucket)
      input = """
      2026/01/15 Assert Zero Balance
          Assets:NewAccount  0 = 0 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end

    test "bare zero assertion fails when account has unexpected balance" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  50 CHF
          Equity:Opening  -50 CHF

      2026/01/15 Assert Zero Balance (should fail)
          Assets:Cash  0 = 0 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert {:error, [failure]} = BalanceAssertions.validate_assertions(transactions)

      assert failure.account == "Assets:Cash"
      assert Decimal.eq?(failure.expected.value, Decimal.new(0))
      assert Decimal.eq?(failure.actual.value, Decimal.new(50))
    end

    test "bare non-zero amount inherits currency from assertion" do
      # Even non-zero bare amounts should inherit currency from assertion
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Add and Check
          Assets:Cash  50 = 150 CHF
          Expenses:Misc  -50 CHF
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end

    test "explicit amount currency takes precedence over assertion currency" do
      # When amount has explicit currency, it should NOT inherit from assertion.
      # Here we add 0 CHF but assert USD balance - the 0 should go to CHF bucket,
      # not USD bucket (even though assertion is in USD).
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 USD
          Equity:Opening  -100 USD

      2026/01/15 Add CHF but assert USD
          Assets:Cash  0 CHF = 100 USD
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      # This should pass: 0 is added to CHF bucket (explicit), assertion checks USD bucket (100)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end
  end

  describe "multi-currency assertions" do
    test "validates assertion for specific currency only" do
      input = """
      2026/01/01 USD Deposit
          Assets:MultiCurrency  100 USD
          Income:Foreign  -100 USD

      2026/01/02 CHF Deposit
          Assets:MultiCurrency  50 CHF
          Income:Local  -50 CHF

      2026/01/15 Check USD Balance
          Assets:MultiCurrency  0 = 100 USD
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end

    test "fails when currency balance is wrong" do
      input = """
      2026/01/01 USD Deposit
          Assets:MultiCurrency  100 USD
          Income:Foreign  -100 USD

      2026/01/15 Check USD Balance
          Assets:MultiCurrency  0 = 150 USD
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert {:error, [failure]} = BalanceAssertions.validate_assertions(transactions)

      assert Decimal.eq?(failure.expected.value, Decimal.new(150))
      assert Decimal.eq?(failure.actual.value, Decimal.new(100))
    end
  end

  describe "virtual postings with assertions" do
    test "virtual unbalanced posting with assertion checks balance without affecting it" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Transaction with virtual note
          Assets:Cash  -50 CHF
          Expenses:Food  50 CHF
          (Budget:Food)  0 = 0 CHF
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end

    test "virtual unbalanced posting assertion fails when expected balance is wrong" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Transaction with wrong virtual assertion
          Assets:Cash  -50 CHF
          Expenses:Food  50 CHF
          (Budget:Food)  0 = 999 CHF
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert {:error, [failure]} = BalanceAssertions.validate_assertions(transactions)
      assert failure.account == "Budget:Food"
      assert Decimal.eq?(failure.expected.value, Decimal.new(999))
    end

    test "virtual unbalanced posting without assertion is skipped" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Transaction with virtual note
          Assets:Cash  -50 CHF
          Expenses:Food  50 CHF
          (Budget:Food)  50 CHF
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end
  end

  describe "postings with elided amounts" do
    test "posting with elided amount does not affect balance" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening

      2026/01/15 Check Balance
          Assets:Cash  0 = 100 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end

    test "posting with nil amount is handled correctly" do
      # Directly test validate_transaction_assertions with a nil amount posting
      transaction = %{
        kind: :regular,
        date: ~D[2026-01-15],
        payee: "Test",
        postings: [
          %{
            account: "Assets:Cash",
            amount: nil,
            assertion: nil,
            virtual: false,
            must_balance: false
          }
        ]
      }

      {balances, failures} =
        BalanceAssertions.validate_transaction_assertions(transaction, %{}, [])

      assert balances == %{}
      assert failures == []
    end
  end

  describe "assertions with cost basis" do
    test "validates assertion considering per-unit cost" do
      input = """
      2026/01/01 Buy Stock
          Assets:Investments  10 AAPL @ 150 USD
          Assets:Cash  -1500 USD

      2026/01/15 Check Investment Value
          Assets:Investments  0 = 10 AAPL
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert :ok = BalanceAssertions.validate_assertions(transactions)
    end
  end

  describe "integration with parse_ledger" do
    test "parse_ledger validates assertions by default" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Wrong Balance Check
          Assets:Cash  0 = 200 CHF
          Equity:Adjustments  0
      """

      assert {:error, {:balance_assertion_failed, failures}} = LedgerParser.parse_ledger(input)
      assert length(failures) == 1
    end

    test "parse_ledger with skip_assertions option succeeds" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Wrong Balance Check
          Assets:Cash  0 = 200 CHF
          Equity:Adjustments  0
      """

      assert {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      assert length(transactions) == 2
    end

    test "parse_ledger succeeds with valid assertions" do
      input = """
      2026/01/01 Opening Balance
          Assets:Cash  100 CHF
          Equity:Opening  -100 CHF

      2026/01/15 Correct Balance Check
          Assets:Cash  0 = 100 CHF
          Equity:Adjustments  0
      """

      assert {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)
      assert length(transactions) == 2
    end
  end

  describe "format_failures/1" do
    test "formats a single failure" do
      failure = %{
        account: "Assets:Cash",
        expected: %{value: 200.0, currency: "CHF", currency_position: nil},
        actual: %{value: 100.0, currency: "CHF", currency_position: nil},
        transaction_date: ~D[2026-01-15],
        transaction_payee: "Balance Check",
        source_file: "main.ledger",
        source_line: 10
      }

      output = BalanceAssertions.format_failures([failure])

      assert output =~ "Balance assertion failed for account 'Assets:Cash'"
      assert output =~ "Expected: 200.00 CHF"
      assert output =~ "Actual:   100.00 CHF"
      assert output =~ "Transaction: 2026-01-15 Balance Check"
      assert output =~ "File: main.ledger:10"
    end

    test "formats multiple failures" do
      failures = [
        %{
          account: "Assets:Cash",
          expected: %{value: 200.0, currency: "CHF", currency_position: nil},
          actual: %{value: 100.0, currency: "CHF", currency_position: nil},
          transaction_date: ~D[2026-01-15],
          transaction_payee: "Check 1",
          source_file: nil,
          source_line: nil
        },
        %{
          account: "Assets:Bank",
          expected: %{value: 500.0, currency: "CHF", currency_position: nil},
          actual: %{value: 300.0, currency: "CHF", currency_position: nil},
          transaction_date: ~D[2026-01-15],
          transaction_payee: "Check 2",
          source_file: nil,
          source_line: nil
        }
      ]

      output = BalanceAssertions.format_failures(failures)

      assert output =~ "Assets:Cash"
      assert output =~ "Assets:Bank"
      assert output =~ "Check 1"
      assert output =~ "Check 2"
    end

    test "formats failure with file but no line number" do
      failure = %{
        account: "Assets:Cash",
        expected: %{value: 200.0, currency: "CHF", currency_position: nil},
        actual: %{value: 100.0, currency: "CHF", currency_position: nil},
        transaction_date: ~D[2026-01-15],
        transaction_payee: "Balance Check",
        source_file: "main.ledger",
        source_line: nil
      }

      output = BalanceAssertions.format_failures([failure])

      assert output =~ "File: main.ledger"
      refute output =~ "main.ledger:"
    end

    test "formats failure with nil currency" do
      failure = %{
        account: "Assets:Cash",
        expected: %{value: 200.0, currency: nil, currency_position: nil},
        actual: %{value: 100.0, currency: nil, currency_position: nil},
        transaction_date: ~D[2026-01-15],
        transaction_payee: "Balance Check",
        source_file: nil,
        source_line: nil
      }

      output = BalanceAssertions.format_failures([failure])

      assert output =~ "Expected: 200.00"
      assert output =~ "Actual:   100.00"
      refute output =~ "200.00 "
    end

    test "formats failure with default currency" do
      failure = %{
        account: "Assets:Cash",
        expected: %{value: 200.0, currency: "default", currency_position: nil},
        actual: %{value: 100.0, currency: "default", currency_position: nil},
        transaction_date: ~D[2026-01-15],
        transaction_payee: "Balance Check",
        source_file: nil,
        source_line: nil
      }

      output = BalanceAssertions.format_failures([failure])

      assert output =~ "Expected: 200.00"
      assert output =~ "Actual:   100.00"
      refute output =~ "default"
    end

    test "formats failure with integer values" do
      failure = %{
        account: "Assets:Cash",
        expected: %{value: 200, currency: "CHF", currency_position: nil},
        actual: %{value: 100, currency: "CHF", currency_position: nil},
        transaction_date: ~D[2026-01-15],
        transaction_payee: "Balance Check",
        source_file: nil,
        source_line: nil
      }

      output = BalanceAssertions.format_failures([failure])

      assert output =~ "Expected: 200 CHF"
      assert output =~ "Actual:   100 CHF"
    end
  end

  describe "entry formatting with assertions" do
    test "formats posting with assertion" do
      input = """
      2026/01/15 Balance Check
          Assets:Cash  0 = 100 CHF
          Equity:Adjustments  0
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      formatted = LedgerParser.format_transactions(transactions)

      # The formatter shows 0.00 for the zero amount
      assert formatted =~ "Assets:Cash  0.00 = 100.00 CHF"
    end

    test "formats posting with amount and assertion" do
      input = """
      2026/01/15 Balance Check
          Assets:Cash  50 CHF = 150 CHF
          Income:Bonus  -50 CHF
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, skip_assertions: true)
      formatted = LedgerParser.format_transactions(transactions)

      assert formatted =~ "Assets:Cash  50.00 CHF = 150.00 CHF"
    end
  end
end
