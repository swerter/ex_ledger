defmodule ExLedger.LedgerParserTransactionTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser
  import ExLedger.TransactionHelpers

  @moduledoc """
  Tests for parse_transaction/1 including structural validation and basic parsing.
  """

  describe "parse_transaction/1 - structural validation" do
    test "requires date at start of transaction" do
      input = """
      Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      assert {:error, :missing_date} = LedgerParser.parse_transaction(input)
    end

    test "requires payee after date" do
      input = """
      2009/11/01
          Expenses:Food               $4.50
          Assets:Checking
      """

      assert {:error, :missing_payee} = LedgerParser.parse_transaction(input)
    end

    test "requires at least two postings" do
      input = """
      2009/11/01 Panera Bread
          Expenses:Food               $4.50
      """

      assert {:error, :insufficient_postings} = LedgerParser.parse_transaction(input)
    end

    test "requires minimum 1-space indentation for postings" do
      input = """
      2009/11/01 Panera Bread
      Expenses:Food               $4.50
      Assets:Checking
      """

      assert {:error, :invalid_indentation} = LedgerParser.parse_transaction(input)
    end

    test "accepts postings with 1-space indentation" do
      input = """
      2009/11/01 Panera Bread
       Expenses:Food               $4.50
       Assets:Checking
      """

      transaction = parse_transaction!(input)
      assert length(transaction.postings) == 2
    end

    test "accepts postings with 2-space indentation" do
      input = """
      2009/11/01 Panera Bread
        Expenses:Food               $4.50
        Assets:Checking
      """

      transaction = parse_transaction!(input)
      assert length(transaction.postings) == 2
    end

    test "accepts postings with 4-space indentation" do
      input = """
      2009/11/01 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)
      assert length(transaction.postings) == 2
    end

    test "accepts postings with tab indentation" do
      input = "2009/11/01 Panera Bread\n\tExpenses:Food               $4.50\n\tAssets:Checking\n"

      transaction = parse_transaction!(input)
      assert length(transaction.postings) == 2
    end

    test "rejects unindented posting lines" do
      input = """
      2009/11/01 Panera Bread
      Expenses:Food               $4.50
      Assets:Checking
      """

      assert {:error, :invalid_indentation} = LedgerParser.parse_transaction(input)
    end

    test "requires at least 2 spaces between account and amount" do
      input = """
      2009/11/01 Panera Bread
          Expenses:Food $4.50
          Assets:Checking
      """

      assert {:error, :insufficient_spacing} = LedgerParser.parse_transaction(input)
    end

    test "requires double-space before amount when currency code is present" do
      input = """
      2024/01/04 Tight spacing
          Assets:Cash CHF -10.00
          Income:Salary
      """

      assert {:error, :insufficient_spacing} = LedgerParser.parse_transaction(input)
    end

    test "accepts double-space before amount when currency code is present" do
      input = """
      2024/01/04 Acceptable spacing
          Assets:Cash  CHF -10.00
          Income:Salary
      """

      transaction = parse_transaction!(input)
      [posting1, posting2] = transaction.postings
      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(-10.00))
      assert posting1.amount.currency == "CHF"
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(10.00))
      assert posting2.amount.currency == "CHF"
    end

    test "accepts 2 or more spaces between account and amount" do
      input = """
      2009/11/01 Panera Bread
          Expenses:Food  $4.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)
      amount = Enum.at(transaction.postings, 0).amount

      assert Decimal.eq?(amount.value, Decimal.from_float(4.50))
      assert amount.currency == "$"
      assert amount.currency_position == :leading
    end

    test "rejects tab character before amount (insufficient_spacing)" do
      # Tab character (\t) instead of double space before amount
      input = """
      2009/11/01 Panera Bread
          Expenses:Food\t$4.50
          Assets:Checking
      """

      assert {:error, :insufficient_spacing} = LedgerParser.parse_transaction(input)
    end

    test "handles account names with numbers correctly" do
      # Account names containing numbers should not be confused with amounts
      # Each currency must balance independently
      input = """
      2009/11/01 Account Transfer
          1 Aktiven:10 Umlaufvermögen:1022 Wise  CHF -234.70
          6 Sonstiger Aufwand:6570 Informatik:Server  CHF 234.70
      """

      transaction = parse_transaction!(input)
      assert length(transaction.postings) == 2
    end

    test "handles account names starting with digits and containing single spaces" do
      # Account names like "3 Ertrag:3200 Handelsertrag:3210 Hosting" start with digits
      # and contain single spaces. Ledger-cli uses 2+ space separator to distinguish
      # account name from amount. This should NOT trigger insufficient_spacing error.
      input = """
      2025-06-03 * Hold release
          3 Ertrag:3200 Handelsertrag:3210 Hosting    1226.67 USD
          6 Sonstiger Aufwand:6570 Informatik:Entwicklung:USD
      """

      transaction = parse_transaction!(input)
      assert length(transaction.postings) == 2
      [posting1, posting2] = transaction.postings
      assert posting1.account == "3 Ertrag:3200 Handelsertrag:3210 Hosting"
      assert Decimal.eq?(posting1.amount.value, Decimal.new("1226.67"))
      assert posting1.amount.currency == "USD"
      assert posting2.account == "6 Sonstiger Aufwand:6570 Informatik:Entwicklung:USD"
    end

    test "handles very long account names with proper spacing" do
      # Long account name similar to real-world ledger files
      # Each currency must balance independently
      input = """
      2009/11/01 Test Transaction
          6 Other expenses:6570 Computer:Development:Webapp                           CHF 225.96
          1 Assets:10 Turnover:1022 Wise                                            CHF -225.96
      """

      transaction = parse_transaction!(input)
      [posting1, posting2] = transaction.postings
      assert posting1.account == "6 Other expenses:6570 Computer:Development:Webapp"
      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(225.96))
      assert posting1.amount.currency == "CHF"
      assert posting2.account == "1 Assets:10 Turnover:1022 Wise"
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(-225.96))
      assert posting2.amount.currency == "CHF"
    end

    test "rejects insufficient spacing with long account name" do
      # Only 1 space before amount with long account name
      input = """
      2009/11/01 Test Transaction
          6 Sonstiger Aufwand:6570 Informatik CHF 225.96
          1 Aktiven:10 Umlaufvermögen:1022 Wise USD -246.47
      """

      assert {:error, :insufficient_spacing} = LedgerParser.parse_transaction(input)
    end

    test "parses account names with spaces when properly separated from amount" do
      input = """
      2009/11/01 Store Purchase
          Expenses:Home Improvement  $125.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)

      [posting1, posting2] = transaction.postings
      assert posting1.account == "Expenses:Home Improvement"
      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(125.50))
      assert posting1.amount.currency == "$"
      assert posting2.account == "Assets:Checking"
    end

    test "parses multi-word account names with multiple spaces in name" do
      input = """
      2009/11/01 Credit Card Payment
          Liabilities:Credit Card Account  $50.00
          Assets:Checking Account
      """

      transaction = parse_transaction!(input)

      [posting1, posting2] = transaction.postings
      assert posting1.account == "Liabilities:Credit Card Account"
      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(50.00))
      assert posting1.amount.currency == "$"
      assert posting2.account == "Assets:Checking Account"
    end
  end

  describe "parse_transaction/1" do
    test "parses transaction with XFER code and expense to checking" do
      input = """
      2009/10/29 (XFER) Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2009-10-29]
      assert transaction.code == "XFER"
      assert transaction.payee == "Panera Bread"
      assert length(transaction.postings) == 2

      [posting1, posting2] = transaction.postings

      assert posting1.account == "Expenses:Food"
      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(4.50))
      assert posting1.amount.currency == "$"

      assert posting2.account == "Assets:Checking"
      # Should be automatically calculated as negative of first posting
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(-4.50))
      assert posting2.amount.currency == "$"
    end

    test "parses transaction with DEP code and income deposit" do
      input = """
      2009/10/30 (DEP) Pay day!
          Assets:Checking            $20.00
          Income
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2009-10-30]
      assert transaction.code == "DEP"
      assert transaction.payee == "Pay day!"
      assert length(transaction.postings) == 2

      [posting1, posting2] = transaction.postings

      assert posting1.account == "Assets:Checking"
      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(20.00))
      assert posting1.amount.currency == "$"

      assert posting2.account == "Income"
      # Should be automatically calculated as negative of first posting
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(-20.00))
      assert posting2.amount.currency == "$"
    end

    test "parses transaction with long hexadecimal code" do
      input = """
      2009/10/31 (559385768438A8D7) Panera Bread
          Expenses:Food               $4.50
          Liabilities:Credit Card
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2009-10-31]
      assert transaction.code == "559385768438A8D7"
      assert transaction.payee == "Panera Bread"
      assert length(transaction.postings) == 2

      [posting1, posting2] = transaction.postings

      assert posting1.account == "Expenses:Food"
      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(4.50))
      assert posting1.amount.currency == "$"

      assert posting2.account == "Liabilities:Credit Card"
      # Should be automatically calculated as negative of first posting
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(-4.50))
      assert posting2.amount.currency == "$"
    end

    test "parses transaction with auxiliary date and cleared state" do
      input = """
      2009/10/29=2009/10/28 * (XFER) Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2009-10-29]
      assert transaction.aux_date == ~D[2009-10-28]
      assert transaction.state == :cleared
      assert transaction.code == "XFER"
      assert transaction.payee == "Panera Bread"
    end

    test "parses transaction with pending state and no code" do
      input = """
      2009/10/29 ! Lunch meeting
          Expenses:Food               $12.00
          Assets:Checking
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2009-10-29]
      assert transaction.aux_date == nil
      assert transaction.state == :pending
      assert transaction.code == ""
      assert transaction.payee == "Lunch meeting"
    end

    test "parses multi-currency transaction with numbered account names" do
      input = """
      2025-05-17 * OVH
          3 Ertrag:3200 Handelsertrag:3210 Migadu:Paypal    613.37 EUR
          6 Sonstiger Aufwand:6570 Informatik:Entwicklung:USD    -716.93 USD
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2025-05-17]
      assert transaction.state == :cleared
      assert transaction.payee == "OVH"
      assert length(transaction.postings) == 2

      [posting1, posting2] = transaction.postings

      assert posting1.account == "3 Ertrag:3200 Handelsertrag:3210 Migadu:Paypal"
      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(613.37))
      assert posting1.amount.currency == "EUR"

      assert posting2.account == "6 Sonstiger Aufwand:6570 Informatik:Entwicklung:USD"
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(-716.93))
      assert posting2.amount.currency == "USD"
    end

    test "parses automated transaction" do
      input = """
      = expr true
          Assets:Cash               $5.00
          Income:Misc
      """

      transaction = parse_transaction!(input)
      assert transaction.kind == :automated
      assert transaction.predicate == "expr true"
      assert length(transaction.postings) == 2
    end

    test "parses periodic transaction" do
      input = """
      ~ Monthly
          Expenses:Rent             $500.00
          Assets:Checking
      """

      transaction = parse_transaction!(input)
      assert transaction.kind == :periodic
      assert transaction.period == "Monthly"
      assert length(transaction.postings) == 2
    end

    test "parses transaction without code" do
      input = """
      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2009-10-29]
      assert transaction.code == ""
      assert transaction.payee == "Panera Bread"

      [_posting1, posting2] = transaction.postings
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(-4.50))
      assert posting2.amount.currency == "$"
    end

    test "parses transaction with both amounts specified" do
      input = """
      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking            -$4.50
      """

      transaction = parse_transaction!(input)

      [posting1, posting2] = transaction.postings

      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(4.50))
      assert posting1.amount.currency == "$"
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(-4.50))
      assert posting2.amount.currency == "$"
    end

    test "parses transaction with payee and comment" do
      input = """
      2009/11/01 Panera Bread  ; Got something to eat
          Expenses:Food               $4.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2009-11-01]
      assert transaction.payee == "Panera Bread"
      assert transaction.comment == "Got something to eat"
      assert length(transaction.postings) == 2
    end

    test "parses transaction with posting notes including key-value metadata" do
      input = """
      2009/11/01 Panera Bread
          ; Type: Coffee
          ; Let's see, I ate a whole bunch of stuff, drank some coffee,
          ; pondered a bagel, then decided against the donut.
          Expenses:Food               $4.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2009-11-01]
      assert transaction.payee == "Panera Bread"

      [posting1, posting2] = transaction.postings

      assert posting1.account == "Expenses:Food"
      assert posting1.metadata == %{"Type" => "Coffee"}

      assert posting1.comments == [
               "Let's see, I ate a whole bunch of stuff, drank some coffee,",
               "pondered a bagel, then decided against the donut."
             ]

      assert posting2.account == "Assets:Checking"
    end

    test "parses transaction with posting notes including tags and metadata" do
      input = """
      2009/11/01 Panera Bread
          ; Type: Dining
          ; :Eating:
          ; This is another long note, after the metadata.
          Expenses:Food               $4.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2009-11-01]
      assert transaction.payee == "Panera Bread"

      [posting1, posting2] = transaction.postings

      assert posting1.account == "Expenses:Food"
      assert posting1.metadata == %{"Type" => "Dining"}
      assert posting1.tags == ["Eating"]
      assert posting1.comments == ["This is another long note, after the metadata."]

      assert posting2.account == "Assets:Checking"
    end

    test "parses transaction with multiple tags" do
      input = """
      2009/11/01 Panera Bread
          ; :Eating:
          ; :Restaurant:
          ; :QuickMeal:
          Expenses:Food               $4.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)

      [posting1, _posting2] = transaction.postings

      assert posting1.tags == ["Eating", "Restaurant", "QuickMeal"]
    end

    test "parses transaction with multiple metadata key-value pairs" do
      input = """
      2009/11/01 Panera Bread
          ; Type: Dining
          ; Location: Downtown
          ; Payment: Cash
          Expenses:Food               $4.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)

      [posting1, _posting2] = transaction.postings

      assert posting1.metadata == %{
               "Type" => "Dining",
               "Location" => "Downtown",
               "Payment" => "Cash"
             }
    end

    test "parses posting notes with spaces after semicolon" do
      input = """
      2009/11/01 Panera Bread
          ;   Type: Coffee
          Expenses:Food               $4.50
          Assets:Checking
      """

      transaction = parse_transaction!(input)

      [posting1, _posting2] = transaction.postings
      assert posting1.metadata == %{"Type" => "Coffee"}
      assert posting1.comments == []
    end

    test "parses transaction with trailing currency amounts" do
      input = """
      2024/08/01 Cash deposit
          Assets:Cash               100.00 CHF
          Income:Salary
      """

      transaction = parse_transaction!(input)

      [posting1, posting2] = transaction.postings
      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(100.00))
      assert posting1.amount.currency == "CHF"
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(-100.00))
      assert posting2.amount.currency == "CHF"
    end

    test "parses transaction with Japanese Yen symbol (large numbers)" do
      # Japanese Yen typically has no decimal places and uses large numbers
      input = """
      2024/03/15 Tokyo Electronics Store
          Expenses:Electronics          ¥158000
          Assets:Bank:JPY
      """

      transaction = parse_transaction!(input)

      [posting1, posting2] = transaction.postings
      assert posting1.account == "Expenses:Electronics"
      assert Decimal.eq?(posting1.amount.value, Decimal.new(158000))
      assert posting1.amount.currency == "¥"
      assert posting1.amount.currency_position == :leading

      assert Decimal.eq?(posting2.amount.value, Decimal.new(-158000))
      assert posting2.amount.currency == "¥"
    end

    test "parses transaction with Euro symbol" do
      input = """
      2024/03/15 Berlin Restaurant
          Expenses:Food                 €45.50
          Assets:Cash
      """

      transaction = parse_transaction!(input)

      [posting1, _] = transaction.postings
      assert Decimal.eq?(posting1.amount.value, Decimal.new("45.50"))
      assert posting1.amount.currency == "€"
      assert posting1.amount.currency_position == :leading
    end

    test "parses transaction with British Pound symbol" do
      input = """
      2024/03/15 London Tube
          Expenses:Transport            £6.80
          Assets:Cash
      """

      transaction = parse_transaction!(input)

      [posting1, _] = transaction.postings
      assert Decimal.eq?(posting1.amount.value, Decimal.new("6.80"))
      assert posting1.amount.currency == "£"
    end

    test "parses transaction with JPY currency code (large numbers)" do
      input = """
      2024/03/20 Salary Payment
          Assets:Bank:Japan            2850000 JPY
          Income:Salary:Japan         -2850000 JPY
      """

      transaction = parse_transaction!(input)

      [posting1, posting2] = transaction.postings
      assert Decimal.eq?(posting1.amount.value, Decimal.new(2850000))
      assert posting1.amount.currency == "JPY"
      assert posting1.amount.currency_position == :trailing

      assert Decimal.eq?(posting2.amount.value, Decimal.new(-2850000))
      assert posting2.amount.currency == "JPY"
    end

    test "parses transaction with stock ticker as currency (AAPL)" do
      # Stock tickers should work as commodity/currency names
      input = """
      2024/03/20 Buy Apple Stock
          Assets:Brokerage:Stocks       10 AAPL @ $150.00
          Assets:Brokerage:Cash
      """

      transaction = parse_transaction!(input)

      [posting1, _] = transaction.postings
      assert Decimal.eq?(posting1.amount.value, Decimal.new(10))
      assert posting1.amount.currency == "AAPL"
      assert posting1.cost.amount.currency == "$"
      assert Decimal.eq?(posting1.cost.amount.value, Decimal.new("150.00"))
    end

    test "parses transaction with lowercase currency name" do
      input = """
      2024/03/20 Custom Currency
          Assets:Wallet                 100 mycurrency
          Income:Mining
      """

      transaction = parse_transaction!(input)

      [posting1, posting2] = transaction.postings
      assert Decimal.eq?(posting1.amount.value, Decimal.new(100))
      assert posting1.amount.currency == "mycurrency"
      assert posting1.amount.currency_position == :trailing

      assert Decimal.eq?(posting2.amount.value, Decimal.new(-100))
      assert posting2.amount.currency == "mycurrency"
    end

    test "parses transaction with mixed case currency name" do
      input = """
      2024/03/20 Bitcoin Purchase
          Assets:Crypto                 0.5 Bitcoin
          Assets:Bank                  -25000 USD
      """

      transaction = parse_transaction!(input)

      [posting1, posting2] = transaction.postings
      assert Decimal.eq?(posting1.amount.value, Decimal.new("0.5"))
      assert posting1.amount.currency == "Bitcoin"

      assert Decimal.eq?(posting2.amount.value, Decimal.new(-25000))
      assert posting2.amount.currency == "USD"
    end

    test "parses multi-currency transaction with JPY conversion" do
      input = """
      2024/04/01 Currency Exchange
          Assets:Bank:USD              1000 USD @@ 149500 JPY
          Assets:Bank:Japan           -149500 JPY
      """

      transaction = parse_transaction!(input)

      [posting1, posting2] = transaction.postings
      assert Decimal.eq?(posting1.amount.value, Decimal.new(1000))
      assert posting1.amount.currency == "USD"
      assert posting1.cost.type == :total
      assert Decimal.eq?(posting1.cost.amount.value, Decimal.new(149500))
      assert posting1.cost.amount.currency == "JPY"

      assert Decimal.eq?(posting2.amount.value, Decimal.new(-149500))
      assert posting2.amount.currency == "JPY"
    end

    test "balance calculation works with large JPY amounts" do
      input = """
      2024/01/01 Opening Balance
          Assets:Bank:Japan            10000000 JPY
          Equity:Opening

      2024/01/15 Rent Payment
          Expenses:Rent                  150000 JPY
          Assets:Bank:Japan

      2024/01/25 Grocery Shopping
          Expenses:Food                   25000 JPY
          Assets:Bank:Japan
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      balances = LedgerParser.balance(result.transactions)

      # Assets:Bank:Japan should be 10000000 - 150000 - 25000 = 9825000 JPY
      bank_balance = balances["Assets:Bank:Japan"] |> hd()
      assert Decimal.eq?(bank_balance.amount, Decimal.new(9825000))
      assert bank_balance.currency == "JPY"

      # Expenses:Rent should be 150000 JPY
      rent_balance = balances["Expenses:Rent"] |> hd()
      assert Decimal.eq?(rent_balance.amount, Decimal.new(150000))

      # Expenses:Food should be 25000 JPY
      food_balance = balances["Expenses:Food"] |> hd()
      assert Decimal.eq?(food_balance.amount, Decimal.new(25000))
    end

    test "parses transaction at sign in description" do
      # Multi-currency transaction - ledger-cli allows this as it tracks
      # each currency separately
      input = """
      2025/01/10 LUFTHANSA-GRO 131.91 EUR @0.91677
        ; todo: file missing
        5 Personal:58 Other:5880 Other Personal expenses  CHF 60.18
        1 Assets:10 Turnover:1022 Abb                          USD -136.30
      """

      transaction = parse_transaction!(input)
      assert transaction.date == ~D[2025-01-10]
      assert transaction.payee == "LUFTHANSA-GRO 131.91 EUR @0.91677"
      assert length(transaction.postings) == 2
    end

    test "parses transaction at sign in description with balanced currencies" do
      # Same test but with balanced currencies
      input = """
      2025/01/10 LUFTHANSA-GRO 131.91 EUR @0.91677
        ; todo: file missing
        5 Personal:58 Other:5880 Other Personal expenses  CHF 60.18
        1 Assets:10 Turnover:1022 Abb                          CHF -60.18
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2025-01-10]
      assert transaction.code == ""
      assert transaction.payee == "LUFTHANSA-GRO 131.91 EUR @0.91677"
      assert length(transaction.postings) == 2

      [posting1, posting2] = transaction.postings

      assert posting1.account == "5 Personal:58 Other:5880 Other Personal expenses"
      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(60.18))
      assert posting1.amount.currency == "CHF"

      assert posting2.account == "1 Assets:10 Turnover:1022 Abb"
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(-60.18))
      assert posting2.amount.currency == "CHF"
    end

    test "parses transaction with single-digit decimal amounts" do
      # Use balanced single currency to test decimal parsing
      input = """
      2024/07/21 Paypal payment from Tilted Windmill Press
        1 Assets:Receivables:Paypal:USD    USD -75.0
        6 Expenses:Bank:Fees    USD 8.4
        5 Expenses:Other   USD 66.6
      """

      transaction = parse_transaction!(input)

      assert transaction.date == ~D[2024-07-21]
      assert transaction.payee == "Paypal payment from Tilted Windmill Press"
      assert length(transaction.postings) == 3

      [posting1, posting2, posting3] = transaction.postings

      assert posting1.account == "1 Assets:Receivables:Paypal:USD"
      assert Decimal.eq?(posting1.amount.value, Decimal.from_float(-75.0))
      assert posting1.amount.currency == "USD"

      assert posting2.account == "6 Expenses:Bank:Fees"
      assert Decimal.eq?(posting2.amount.value, Decimal.from_float(8.4))
      assert posting2.amount.currency == "USD"

      assert posting3.account == "5 Expenses:Other"
      assert Decimal.eq?(posting3.amount.value, Decimal.from_float(66.6))
      assert posting3.amount.currency == "USD"
    end
  end
end
