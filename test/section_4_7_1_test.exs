defmodule ExLedger.Section471Test do
  @moduledoc """
  Tests for Section 4.7.1 - Transactions and Comments from the Ledger manual.

  This covers:
  - Comment characters: ; # % | *
  - Price directives: P DATE SYMBOL PRICE
  - Automated transactions: = predicate
  - Periodic transactions: ~ period
  - Virtual postings: (ACCOUNT) and [ACCOUNT]
  - Cost/price syntax: @ AMOUNT and @@ AMOUNT
  - Posting notes with dates: [ACTUAL_DATE] or [=EFFECTIVE_DATE]

  Note: Basic transaction format tests are in ledger_parser_test.exs
  """

  use ExUnit.Case
  alias ExLedger.LedgerParser
  import ExLedger.TransactionHelpers

  # ==========================================================================
  # Section: Comment characters
  # ==========================================================================

  describe "comment characters - ; # % | *" do
    # Parameterized tests for each comment character
    for {char, name} <- [
          {";", "semicolon"},
          {"#", "pound/hash"},
          {"%", "percent"},
          {"|", "pipe/bar"},
          {"*", "asterisk"}
        ] do
      test "#{name} comment is ignored at top level" do
        input = """
        #{unquote(char)} This is a comment
        2024/01/15 Grocery Store
            Expenses:Food  $25.00
            Assets:Cash
        """

        transactions = parse_ledger!(input)
        assert length(transactions) == 1
        assert hd(transactions).payee == "Grocery Store"
      end
    end

    test "multiple different comment types are all ignored" do
      input = """
      ; semicolon comment
      # hash comment
      % percent comment
      | pipe comment
      * asterisk comment
      2024/01/15 Grocery Store
          Expenses:Food  $25.00
          Assets:Cash
      """

      transactions = parse_ledger!(input)
      assert length(transactions) == 1
    end

    test "comment after transaction is ignored" do
      input = """
      2024/01/15 Grocery Store
          Expenses:Food  $25.00
          Assets:Cash

      ; This comment should be ignored
      # Another comment
      """

      transactions = parse_ledger!(input)
      assert length(transactions) == 1
    end

    test "indented semicolon is parsed as posting note" do
      input = """
      2024/01/15 Grocery Store
          ; This is a note for the posting below
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      [posting1, _posting2] = txn.postings
      assert "This is a note for the posting below" in posting1.comments
    end
  end

  # ==========================================================================
  # Section: Price directives
  # ==========================================================================

  describe "price directive - P DATE SYMBOL PRICE" do
    test "parses simple price directive" do
      input = """
      P 2024/01/15 USD $1.00

      2024/01/15 Test
          Expenses:Test  $10.00
          Assets:Cash
      """

      transactions = parse_ledger!(input)
      # Price directive should be ignored as a transaction
      assert length(transactions) == 1
    end

    test "parses price directive with different currencies" do
      input = """
      P 2024/01/15 EUR $1.10
      P 2024/01/15 GBP $1.25
      P 2024/01/15 CHF $1.15

      2024/01/15 Test
          Expenses:Test  $10.00
          Assets:Cash
      """

      transactions = parse_ledger!(input)
      assert length(transactions) == 1
    end

    test "price directive does not interfere with transactions" do
      input = """
      2024/01/10 First
          Expenses:Test  $10.00
          Assets:Cash

      P 2024/01/15 EUR $1.10

      2024/01/20 Second
          Expenses:Test  $20.00
          Assets:Cash
      """

      transactions = parse_ledger!(input)
      assert length(transactions) == 2
      assert Enum.at(transactions, 0).payee == "First"
      assert Enum.at(transactions, 1).payee == "Second"
    end
  end

  # ==========================================================================
  # Section: Automated transactions
  # ==========================================================================

  describe "automated transaction - = predicate" do
    test "parses automated transaction with simple predicate" do
      input = """
      = /Groceries/
          (Budget:Food)  -1.0
      """

      txn = parse_transaction!(input)
      assert txn.kind == :automated
      assert txn.predicate == "/Groceries/"
      assert length(txn.postings) == 1
    end

    test "parses automated transaction with expression predicate" do
      input = """
      = expr account =~ /Expenses/
          (Budget:General)  -1.0
      """

      txn = parse_transaction!(input)
      assert txn.kind == :automated
      assert txn.predicate == "expr account =~ /Expenses/"
    end

    test "parses automated transaction with multiple postings" do
      input = """
      = /Food/
          Expenses:Tax  0.05
          Assets:Budget:Food
      """

      txn = parse_transaction!(input)
      assert txn.kind == :automated
      assert length(txn.postings) == 2
    end

    test "automated transaction requires predicate" do
      input = """
      =
          Assets:Test  $10.00
      """

      assert {:error, :missing_predicate} = LedgerParser.parse_transaction(input)
    end

    test "automated transaction in ledger context" do
      input = """
      = /Groceries/
          (Budget:Food)  -1.0

      2024/01/15 Grocery Store
          Expenses:Groceries  $50.00
          Assets:Cash
      """

      transactions = parse_ledger!(input)
      assert length(transactions) == 2

      [auto_txn, regular_txn] = transactions
      assert auto_txn.kind == :automated
      assert regular_txn.kind == :regular
    end
  end

  # ==========================================================================
  # Section: Periodic transactions
  # ==========================================================================

  describe "periodic transaction - ~ period" do
    test "parses periodic transaction with Monthly period" do
      input = """
      ~ Monthly
          Expenses:Rent  $1000.00
          Assets:Checking
      """

      txn = parse_transaction!(input)
      assert txn.kind == :periodic
      assert txn.period == "Monthly"
      assert length(txn.postings) == 2
    end

    test "parses periodic transaction with Weekly period" do
      input = """
      ~ Weekly
          Expenses:Groceries  $100.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.kind == :periodic
      assert txn.period == "Weekly"
    end

    test "parses periodic transaction with complex period expression" do
      input = """
      ~ every 2 weeks from 2024/01/01
          Expenses:Paycheck  $2000.00
          Income:Salary
      """

      txn = parse_transaction!(input)
      assert txn.kind == :periodic
      assert txn.period == "every 2 weeks from 2024/01/01"
    end

    test "periodic transaction requires period expression" do
      input = """
      ~
          Assets:Test  $10.00
      """

      assert {:error, :missing_period} = LedgerParser.parse_transaction(input)
    end

    test "periodic transaction in ledger context" do
      input = """
      ~ Monthly
          Expenses:Rent  $1000.00
          Assets:Checking

      2024/01/15 Grocery Store
          Expenses:Groceries  $50.00
          Assets:Cash
      """

      transactions = parse_ledger!(input)
      assert length(transactions) == 2

      [periodic_txn, regular_txn] = transactions
      assert periodic_txn.kind == :periodic
      assert regular_txn.kind == :regular
    end
  end

  # ==========================================================================
  # Section: Virtual postings
  # ==========================================================================

  describe "virtual postings - (ACCOUNT) and [ACCOUNT]" do
    test "parses virtual posting with parentheses (unbalanced)" do
      input = """
      2024/01/15 Budget allocation
          Expenses:Food  $100.00
          Assets:Checking  -$100.00
          (Budget:Food)  $-100.00
      """

      txn = parse_transaction!(input)
      assert length(txn.postings) == 3

      [_p1, _p2, virtual_posting] = txn.postings
      assert virtual_posting.account == "Budget:Food"
      assert virtual_posting.virtual == true
      assert virtual_posting.must_balance == false
    end

    test "parses virtual posting with square brackets (must balance)" do
      input = """
      2024/01/15 Budget allocation
          Expenses:Food  $100.00
          Assets:Checking  -$100.00
          [Budget:Food]  $-100.00
          [Budget:Checking]  $100.00
      """

      txn = parse_transaction!(input)
      assert length(txn.postings) == 4

      [_p1, _p2, vp1, vp2] = txn.postings
      assert vp1.account == "Budget:Food"
      assert vp1.virtual == true
      assert vp1.must_balance == true
      assert vp2.account == "Budget:Checking"
      assert vp2.virtual == true
      assert vp2.must_balance == true
    end

    test "virtual postings can have no amount" do
      input = """
      2024/01/15 Budget allocation
          Expenses:Food  $100.00
          Assets:Checking
          (Budget:Food)
      """

      txn = parse_transaction!(input)
      [_p1, _p2, virtual_posting] = txn.postings
      assert virtual_posting.account == "Budget:Food"
      assert virtual_posting.virtual == true
      assert virtual_posting.amount == nil
    end

    test "mixed regular and virtual postings" do
      input = """
      2024/01/15 Purchase
          Expenses:Food  $50.00
          Assets:Checking  -$50.00
          (Budget:Food)  $-50.00
          [Tracking:Receipts]  $50.00
          [Tracking:Expenses]  -$50.00
      """

      txn = parse_transaction!(input)
      postings = txn.postings

      assert length(postings) == 5

      # First two are regular
      assert Enum.at(postings, 0).virtual == false
      assert Enum.at(postings, 1).virtual == false

      # Third is virtual (parentheses)
      assert Enum.at(postings, 2).virtual == true
      assert Enum.at(postings, 2).must_balance == false

      # Fourth and fifth are virtual (brackets)
      assert Enum.at(postings, 3).virtual == true
      assert Enum.at(postings, 3).must_balance == true
      assert Enum.at(postings, 4).virtual == true
      assert Enum.at(postings, 4).must_balance == true
    end
  end

  # ==========================================================================
  # Section: Cost/price syntax
  # ==========================================================================

  describe "cost/price syntax - @ and @@" do
    test "parses per-unit cost with @" do
      input = """
      2024/01/15 Buy stock
          Assets:Investments:AAPL  10 AAPL @ $150.00
          Assets:Checking
      """

      txn = parse_transaction!(input)
      [posting1, _posting2] = txn.postings

      assert Decimal.eq?(posting1.amount.value, Decimal.new(10))
      assert posting1.amount.currency == "AAPL"
      assert posting1.cost.type == :per_unit
      assert Decimal.eq?(posting1.cost.amount.value, Decimal.from_float(150.00))
      assert posting1.cost.amount.currency == "$"
    end

    test "parses total cost with @@" do
      input = """
      2024/01/15 Buy stock
          Assets:Investments:AAPL  10 AAPL @@ $1500.00
          Assets:Checking
      """

      txn = parse_transaction!(input)
      [posting1, _posting2] = txn.postings

      assert Decimal.eq?(posting1.amount.value, Decimal.new(10))
      assert posting1.amount.currency == "AAPL"
      assert posting1.cost.type == :total
      assert Decimal.eq?(posting1.cost.amount.value, Decimal.from_float(1500.00))
      assert posting1.cost.amount.currency == "$"
    end

    test "cost is used for balance calculation" do
      input = """
      2024/01/15 Buy stock
          Assets:Investments:AAPL  10 AAPL @ $150.00
          Assets:Checking
      """

      txn = parse_transaction!(input)
      [_posting1, posting2] = txn.postings

      # The checking account should be balanced against the total cost
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(-1500.00))
      assert posting2.amount.currency == "$"
    end

    test "per-unit cost with currency code" do
      input = """
      2024/01/15 Currency exchange
          Assets:EUR  100 EUR @ 1.10 USD
          Assets:USD
      """

      txn = parse_transaction!(input)
      [posting1, posting2] = txn.postings

      assert Decimal.eq?(posting1.amount.value, Decimal.new(100))
      assert posting1.amount.currency == "EUR"
      assert Decimal.eq?(posting1.cost.amount.value, Decimal.new("1.10"))
      assert posting1.cost.amount.currency == "USD"

      # Decimal comparison (100 * 1.10 = 110)
      assert Decimal.eq?(posting2.amount.value, Decimal.new(-110))
      assert posting2.amount.currency == "USD"
    end

    test "total cost with currency code" do
      input = """
      2024/01/15 Currency exchange
          Assets:EUR  100 EUR @@ 110 USD
          Assets:USD
      """

      txn = parse_transaction!(input)
      [posting1, posting2] = txn.postings

      assert posting1.cost.type == :total
      assert Decimal.eq?(posting1.cost.amount.value, Decimal.new(110))
      assert posting1.cost.amount.currency == "USD"

      assert Decimal.eq?(posting2.amount.value, Decimal.new(-110))
      assert posting2.amount.currency == "USD"
    end
  end

  # ==========================================================================
  # Section: Posting notes with dates
  # ==========================================================================

  describe "posting notes with dates - [DATE] syntax" do
    test "parses posting with actual date in note" do
      input = """
      2024/01/15 Payment
          ; [2024/01/10]
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      [posting1, _posting2] = txn.postings

      assert posting1.actual_date == ~D[2024-01-10]
    end

    test "parses posting with effective date in note" do
      input = """
      2024/01/15 Payment
          ; [=2024/01/20]
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      [posting1, _posting2] = txn.postings

      assert posting1.effective_date == ~D[2024-01-20]
    end

    test "parses posting with both actual and effective dates" do
      input = """
      2024/01/15 Payment
          ; [2024/01/10=2024/01/20]
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      [posting1, _posting2] = txn.postings

      assert posting1.actual_date == ~D[2024-01-10]
      assert posting1.effective_date == ~D[2024-01-20]
    end

    test "date in note can coexist with other metadata" do
      input = """
      2024/01/15 Payment
          ; [2024/01/10]
          ; Receipt: 12345
          ; :Food:
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      [posting1, _posting2] = txn.postings

      assert posting1.actual_date == ~D[2024-01-10]
      assert posting1.metadata["Receipt"] == "12345"
      assert "Food" in posting1.tags
    end
  end

  # ==========================================================================
  # Section: Integration tests
  # ==========================================================================

  describe "integration - complete ledger with all features" do
    test "parses complex ledger with multiple feature types" do
      input = """
      ; Configuration
      # Another comment style

      ; Periodic budgets
      ~ Monthly
          Expenses:Food  $500.00
          Assets:Budget

      ; Automated rules
      = /Groceries/
          (Budget:Food)  -1.0

      ; Price history
      P 2024/01/01 EUR $1.10
      P 2024/01/15 EUR $1.12

      ; Regular transactions
      2024/01/15 * (CHK001) Grocery Store  ; weekly shopping
          Expenses:Groceries  $75.00
          Assets:Checking

      2024/01/20 ! Stock purchase
          Assets:Investments:AAPL  5 AAPL @ $150.00
          Assets:Checking
      """

      transactions = parse_ledger!(input)

      # Should have: 1 periodic, 1 automated, 2 regular
      assert length(transactions) == 4

      periodic = Enum.find(transactions, &(&1.kind == :periodic))
      assert periodic.period == "Monthly"

      automated = Enum.find(transactions, &(&1.kind == :automated))
      assert automated.predicate == "/Groceries/"

      regular = Enum.filter(transactions, &(&1.kind == :regular))
      assert length(regular) == 2
    end
  end
end
