defmodule ExLedger.LedgerParserTest do
  use ExUnit.Case
  alias ExLedger.EntryFormatter
  alias ExLedger.LedgerParser
  alias ExLedger.TestHelpers
  import ExLedger.TransactionHelpers

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

  describe "parse_date/1" do
    test "parses YYYY/MM/DD format" do
      assert {:ok, ~D[2009-10-29]} = LedgerParser.parse_date("2009/10/29")
      assert {:ok, ~D[2009-10-30]} = LedgerParser.parse_date("2009/10/30")
      assert {:ok, ~D[2009-10-31]} = LedgerParser.parse_date("2009/10/31")
    end

    test "returns error for invalid date" do
      assert {:error, _reason} = LedgerParser.parse_date("invalid")
      assert {:error, _reason} = LedgerParser.parse_date("2009.10.29")
    end
  end

  describe "parse_posting/1" do
    test "parses posting with amount" do
      input = "    Expenses:Food               $4.50"

      posting = parse_posting!(input)

      assert posting.account == "Expenses:Food"
      assert Decimal.eq?(posting.amount.value, Decimal.from_float(4.50))
      assert posting.amount.currency == "$"
    end

    test "parses posting without amount (to be auto-balanced)" do
      input = "    Assets:Checking"

      posting = parse_posting!(input)

      assert posting.account == "Assets:Checking"
      assert posting.amount == nil
    end

    test "parses posting with negative amount" do
      input = "    Assets:Checking            -$4.50"

      posting = parse_posting!(input)

      assert posting.account == "Assets:Checking"
      assert Decimal.eq?(posting.amount.value, Decimal.from_float(-4.50))
      assert posting.amount.currency == "$"
    end

    test "parses posting with multi-level account" do
      input = "    Liabilities:Credit Card     $4.50"

      posting = parse_posting!(input)

      assert posting.account == "Liabilities:Credit Card"
      assert Decimal.eq?(posting.amount.value, Decimal.from_float(4.50))
      assert posting.amount.currency == "$"
    end

    test "parses posting with trailing currency code" do
      input = "    Assets:Cash               10.00 CHF"

      posting = parse_posting!(input)

      assert posting.account == "Assets:Cash"
      assert Decimal.eq?(posting.amount.value, Decimal.from_float(10.00))
      assert posting.amount.currency == "CHF"
    end

    test "parses posting with different amounts" do
      posting = parse_posting!("    Income    $20.00")
      assert Decimal.eq?(posting.amount.value, Decimal.from_float(20.00))
      assert posting.amount.currency == "$"
    end
  end

  describe "parse_note/1" do
    test "parses comment note" do
      input = "; Got something to eat"

      assert {:ok, {:comment, "Got something to eat"}} = LedgerParser.parse_note(input)
    end

    test "parses key-value metadata" do
      input = "; Type: Coffee"

      assert {:ok, {:metadata, "Type", "Coffee"}} = LedgerParser.parse_note(input)
    end

    test "parses key-value metadata with spaces in value" do
      input = "; Location: Downtown Boston"

      assert {:ok, {:metadata, "Location", "Downtown Boston"}} = LedgerParser.parse_note(input)
    end

    test "parses tag" do
      input = "; :Eating:"

      assert {:ok, {:tag, "Eating"}} = LedgerParser.parse_note(input)
    end

    test "parses multi-line comment" do
      input = "; Let's see, I ate a whole bunch of stuff, drank some coffee,"

      assert {:ok, {:comment, "Let's see, I ate a whole bunch of stuff, drank some coffee,"}} =
               LedgerParser.parse_note(input)
    end

    test "distinguishes between tag and comment with colons" do
      # Tag format: ; :TagName:
      assert {:ok, {:tag, "Eating"}} = LedgerParser.parse_note("; :Eating:")

      # Comment format: ; text with: colons
      assert {:ok, {:comment, "Note: this is a comment"}} =
               LedgerParser.parse_note("; Note: this is a comment")
    end
  end

  describe "parse_account_declaration/1" do
    test "parses account declaration with expense type" do
      input = "account 6 Sonstiger Aufwand:6700 Übriger Betriebsaufwand  ;; type:expense"

      assert {:ok, account} = LedgerParser.parse_account_declaration(input)
      assert account.name == "6 Sonstiger Aufwand:6700 Übriger Betriebsaufwand"
      assert account.type == :expense
    end

    test "parses account declaration with revenue type" do
      input = "account Income:Salary  ; type:revenue"

      assert {:ok, account} = LedgerParser.parse_account_declaration(input)
      assert account.name == "Income:Salary"
      assert account.type == :revenue
    end

    test "parses account declaration with asset type" do
      input = "account Assets:Checking  ;; type:asset"

      assert {:ok, account} = LedgerParser.parse_account_declaration(input)
      assert account.name == "Assets:Checking"
      assert account.type == :asset
    end

    test "parses account declaration with liability type" do
      input = "account Liabilities:Credit Card  ; type:liability"

      assert {:ok, account} = LedgerParser.parse_account_declaration(input)
      assert account.name == "Liabilities:Credit Card"
      assert account.type == :liability
    end

    test "parses account declaration with equity type" do
      input = "account Equity:Opening Balances  ; type:equity"

      assert {:ok, account} = LedgerParser.parse_account_declaration(input)
      assert account.name == "Equity:Opening Balances"
      assert account.type == :equity
    end

    test "returns error for invalid account type" do
      input = "account Assets:Checking  ; type:invalid"

      assert {:error, :invalid_account_declaration} =
               LedgerParser.parse_account_declaration(input)
    end

    test "returns error for missing type" do
      input = "account Assets:Checking"

      assert {:error, :invalid_account_declaration} =
               LedgerParser.parse_account_declaration(input)
    end
  end

  describe "parse_amount/1" do
    test "parses bare-number amounts without currency" do
      # Bare numbers should have nil currency, not default to "$"
      {:ok, amt1} = LedgerParser.parse_amount("100")
      assert Decimal.eq?(amt1.value, Decimal.new(100))
      assert amt1.currency == nil

      {:ok, amt2} = LedgerParser.parse_amount("42.50")
      assert Decimal.eq?(amt2.value, Decimal.from_float(42.50))
      assert amt2.currency == nil

      {:ok, amt3} = LedgerParser.parse_amount("-25.75")
      assert Decimal.eq?(amt3.value, Decimal.from_float(-25.75))
      assert amt3.currency == nil

      assert {:ok, amount} = LedgerParser.parse_amount("100")
      assert amount.currency_position == nil
    end

    test "parses dollar amounts with cents" do
      {:ok, amt1} = LedgerParser.parse_amount("$4.50")
      assert Decimal.eq?(amt1.value, Decimal.from_float(4.50))
      assert amt1.currency == "$"

      {:ok, amt2} = LedgerParser.parse_amount("$20.00")
      assert Decimal.eq?(amt2.value, Decimal.from_float(20.00))
      assert amt2.currency == "$"

      assert {:ok, amount} = LedgerParser.parse_amount("$4.50")
      assert amount.currency_position == :leading
    end

    test "parses negative dollar amounts" do
      {:ok, amt1} = LedgerParser.parse_amount("-$4.50")
      assert Decimal.eq?(amt1.value, Decimal.from_float(-4.50))
      assert amt1.currency == "$"

      {:ok, amt2} = LedgerParser.parse_amount("-$20.00")
      assert Decimal.eq?(amt2.value, Decimal.from_float(-20.00))
      assert amt2.currency == "$"
    end

    test "parses dollar amounts without cents" do
      {:ok, amt1} = LedgerParser.parse_amount("$4")
      assert Decimal.eq?(amt1.value, Decimal.new(4))
      assert amt1.currency == "$"

      {:ok, amt2} = LedgerParser.parse_amount("$20")
      assert Decimal.eq?(amt2.value, Decimal.new(20))
      assert amt2.currency == "$"
    end

    test "parses amounts with single-digit decimal" do
      {:ok, amt1} = LedgerParser.parse_amount("$4.5")
      assert Decimal.eq?(amt1.value, Decimal.from_float(4.5))

      {:ok, amt2} = LedgerParser.parse_amount("USD 75.0")
      assert Decimal.eq?(amt2.value, Decimal.from_float(75.0))

      {:ok, amt3} = LedgerParser.parse_amount("USD -75.0")
      assert Decimal.eq?(amt3.value, Decimal.from_float(-75.0))

      {:ok, amt4} = LedgerParser.parse_amount("CHF 66.6")
      assert Decimal.eq?(amt4.value, Decimal.from_float(66.6))
    end

    test "parses amounts with varying decimal precision" do
      {:ok, amt1} = LedgerParser.parse_amount("$4.5")
      assert Decimal.eq?(amt1.value, Decimal.new("4.5"))

      {:ok, amt2} = LedgerParser.parse_amount("$4.50")
      assert Decimal.eq?(amt2.value, Decimal.new("4.50"))

      {:ok, amt3} = LedgerParser.parse_amount("$4.123")
      assert Decimal.eq?(amt3.value, Decimal.new("4.123"))

      {:ok, amt4} = LedgerParser.parse_amount("$4.12345")
      assert Decimal.eq?(amt4.value, Decimal.new("4.12345"))
    end

    test "parses amounts with trailing currency code" do
      {:ok, amt} = LedgerParser.parse_amount("10 CHF")
      assert Decimal.eq?(amt.value, Decimal.new(10))
      assert amt.currency == "CHF"
      {:ok, amt2} = LedgerParser.parse_amount("-10.5 USD")
      assert Decimal.eq?(amt2.value, Decimal.from_float(-10.5))
      assert amt2.currency == "USD"

      {:ok, amt3} = LedgerParser.parse_amount("75 EUR")
      assert Decimal.eq?(amt3.value, Decimal.new(75))
      assert amt3.currency == "EUR"

      assert {:ok, amount} = LedgerParser.parse_amount("10 CHF")
      assert amount.currency_position == :trailing
    end

    test "parses amounts without decimal point" do
      {:ok, amt1} = LedgerParser.parse_amount("USD 100")
      assert Decimal.eq?(amt1.value, Decimal.new(100))
      assert amt1.currency == "USD"

      {:ok, amt2} = LedgerParser.parse_amount("CHF 0")
      assert Decimal.eq?(amt2.value, Decimal.new(0))
      assert amt2.currency == "CHF"
    end

    test "returns error for invalid amounts" do
      assert {:error, _reason} = LedgerParser.parse_amount("invalid")
      assert {:error, _reason} = LedgerParser.parse_amount("")
      assert {:error, _reason} = LedgerParser.parse_amount("USD 10 CHF")
    end
  end

  describe "balance_postings/1" do
    test "balances postings when second amount is nil" do
      postings = [
        %{
          account: "Expenses:Food",
          amount: %{value: Decimal.from_float(4.50), currency: "$", currency_position: :leading}
        },
        %{account: "Assets:Checking", amount: nil}
      ]

      result = LedgerParser.balance_postings(postings)
      balanced = Enum.at(result, 1).amount

      assert Decimal.eq?(balanced.value, Decimal.from_float(-4.50))
      assert balanced.currency == "$"
    end

    test "balances postings when first amount is nil" do
      postings = [
        %{account: "Assets:Checking", amount: nil},
        %{account: "Income", amount: %{value: Decimal.from_float(20.00), currency: "$", currency_position: :leading}}
      ]

      result = LedgerParser.balance_postings(postings)
      balanced = Enum.at(result, 0).amount

      assert Decimal.eq?(balanced.value, Decimal.from_float(-20.00))
      assert balanced.currency == "$"
    end

    test "does not modify postings when all amounts are specified" do
      postings = [
        %{
          account: "Expenses:Food",
          amount: %{value: Decimal.from_float(4.50), currency: "$", currency_position: :leading}
        },
        %{
          account: "Assets:Checking",
          amount: %{value: Decimal.from_float(-4.50), currency: "$", currency_position: :leading}
        }
      ]

      result = LedgerParser.balance_postings(postings)

      # Compare values individually since Decimal structs need Decimal.eq?
      assert Decimal.eq?(Enum.at(result, 0).amount.value, Enum.at(postings, 0).amount.value)
      assert Decimal.eq?(Enum.at(result, 1).amount.value, Enum.at(postings, 1).amount.value)
    end

    test "balances with multiple postings (one nil)" do
      postings = [
        %{
          account: "Expenses:Food",
          amount: %{value: Decimal.from_float(3.00), currency: "$", currency_position: :leading}
        },
        %{
          account: "Expenses:Drink",
          amount: %{value: Decimal.from_float(1.50), currency: "$", currency_position: :leading}
        },
        %{account: "Assets:Checking", amount: nil}
      ]

      result = LedgerParser.balance_postings(postings)
      balanced = Enum.at(result, 2).amount

      assert Decimal.eq?(balanced.value, Decimal.from_float(-4.50))
      assert balanced.currency == "$"
    end

    test "does not auto-balance multi-currency postings with a missing amount" do
      postings = [
        %{account: "Assets:Cash", amount: %{value: Decimal.from_float(10.00), currency: "USD"}},
        %{account: "Expenses:Fees", amount: %{value: Decimal.from_float(-5.00), currency: "CHF"}},
        %{account: "Equity:Opening", amount: nil}
      ]

      result = LedgerParser.balance_postings(postings)

      assert Enum.at(result, 2).amount == nil
    end
  end

  describe "parse_ledger/1" do
    test "parses multiple transactions and ignores comment lines" do
      input = """
      ; This is a comment at the start of the file
      ; Another comment line

      2009/10/29 (XFER) Panera Bread
          Expenses:Food               $4.50
          Assets:Checking

      ; Comment between transactions
      2009/10/30 (DEP) Pay day!
          Assets:Checking            $20.00
          Income

      2009/10/30 (XFER) Panera Bread
          Expenses:Food               $4.50
          Assets:Checking

      ; Yet another comment
      2009/10/31 (559385768438A8D7) Panera Bread
          Expenses:Food               $4.50
          Liabilities:Credit Card
      """

      assert {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 4

      assert Enum.at(transactions, 0).date == ~D[2009-10-29]
      assert Enum.at(transactions, 1).date == ~D[2009-10-30]
      assert Enum.at(transactions, 2).date == ~D[2009-10-30]
      assert Enum.at(transactions, 3).date == ~D[2009-10-31]

      # Verify all transactions are balanced
      Enum.each(transactions, fn transaction ->
        total =
          transaction.postings
          |> Enum.map(& &1.amount.value)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

        assert Decimal.eq?(total, Decimal.new(0))
      end)
    end

    test "parses multiple transactions" do
      input = """
      2009/10/29 (XFER) Panera Bread
          Expenses:Food               $4.50
          Assets:Checking

      2009/10/30 (DEP) Pay day!
          Assets:Checking            $20.00
          Income

      2009/10/30 (XFER) Panera Bread
          Expenses:Food               $4.50
          Assets:Checking

      2009/10/31 (559385768438A8D7) Panera Bread
          Expenses:Food               $4.50
          Liabilities:Credit Card
      """

      assert {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 4

      assert Enum.at(transactions, 0).date == ~D[2009-10-29]
      assert Enum.at(transactions, 1).date == ~D[2009-10-30]
      assert Enum.at(transactions, 2).date == ~D[2009-10-30]
      assert Enum.at(transactions, 3).date == ~D[2009-10-31]

      # Verify all transactions are balanced
      Enum.each(transactions, fn transaction ->
        total =
          transaction.postings
          |> Enum.map(& &1.amount.value)
          |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

        assert Decimal.eq?(total, Decimal.new(0))
      end)
    end

    test "handles empty input" do
      assert {:ok, %{transactions: []}} = LedgerParser.parse_ledger("")
      assert {:ok, %{transactions: []}} = LedgerParser.parse_ledger("\n\n")
    end

    test "parses fixture bills.ledger with attachments" do
      path = Path.expand("fixtures/bills.ledger", __DIR__)
      content = File.read!(path)

      assert {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(content)
      assert length(transactions) == 2

      first_transaction = hd(transactions)
      assert first_transaction.date == ~D[2025-01-05]
      assert first_transaction.payee == "Swiss Post - Postage and Shipping"

      [first_posting, second_posting] = first_transaction.postings

      assert first_posting.account == "Expenses:Office:Postage"
      assert Decimal.eq?(first_posting.amount.value, Decimal.from_float(145.50))
      assert first_posting.amount.currency == "CHF"

      assert second_posting.account == "Assets:Bank:Checking"
      assert Decimal.eq?(second_posting.amount.value, Decimal.from_float(-145.50))
      assert second_posting.amount.currency == "CHF"

      assert String.contains?(content, "; Attachment: bills/2025-01-05_Swiss_Post.pdf")
      assert String.contains?(content, "; Attachment: bills/2025-01-05_another.pdf")

      assert first_transaction.metadata["Attachment"] == [
               "bills/2025-01-05_Swiss_Post.pdf",
               "bills/2025-01-05_another.pdf"
             ]

      assert first_posting.metadata["Attachment"] == [
               "bills/2025-01-05_Swiss_Post.pdf",
               "bills/2025-01-05_another.pdf"
             ]

      last_transaction = List.last(transactions)
      assert last_transaction.date == ~D[2025-01-12]
      assert last_transaction.payee == "AWS - Cloud Hosting January"
    end

    test "parses multiple attachments into metadata map" do
      input = """
      2025/01/05 Swiss Post - Postage and Shipping
          Expenses:Office:Postage  145.50 CHF  ; :office:Q1:
          ; Attachment: receipts/2025-01-05_Swiss_Post.pdf
          ; Attachment: receipts/2025-01-12_AWS.pdf
          Assets:Bank:Checking
      """

      assert {:ok, %{transactions: [transaction]}} = LedgerParser.parse_ledger(input)

      [_first_posting, second_posting] = transaction.postings
      attachments = Map.get(second_posting.metadata, "Attachment")

      assert is_list(attachments)
      assert length(attachments) == 2

      assert attachments == [
               "receipts/2025-01-05_Swiss_Post.pdf",
               "receipts/2025-01-12_AWS.pdf"
             ]
    end

    test "parses transaction-level attachments into transaction metadata" do
      input = """
      2025/01/05 Swiss Post - Postage and Shipping
          ; Attachment: receipts/2025-01-05_Swiss_Post.pdf
          ; Attachment: receipts/2025-01-12_AWS.pdf
          Expenses:Office:Postage  145.50 CHF
          Assets:Bank:Checking
      """

      assert {:ok, %{transactions: [transaction]}} = LedgerParser.parse_ledger(input)

      assert transaction.metadata["Attachment"] == [
               "receipts/2025-01-05_Swiss_Post.pdf",
               "receipts/2025-01-12_AWS.pdf"
             ]

      [first_posting | _rest] = transaction.postings

      assert first_posting.metadata["Attachment"] == [
               "receipts/2025-01-05_Swiss_Post.pdf",
               "receipts/2025-01-12_AWS.pdf"
             ]
    end

    test "formats multiple attachments as separate lines" do
      input = """
      2025/01/05 Swiss Post - Postage and Shipping
          ; Attachment: receipts/2025-01-05_Swiss_Post.pdf
          ; Attachment: receipts/2025-01-12_AWS.pdf
          Expenses:Office:Postage  145.50 CHF  ; :office:Q1:
          Assets:Bank:Checking
      """

      assert {:ok, %{transactions: [transaction]}} = LedgerParser.parse_ledger(input)

      formatted = EntryFormatter.format_entry(transaction, nil, true)

      assert String.contains?(
               formatted,
               "    ; Attachment: receipts/2025-01-05_Swiss_Post.pdf\n"
             )

      assert String.contains?(
               formatted,
               "    ; Attachment: receipts/2025-01-12_AWS.pdf\n"
             )

      attachment_lines =
        formatted
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "    ; Attachment: "))

      assert length(attachment_lines) == 2
    end

    test "parses consecutive transactions without blank lines between them" do
      input = """
      2024/1/21 Transaction 1
          Account:A  CHF 100.00
          Account:B
      2024/1/21 Transaction 2
          Account:C  CHF 50.00
          Account:D
      2024/1/22 Transaction 3
          Account:E  CHF 25.00
          Account:F
      """

      assert {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 3

      assert Enum.at(transactions, 0).date == ~D[2024-01-21]
      assert Enum.at(transactions, 0).payee == "Transaction 1"
      assert length(Enum.at(transactions, 0).postings) == 2

      assert Enum.at(transactions, 1).date == ~D[2024-01-21]
      assert Enum.at(transactions, 1).payee == "Transaction 2"
      assert length(Enum.at(transactions, 1).postings) == 2

      assert Enum.at(transactions, 2).date == ~D[2024-01-22]
      assert Enum.at(transactions, 2).payee == "Transaction 3"
      assert length(Enum.at(transactions, 2).postings) == 2
    end

    test "parses transaction with many postings and one nil amount" do
      input = """
      2024/1/21 Multi-posting transaction
          Account:Main
          Account:A  CHF -100.00
          Account:B  CHF -200.00
          Account:C  CHF -300.00
      """

      assert {:ok, %{transactions: [transaction]}} = LedgerParser.parse_ledger(input)

      assert transaction.date == ~D[2024-01-21]
      assert transaction.payee == "Multi-posting transaction"
      assert length(transaction.postings) == 4

      # First posting should be auto-balanced to 600.00
      assert Decimal.eq?(Enum.at(transaction.postings, 0).amount.value, Decimal.from_float(600.00))
      assert Decimal.eq?(Enum.at(transaction.postings, 1).amount.value, Decimal.from_float(-100.00))
      assert Decimal.eq?(Enum.at(transaction.postings, 2).amount.value, Decimal.from_float(-200.00))
      assert Decimal.eq?(Enum.at(transaction.postings, 3).amount.value, Decimal.from_float(-300.00))
    end

    test "keeps posting notes and metadata when parsing multiple transactions" do
      input = """
      2009/11/01 Panera Bread
          ; Type: Coffee
          ; :Eating:
          ; Rounded up
          Expenses:Food               $4.50
          Assets:Checking
      """

      assert {:ok, %{transactions: [transaction]}} = LedgerParser.parse_ledger(input)

      [posting1, posting2] = transaction.postings

      assert posting1.metadata == %{"Type" => "Coffee"}
      assert posting1.tags == ["Eating"]
      assert posting1.comments == ["Rounded up"]
      assert posting2.metadata == %{}
    end

    test "parses consecutive transactions with multi-posting and double-semicolon comments" do
      input = """
      2024/1/21 Transaction 1
          Account:A  CHF 100.00
          Account:B
      2024/1/21 Transaction 2
          Account:Main
          Account:A  CHF -530.00 ;; comment 1
          Account:B  CHF -110.00 ;; comment 2
          Account:C  CHF -116.80 ;; comment 3
      """

      assert {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)

      assert length(transactions) == 2

      assert Enum.at(transactions, 0).date == ~D[2024-01-21]
      assert Enum.at(transactions, 0).payee == "Transaction 1"
      assert length(Enum.at(transactions, 0).postings) == 2

      assert Enum.at(transactions, 1).date == ~D[2024-01-21]
      assert Enum.at(transactions, 1).payee == "Transaction 2"
      assert length(Enum.at(transactions, 1).postings) == 4
    end

    test "parses dates with dash separator (YYYY-MM-DD)" do
      input = """
      2024-06-01 Transaction with dash date
          Account:A  CHF 100.00
          Account:B
      """

      assert {:ok, %{transactions: [transaction]}} = LedgerParser.parse_ledger(input)
      assert transaction.date == ~D[2024-06-01]
      assert transaction.payee == "Transaction with dash date"
    end

    test "parses amounts with single decimal digit correctly" do
      input = """
      2024/01/04 Test transaction
          Account:A  USD 95.01
          Account:B  USD 4.99
          Account:C  USD -100.0
      """

      assert {:ok, %{transactions: [transaction]}} = LedgerParser.parse_ledger(input)
      assert length(transaction.postings) == 3

      # Check amounts are parsed correctly
      assert Decimal.eq?(Enum.at(transaction.postings, 0).amount.value, Decimal.new("95.01"))
      assert Decimal.eq?(Enum.at(transaction.postings, 1).amount.value, Decimal.new("4.99"))
      assert Decimal.eq?(Enum.at(transaction.postings, 2).amount.value, Decimal.new("-100.0"))

      # Verify transaction balances
      total = Enum.reduce(transaction.postings, Decimal.new(0), fn p, acc -> Decimal.add(acc, p.amount.value) end)
      assert Decimal.eq?(total, Decimal.new(0))
    end

    test "includes start line for failing transaction" do
      input = """
      2009/10/29 (DEP) Pay day!
          Assets:Checking            $20.00
          Income

      2009/10/30
          Assets:Checking             $10.00
          Income
      """

      assert {:error, error} = LedgerParser.parse_ledger(input)
      assert error.reason == :missing_payee
      assert error.line == 5
      assert error.file == nil
    end
  end

  describe "validate_transaction/1" do
    test "validates balanced transaction" do
      transaction = %{
        date: ~D[2009-10-29],
        code: "XFER",
        description: "Panera Bread",
        postings: [
          %{account: "Expenses:Food", amount: %{value: 4.50, currency: "$"}},
          %{account: "Assets:Checking", amount: %{value: -4.50, currency: "$"}}
        ]
      }

      assert :ok = LedgerParser.validate_transaction(transaction)
    end

    test "returns error when multiple postings are missing amounts" do
      transaction = %{
        postings: [
          %{account: "Assets:Cash", amount: nil},
          %{account: "Expenses:Food", amount: nil},
          %{account: "Equity:Opening", amount: %{value: 5.00, currency: "$"}}
        ]
      }

      assert {:error, :multiple_nil_amounts} = LedgerParser.validate_transaction(transaction)
    end

    test "returns error for unbalanced transaction" do
      transaction = %{
        date: ~D[2009-10-29],
        code: "XFER",
        description: "Panera Bread",
        postings: [
          %{account: "Expenses:Food", amount: %{value: 4.50, currency: "$"}},
          %{account: "Assets:Checking", amount: %{value: -3.00, currency: "$"}}
        ]
      }

      assert {:error, :unbalanced} = LedgerParser.validate_transaction(transaction)
    end

    test "validates transaction with multiple postings summing to zero" do
      transaction = %{
        date: ~D[2009-10-29],
        code: "XFER",
        description: "Split purchase",
        postings: [
          %{account: "Expenses:Food", amount: %{value: 3.00, currency: "$"}},
          %{account: "Expenses:Drink", amount: %{value: 1.50, currency: "$"}},
          %{account: "Assets:Checking", amount: %{value: -4.50, currency: "$"}}
        ]
      }

      assert :ok = LedgerParser.validate_transaction(transaction)
    end

    test "accepts multi-currency transaction where currencies do not individually balance" do
      # Ledger-cli allows multi-currency transactions where each currency doesn't balance independently.
      # It tracks each currency separately.
      input = """
      2024/07/21 Paypal payment
        Assets:Receivables:Paypal    USD -75.0
        Expenses:Bank:Fees    USD 1.0
        Expenses:Training   CHF 66.61
      """

      # USD: -75 + 1 = -74 (tracked separately)
      # CHF: 66.61 (tracked separately)
      transaction = parse_transaction!(input)
      assert :ok = LedgerParser.validate_transaction(transaction)
      assert length(transaction.postings) == 3
    end

    test "accepts multi-currency transaction with integer amounts" do
      # Multi-currency transactions are allowed even when currencies don't balance
      input = """
      2024/07/21 Payment
        Assets:Account1    USD -75
        Expenses:Fees    USD 1
        Expenses:Other   CHF 66
      """

      # USD: -75 + 1 = -74 (tracked separately)
      # CHF: 66 (tracked separately)
      transaction = parse_transaction!(input)
      assert :ok = LedgerParser.validate_transaction(transaction)
    end

    test "accepts multi-currency transaction with @ in description" do
      # Test with @ symbol in description (common in payee names and exchange rates)
      # Multi-currency transactions don't require currencies to balance independently
      input = """
      2024/07/21 Payment from user@example.com @ 1.5 rate
        Assets:Account1    USD -100.0
        Expenses:Fees    USD 2.0
        Expenses:Other   CHF 80.0
      """

      # USD: -100 + 2 = -98 (tracked separately)
      # CHF: 80 (tracked separately)
      transaction = parse_transaction!(input)
      assert :ok = LedgerParser.validate_transaction(transaction)
    end

    test "returns error for unbalanced single-currency transaction" do
      # Single currency that doesn't balance - should be rejected
      input = """
      2024/07/21 Payment
        Assets:Account1    USD -75
        Expenses:Fees    USD 1
        Expenses:Other   USD 50
      """

      # Should fail validation: USD -75 + 1 + 50 = -24 (not zero)
      result = LedgerParser.parse_transaction(input)

      case result do
        {:ok, transaction} ->
          assert {:error, :unbalanced} = LedgerParser.validate_transaction(transaction)

        {:error, :unbalanced} ->
          # Parse-time validation caught it - acceptable
          assert true

        {:error, error} ->
          flunk("Parse failed with unexpected error: #{inspect(error)}. Expected :unbalanced")
      end
    end

    test "returns error for multi-currency transaction with missing amount" do
      # Multi-currency transaction with one missing amount cannot be auto-balanced
      input = """
      2024/07/21 Paypal payment from Tilted Windmill Press
        Assets:Receivables:Paypal:USD    USD -75.00
        Expenses:Bank:Fees
        Expenses:Training   CHF 66.61
      """

      assert {:error, :multi_currency_missing_amount} = LedgerParser.parse_transaction(input)
    end

    test "allows transaction with zero-value currency and missing amount" do
      # Zero-value amounts should be ignored when checking for multi-currency
      # This allows opening balances with 0.00 in secondary currencies
      input = """
      2024/01/01 Opening Balances with zero EUR
        Assets:Checking            CHF 1000.00
        Assets:Bank                EUR 0.00
        Equity:Opening Balances
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)
      assert :ok = LedgerParser.validate_transaction(transaction)

      # Verify the transaction can be balanced
      balanced_postings = LedgerParser.balance_postings(transaction.postings)
      last_posting = List.last(balanced_postings)

      assert last_posting.amount != nil, "Last posting should be auto-balanced"
      assert last_posting.amount.currency == "CHF", "Should balance in CHF (non-zero currency)"
      assert Decimal.eq?(last_posting.amount.value, Decimal.new(-1000)), "Should balance to -1000 CHF"
    end

    test "allows transaction with multiple zero-value currencies and missing amount" do
      # Multiple zero-value amounts in different currencies should all be ignored
      input = """
      2024/01/01 Opening Balances
        Assets:Checking            CHF 500.00
        Assets:Paypal:USD          USD 0.00
        Assets:Bank:EUR            EUR 0.00
        Equity:Opening Balances
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)
      assert :ok = LedgerParser.validate_transaction(transaction)

      balanced_postings = LedgerParser.balance_postings(transaction.postings)
      last_posting = List.last(balanced_postings)

      assert last_posting.amount != nil
      assert last_posting.amount.currency == "CHF"
      assert Decimal.eq?(last_posting.amount.value, Decimal.new(-500))
    end
  end

  describe "get_account_postings/2" do
    setup do
      transactions = [
        %{
          date: ~D[2009-10-29],
          code: "XFER",
          payee: "Panera Bread",
          postings: [
            %{account: "Expenses:Food", amount: %{value: Decimal.new("4.50"), currency: "$"}},
            %{account: "Assets:Checking", amount: %{value: Decimal.new("-4.50"), currency: "$"}}
          ]
        },
        %{
          date: ~D[2009-10-30],
          code: "DEP",
          payee: "Pay day!",
          postings: [
            %{account: "Assets:Checking", amount: %{value: Decimal.new("20.00"), currency: "$"}},
            %{account: "Income", amount: %{value: Decimal.new("-20.00"), currency: "$"}}
          ]
        },
        %{
          date: ~D[2009-10-30],
          code: "XFER",
          payee: "Panera Bread",
          postings: [
            %{account: "Expenses:Food", amount: %{value: Decimal.new("4.50"), currency: "$"}},
            %{account: "Assets:Checking", amount: %{value: Decimal.new("-4.50"), currency: "$"}}
          ]
        },
        %{
          date: ~D[2009-10-31],
          code: "559385768438A8D7",
          payee: "Panera Bread",
          postings: [
            %{account: "Expenses:Food", amount: %{value: Decimal.new("4.50"), currency: "$"}},
            %{account: "Liabilities:Credit Card", amount: %{value: Decimal.new("-4.50"), currency: "$"}}
          ]
        }
      ]

      {:ok, transactions: transactions}
    end

    test "returns postings for Expenses:Food account with running balance", %{
      transactions: transactions
    } do
      result = LedgerParser.get_account_postings(transactions, "Expenses:Food")

      assert length(result) == 3

      # First posting: 09-Oct-29 Panera Bread   Expenses:Food       $4.50     $4.50
      p0 = Enum.at(result, 0)
      assert p0.date == ~D[2009-10-29]
      assert p0.description == "Panera Bread"
      assert p0.account == "Expenses:Food"
      assert Decimal.eq?(p0.amount, Decimal.from_float(4.50))
      assert Decimal.eq?(p0.balance, Decimal.from_float(4.50))

      # Second posting: 09-Oct-30 Panera Bread   Expenses:Food       $4.50     $9.00
      p1 = Enum.at(result, 1)
      assert p1.date == ~D[2009-10-30]
      assert Decimal.eq?(p1.amount, Decimal.from_float(4.50))
      assert Decimal.eq?(p1.balance, Decimal.from_float(9.00))

      # Third posting: 09-Oct-31 Panera Bread   Expenses:Food       $4.50     $13.50
      p2 = Enum.at(result, 2)
      assert p2.date == ~D[2009-10-31]
      assert Decimal.eq?(p2.amount, Decimal.from_float(4.50))
      assert Decimal.eq?(p2.balance, Decimal.from_float(13.50))
    end

    test "returns postings for Assets:Checking account with running balance", %{
      transactions: transactions
    } do
      result = LedgerParser.get_account_postings(transactions, "Assets:Checking")

      assert length(result) == 3

      # First: 09-Oct-29 Panera Bread   Assets:Checking   -$4.50    -$4.50
      p0 = Enum.at(result, 0)
      assert p0.date == ~D[2009-10-29]
      assert p0.description == "Panera Bread"
      assert p0.account == "Assets:Checking"
      assert Decimal.eq?(p0.amount, Decimal.from_float(-4.50))
      assert Decimal.eq?(p0.balance, Decimal.from_float(-4.50))

      # Second: 09-Oct-30 Pay day!   Assets:Checking   $20.00    $15.50
      p1 = Enum.at(result, 1)
      assert p1.date == ~D[2009-10-30]
      assert Decimal.eq?(p1.amount, Decimal.from_float(20.00))
      assert Decimal.eq?(p1.balance, Decimal.from_float(15.50))

      # Third: 09-Oct-30 Panera Bread   Assets:Checking   -$4.50    $11.00
      p2 = Enum.at(result, 2)
      assert p2.date == ~D[2009-10-30]
      assert Decimal.eq?(p2.amount, Decimal.from_float(-4.50))
      assert Decimal.eq?(p2.balance, Decimal.from_float(11.00))
    end

    test "returns postings for Income account with running balance", %{transactions: transactions} do
      result = LedgerParser.get_account_postings(transactions, "Income")

      assert length(result) == 1

      p0 = Enum.at(result, 0)
      assert p0.date == ~D[2009-10-30]
      assert p0.description == "Pay day!"
      assert p0.account == "Income"
      assert Decimal.eq?(p0.amount, Decimal.from_float(-20.00))
      assert Decimal.eq?(p0.balance, Decimal.from_float(-20.00))
    end

    test "returns postings for Liabilities:Credit Card account with running balance", %{
      transactions: transactions
    } do
      result = LedgerParser.get_account_postings(transactions, "Liabilities:Credit Card")

      assert length(result) == 1

      p0 = Enum.at(result, 0)
      assert p0.date == ~D[2009-10-31]
      assert p0.description == "Panera Bread"
      assert p0.account == "Liabilities:Credit Card"
      assert Decimal.eq?(p0.amount, Decimal.from_float(-4.50))
      assert Decimal.eq?(p0.balance, Decimal.from_float(-4.50))
    end

    test "returns empty list for non-existent account", %{transactions: transactions} do
      result = LedgerParser.get_account_postings(transactions, "Assets:Savings")

      assert result == []
    end

    test "calculates running balance correctly with multiple transactions", %{
      transactions: transactions
    } do
      result = LedgerParser.get_account_postings(transactions, "Expenses:Food")

      # Verify running balance calculation
      assert Decimal.eq?(Enum.at(result, 0).balance, Decimal.from_float(4.50))
      assert Decimal.eq?(Enum.at(result, 1).balance, Decimal.from_float(9.00))
      assert Decimal.eq?(Enum.at(result, 2).balance, Decimal.from_float(13.50))

      # Verify each balance is cumulative
      Enum.reduce(result, Decimal.new(0), fn posting, acc ->
        expected_balance = Decimal.add(acc, posting.amount)
        assert Decimal.eq?(posting.balance, expected_balance)
        posting.balance
      end)
    end
  end

  describe "format_account_register/2" do
    test "formats account register output with date, description, account, amount, and balance" do
      postings = [
        %{
          date: ~D[2009-10-29],
          description: "Panera Bread",
          account: "Expenses:Food",
          amount: 4.50,
          balance: 4.50
        },
        %{
          date: ~D[2009-10-30],
          description: "Panera Bread",
          account: "Expenses:Food",
          amount: 4.50,
          balance: 9.00
        }
      ]

      result = LedgerParser.format_account_register(postings, "Expenses:Food")

      expected = """
      09-Oct-29 Panera Bread   Expenses:Food       $4.50     $4.50
      09-Oct-30 Panera Bread   Expenses:Food       $4.50     $9.00
      """

      assert String.trim(result) == String.trim(expected)
    end

    test "formats negative amounts correctly" do
      postings = [
        %{
          date: ~D[2009-10-29],
          description: "Panera Bread",
          account: "Assets:Checking",
          amount: -4.50,
          balance: -4.50
        },
        %{
          date: ~D[2009-10-30],
          description: "Pay day!",
          account: "Assets:Checking",
          amount: 20.00,
          balance: 15.50
        }
      ]

      result = LedgerParser.format_account_register(postings, "Assets:Checking")

      expected = """
      09-Oct-29 Panera Bread   Assets:Checking    -$4.50    -$4.50
      09-Oct-30 Pay day!       Assets:Checking    $20.00    $15.50
      """

      assert String.trim(result) == String.trim(expected)
    end
  end

  describe "format_balance/2" do
    test "shows single-currency totals with currency and actual imbalance" do
      balances = %{
        "Assets:Checking" => [%{amount: -10.0, currency: "$"}],
        "Expenses:Coffee" => [%{amount: 5.0, currency: "$"}]
      }

      result = LedgerParser.format_balance(balances)
      lines = String.split(result, "\n")

      # Totals line is second to last because output ends with a newline
      assert Enum.at(lines, -2) == String.pad_leading("$-5.00", 20)
    end
  end

  describe "parse_ledger/1 - include directive (no file resolution)" do
    test "parses transactions without include directives" do
      # parse_ledger/1 doesn't resolve includes, so include lines are ignored
      input = """
      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      assert {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input)
      assert length(transactions) == 1
    end
  end

  describe "extract_account_declarations/1" do
    test "extracts account declarations from ledger content" do
      input = """
      account Assets:Checking  ; type:asset
      account Expenses:Food  ;; type:expense
      account Income:Salary  ; type:revenue
      account Liabilities:Credit Card  ; type:liability

      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      accounts = LedgerParser.extract_account_declarations(input)

      assert accounts == %{
               "Assets:Checking" => :asset,
               "Expenses:Food" => :expense,
               "Income:Salary" => :revenue,
               "Liabilities:Credit Card" => :liability
             }
    end

    test "extracts account declarations with comments in file" do
      input = """
      ; This is a comment
      account Assets:Checking  ; type:asset
      ; Another comment
      account Expenses:Food  ;; type:expense
      account Income:Salary  ; type:revenue

      ; Comment before transaction
      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      accounts = LedgerParser.extract_account_declarations(input)

      assert accounts == %{
               "Assets:Checking" => :asset,
               "Expenses:Food" => :expense,
               "Income:Salary" => :revenue
             }
    end

    test "ignores invalid account declarations" do
      input = """
      account Assets:Checking  ; type:asset
      account Another:Account  ; type:invalid_type

      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      accounts = LedgerParser.extract_account_declarations(input)

      assert accounts == %{
               "Assets:Checking" => :asset
             }
    end

    test "returns empty map when no account declarations" do
      input = """
      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      accounts = LedgerParser.extract_account_declarations(input)

      assert accounts == %{}
    end
  end

  describe "parse_ledger_with_includes/2 - file resolution" do
    setup do
      {:ok, test_dir: TestHelpers.tmp_dir!("ex_ledger_test")}
    end

    test "reads and parses included file", %{test_dir: test_dir} do
      # Create an included file
      included_file = Path.join(test_dir, "opening_balances.ledger")

      File.write!(included_file, """
      2009/01/01 Opening Balance
          Assets:Checking            $100.00
          Equity:Opening Balances
      """)

      # Create main file that includes it
      main_file = Path.join(test_dir, "main.ledger")

      File.write!(main_file, """
      include opening_balances.ledger

      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """)

      # Parse with includes
      {:ok, content} = File.read(main_file)

      assert {:ok, %{transactions: transactions, accounts: accounts}} =
               LedgerParser.parse_ledger(content, base_dir: test_dir)

      # Should have both transactions
      assert length(transactions) == 2
      assert Enum.at(transactions, 0).payee == "Opening Balance"
      assert Enum.at(transactions, 1).payee == "Panera Bread"
      # No account declarations in this test
      assert accounts == %{}
    end

    test "expands aliases defined in an included file", %{test_dir: test_dir} do
      accounts_file = Path.join(test_dir, "accounts.ledger")

      File.write!(accounts_file, """
      account Assets:Checking
              alias checking
      alias bank = checking
      """)

      main_file = Path.join(test_dir, "main.ledger")

      File.write!(main_file, """
      include accounts.ledger

      2024/01/01 Grocery Store
          bank                        $50.00
          Assets:Checking
      """)

      {:ok, content} = File.read(main_file)

      assert {:ok, %{accounts: accounts}} =
               LedgerParser.parse_ledger(content, base_dir: test_dir)

      assert accounts["Assets:Checking"] == :asset
      assert accounts["checking"] == "Assets:Checking"
      assert accounts["bank"] == "Assets:Checking"
    end

    test "handles nested includes", %{test_dir: test_dir} do
      # Create a deeply included file
      deep_file = Path.join(test_dir, "deep.ledger")

      File.write!(deep_file, """
      2009/01/01 Deep Transaction
          Assets:Checking            $50.00
          Equity:Opening Balances
      """)

      # Create an included file that includes another file
      included_file = Path.join(test_dir, "opening_balances.ledger")

      File.write!(included_file, """
      include deep.ledger

      2009/01/02 Middle Transaction
          Assets:Checking            $100.00
          Equity:Opening Balances
      """)

      # Create main file
      main_file = Path.join(test_dir, "main.ledger")

      File.write!(main_file, """
      include opening_balances.ledger

      2009/10/29 Top Transaction
          Expenses:Food               $4.50
          Assets:Checking
      """)

      {:ok, content} = File.read(main_file)

      assert {:ok, %{transactions: transactions}} =
               LedgerParser.parse_ledger(content, base_dir: test_dir)

      # Should have all three transactions
      assert length(transactions) == 3
      assert Enum.at(transactions, 0).payee == "Deep Transaction"
      assert Enum.at(transactions, 1).payee == "Middle Transaction"
      assert Enum.at(transactions, 2).payee == "Top Transaction"
    end

    test "returns error when included file does not exist", %{test_dir: test_dir} do
      main_file = Path.join(test_dir, "main.ledger")

      File.write!(main_file, """
      include nonexistent.ledger

      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """)

      {:ok, content} = File.read(main_file)

      assert {:error, {:include_not_found, "nonexistent.ledger"}} =
               LedgerParser.parse_ledger(content, base_dir: test_dir)
    end

    test "handles relative paths in includes", %{test_dir: test_dir} do
      # Create subdirectory
      sub_dir = Path.join(test_dir, "ledgers")
      File.mkdir_p!(sub_dir)

      included_file = Path.join(sub_dir, "opening_balances.ledger")

      File.write!(included_file, """
      2009/01/01 Opening Balance
          Assets:Checking            $100.00
          Equity:Opening Balances
      """)

      main_file = Path.join(test_dir, "main.ledger")

      File.write!(main_file, """
      include ledgers/opening_balances.ledger

      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """)

      {:ok, content} = File.read(main_file)

      assert {:ok, %{transactions: transactions}} =
               LedgerParser.parse_ledger(content, base_dir: test_dir)

      assert length(transactions) == 2
    end

    test "prevents infinite loops with circular includes", %{test_dir: test_dir} do
      # Create file A that includes B
      file_a = Path.join(test_dir, "a.ledger")

      File.write!(file_a, """
      include b.ledger

      2009/01/01 Transaction A
          Assets:Checking            $100.00
          Equity:Opening Balances
      """)

      # Create file B that includes A (circular reference)
      file_b = Path.join(test_dir, "b.ledger")

      File.write!(file_b, """
      include a.ledger

      2009/01/02 Transaction B
          Assets:Checking            $50.00
          Equity:Opening Balances
      """)

      {:ok, content} = File.read(file_a)

      assert {:error, {:circular_include, _}} =
               LedgerParser.parse_ledger(content, base_dir: test_dir)
    end

    test "rejects symlinks pointing outside base directory", %{test_dir: test_dir} do
      # Create a file outside the test directory
      outside_dir = TestHelpers.tmp_dir!("outside_ledger_test")

      outside_file = Path.join(outside_dir, "outside.ledger")

      File.write!(outside_file, """
      2009/01/01 Outside Transaction
          Assets:Checking            $100.00
          Equity:Opening Balances
      """)

      # Create a symlink inside test_dir pointing to outside file
      symlink_path = Path.join(test_dir, "symlink.ledger")

      # Create symlink (this might fail on some systems without permissions)
      case File.ln_s(outside_file, symlink_path) do
        :ok ->
          # Create main file that tries to include via symlink
          main_file = Path.join(test_dir, "main.ledger")

          File.write!(main_file, """
          include symlink.ledger

          2009/10/29 Local Transaction
              Expenses:Food               $4.50
              Assets:Checking
          """)

          {:ok, content} = File.read(main_file)

          # Should reject because symlink points outside base_dir
          assert {:error, {:include_outside_base, "symlink.ledger"}} =
                   LedgerParser.parse_ledger(content, base_dir: test_dir)

        {:error, _} ->
          # Skip test if symlinking is not supported
          :ok
      end
    end

    test "strips comments from include lines", %{test_dir: test_dir} do
      included_file = Path.join(test_dir, "opening_balances.ledger")

      File.write!(included_file, """
      2009/01/01 Opening Balance
          Assets:Checking            $100.00
          Equity:Opening Balances
      """)

      main_file = Path.join(test_dir, "main.ledger")

      File.write!(main_file, """
      include opening_balances.ledger  ; 2024 opening balances
      """)

      {:ok, content} = File.read(main_file)

      assert {:ok, %{transactions: transactions}} =
               LedgerParser.parse_ledger(content, base_dir: test_dir)

      assert length(transactions) == 1
      assert Enum.at(transactions, 0).payee == "Opening Balance"
    end

    test "extracts account declarations from main file and included files", %{test_dir: test_dir} do
      # Create an included file with account declarations
      included_file = Path.join(test_dir, "accounts.ledger")

      File.write!(included_file, """
      account Assets:Checking  ; type:asset
      account Expenses:Food  ; type:expense

      2009/01/01 Opening Balance
          Assets:Checking            $100.00
          Equity:Opening Balances
      """)

      # Create main file with its own account declarations
      main_file = Path.join(test_dir, "main.ledger")

      File.write!(main_file, """
      account Income:Salary  ; type:revenue
      account Liabilities:Credit Card  ; type:liability

      include accounts.ledger

      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """)

      {:ok, content} = File.read(main_file)

      assert {:ok, %{transactions: transactions, accounts: accounts}} =
               LedgerParser.parse_ledger(content, base_dir: test_dir)

      # Should have both transactions
      assert length(transactions) == 2

      # Should have all account declarations from both files
      assert accounts == %{
               "Assets:Checking" => :asset,
               "Expenses:Food" => :expense,
               "Income:Salary" => :revenue,
               "Liabilities:Credit Card" => :liability
             }
    end

    test "handles comments and account declarations together", %{test_dir: test_dir} do
      # Create a ledger file with comments and account declarations
      ledger_file = Path.join(test_dir, "with_comments.ledger")

      File.write!(ledger_file, """
      ; This file demonstrates account declarations
      ; with comments throughout

      account Assets:Checking  ; type:asset
      ; Comment between declarations
      account Expenses:Food  ; type:expense

      ; Now for some transactions
      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking

      ; Another transaction
      2009/10/30 Salary
          Assets:Checking            $2000.00
          Income:Salary
      """)

      {:ok, content} = File.read(ledger_file)

      assert {:ok, %{transactions: transactions, accounts: accounts}} =
               LedgerParser.parse_ledger(content, base_dir: test_dir)

      # Should have both transactions
      assert length(transactions) == 2
      assert Enum.at(transactions, 0).payee == "Panera Bread"
      assert Enum.at(transactions, 1).payee == "Salary"

      # Should have account declarations
      assert accounts == %{
               "Assets:Checking" => :asset,
               "Expenses:Food" => :expense
             }
    end

    test "handles include files with errors", %{test_dir: test_dir} do
      included_file = Path.join(test_dir, "bad.ledger")

      File.write!(included_file, """
      2009/01/01
          Assets:Checking            $100.00
      """)

      main_file = Path.join(test_dir, "main.ledger")

      File.write!(main_file, """
      include bad.ledger
      """)

      {:ok, content} = File.read(main_file)
      # Should return an error about the parse failure in the included file
      assert {:error, _} = LedgerParser.parse_ledger(content, base_dir: test_dir)
    end

    test "returns import chain when an included file fails to parse", %{test_dir: test_dir} do
      included_file = Path.join(test_dir, "bad.ledger")

      File.write!(included_file, """
      2009/01/01
          Assets:Checking            $100.00
      """)

      main_file = Path.join(test_dir, "main.ledger")

      File.write!(main_file, """
      include bad.ledger
      """)

      {:ok, content} = File.read(main_file)

      assert {:error,
              %{
                reason: :missing_payee,
                line: 1,
                file: "bad.ledger",
                import_chain: [{"main.ledger", 1}]
              }} =
               LedgerParser.parse_ledger(
                 content,
                 base_dir: test_dir,
                 source_file: "main.ledger"
               )
    end
  end

  describe "account aliases" do
    test "extracts account declarations with aliases (new format)" do
      input = """
      account Expenses:Groceries
              assert commodity == "CHF"
              alias postkonto
      account Assets:Checking
              alias checking
              alias bank

      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      accounts = LedgerParser.extract_account_declarations(input)

      # Should have main account names mapped to types
      assert accounts["Expenses:Groceries"] == :asset
      assert accounts["Assets:Checking"] == :asset

      # Should have aliases mapped to account names
      assert accounts["postkonto"] == "Expenses:Groceries"
      assert accounts["checking"] == "Assets:Checking"
      assert accounts["bank"] == "Assets:Checking"
    end

    test "extracts account declarations without aliases (new format)" do
      input = """
      account Expenses:Food
      account Assets:Checking
              assert commodity == "USD"

      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      accounts = LedgerParser.extract_account_declarations(input)

      # Should only have main account names
      assert accounts["Expenses:Food"] == :asset
      assert accounts["Assets:Checking"] == :asset
      assert map_size(accounts) == 2
    end

    test "resolves account name when given an alias" do
      accounts = %{
        "Assets:Checking" => :asset,
        "checking" => "Assets:Checking",
        "bank" => "Assets:Checking"
      }

      assert LedgerParser.resolve_account_name("checking", accounts) == "Assets:Checking"
      assert LedgerParser.resolve_account_name("bank", accounts) == "Assets:Checking"
    end

    test "resolves account name when given a main account name" do
      accounts = %{
        "Assets:Checking" => :asset,
        "checking" => "Assets:Checking"
      }

      assert LedgerParser.resolve_account_name("Assets:Checking", accounts) == "Assets:Checking"
    end

    test "resolves account name for unknown account" do
      accounts = %{
        "Assets:Checking" => :asset,
        "checking" => "Assets:Checking"
      }

      assert LedgerParser.resolve_account_name("Unknown:Account", accounts) == "Unknown:Account"
    end

    test "resolves transaction aliases" do
      transactions = [
        %{
          date: ~D[2009-10-29],
          code: "",
          payee: "Test",
          comment: nil,
          postings: [
            %{
              account: "checking",
              amount: %{value: -10.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            },
            %{
              account: "food",
              amount: %{value: 10.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        }
      ]

      accounts = %{
        "Assets:Checking" => :asset,
        "Expenses:Food" => :expense,
        "checking" => "Assets:Checking",
        "food" => "Expenses:Food"
      }

      resolved = LedgerParser.resolve_transaction_aliases(transactions, accounts)

      assert Enum.at(resolved, 0).postings |> Enum.at(0) |> Map.get(:account) == "Assets:Checking"
      assert Enum.at(resolved, 0).postings |> Enum.at(1) |> Map.get(:account) == "Expenses:Food"
    end

    test "balance resolves aliases before calculating account balances" do
      input = """
      account Assets:Checking
              alias checking
      account Expenses:Food
              alias food

      2024/01/01 Grocery Store
          food                        $50.00
          checking
      """

      {:ok, %{transactions: transactions, accounts: accounts}} =
        LedgerParser.parse_ledger(input, base_dir: ".")

      # Resolve aliases before calculating balance
      resolved = LedgerParser.resolve_transaction_aliases(transactions, accounts)
      balances = LedgerParser.balance(resolved)

      # Should have canonical account names, not aliases
      assert Map.has_key?(balances, "Assets:Checking")
      assert Map.has_key?(balances, "Expenses:Food")
      refute Map.has_key?(balances, "checking")
      refute Map.has_key?(balances, "food")

      assert Decimal.eq?(balances["Expenses:Food"] |> hd() |> Map.get(:amount), Decimal.new(50))
      assert Decimal.eq?(balances["Assets:Checking"] |> hd() |> Map.get(:amount), Decimal.new(-50))
    end

    test "stats resolves aliases before calculating statistics" do
      input = """
      account Assets:Checking
              alias checking
      account Expenses:Food
              alias food

      2024/01/01 Grocery Store
          food                        $50.00
          checking

      2024/01/02 Restaurant
          food                        $25.00
          checking
      """

      {:ok, %{transactions: transactions, accounts: accounts}} =
        LedgerParser.parse_ledger(input, base_dir: ".")

      # Without resolving aliases, stats would count "food" and "checking" as separate accounts
      resolved = LedgerParser.resolve_transaction_aliases(transactions, accounts)
      stats = LedgerParser.stats(resolved)

      # Should count only 2 accounts (canonical names), not 4 (aliases + canonical)
      # Note: stats returns atom keys, and the key is :unique_accounts
      assert stats[:unique_accounts] == 2
    end

    test "list_accounts shows canonical names when aliases are used in transactions" do
      input = """
      account Assets:Checking
              alias checking
      account Expenses:Food
              alias food

      2024/01/01 Grocery Store
          food                        $50.00
          checking
      """

      {:ok, %{transactions: transactions, accounts: accounts}} =
        LedgerParser.parse_ledger(input, base_dir: ".")

      # Resolve aliases before listing
      resolved = LedgerParser.resolve_transaction_aliases(transactions, accounts)
      account_list = LedgerParser.list_accounts(resolved, accounts)

      # Should show canonical names, not aliases
      assert "Assets:Checking" in account_list
      assert "Expenses:Food" in account_list
      refute "checking" in account_list
      refute "food" in account_list
    end

    test "list_accounts resolves aliases without pre-resolving" do
      input = """
      account Assets:Checking
              alias checking
      account Expenses:Food
              alias food

      2024/01/01 Grocery Store
          food                        $50.00
          checking
      """

      {:ok, %{transactions: transactions, accounts: accounts}} =
        LedgerParser.parse_ledger(input, base_dir: ".")

      account_list = LedgerParser.list_accounts(transactions, accounts)

      assert "Assets:Checking" in account_list
      assert "Expenses:Food" in account_list
      refute "checking" in account_list
      refute "food" in account_list
    end

    test "budget_report resolves aliases before calculating budget" do
      input = """
      account Expenses:Rent
              alias rent
      account Income:Salary
              alias salary

      ~ Monthly
          rent                        $1000.00
          salary

      2024/01/01 Paycheck
          salary                      $3000.00
          Assets:Checking
      """

      {:ok, %{transactions: transactions, accounts: accounts}} =
        LedgerParser.parse_ledger(input, base_dir: ".")

      # Resolve aliases before budget calculation
      resolved = LedgerParser.resolve_transaction_aliases(transactions, accounts)
      budget_list = LedgerParser.budget_report(resolved)

      # budget_report returns a list of maps, extract account names
      budget_accounts = Enum.map(budget_list, & &1.account) |> Enum.uniq()

      # Should use canonical account names
      assert "Expenses:Rent" in budget_accounts
      assert "Income:Salary" in budget_accounts
      refute "rent" in budget_accounts
      refute "salary" in budget_accounts
    end

    test "handles mixed old and new account declaration formats" do
      input = """
      account Income:Salary  ; type:revenue
      account Expenses:Groceries
              alias groceries
      account Assets:Checking  ; type:asset

      2009/10/29 Test
          Expenses:Food               $4.50
          Assets:Checking
      """

      accounts = LedgerParser.extract_account_declarations(input)

      # Old format accounts
      assert accounts["Income:Salary"] == :revenue
      assert accounts["Assets:Checking"] == :asset

      # New format account with alias
      assert accounts["Expenses:Groceries"] == :asset
      assert accounts["groceries"] == "Expenses:Groceries"
    end

    test "parses account block with multiple assertions and aliases" do
      input = """
      account Expenses:Groceries
              assert commodity == "CHF"
              alias postkonto
              alias groceries
              assert balance >= 0

      """

      accounts = LedgerParser.extract_account_declarations(input)

      assert accounts["Expenses:Groceries"] == :asset
      assert accounts["postkonto"] == "Expenses:Groceries"
      assert accounts["groceries"] == "Expenses:Groceries"
    end

    test "expands alias chains to canonical accounts" do
      input = """
      account Assets:Checking
              alias checking
      alias bank = checking
      """

      accounts = LedgerParser.extract_account_declarations(input)

      assert accounts["Assets:Checking"] == :asset
      assert accounts["checking"] == "Assets:Checking"
      assert accounts["bank"] == "Assets:Checking"
    end

    test "parses account with type comment AND aliases in block" do
      input = """
      account Expenses:Food  ; type:expense
              alias food
              alias groceries
      account Assets:Cash  ; type:asset
              alias cash
      """

      accounts = LedgerParser.extract_account_declarations(input)

      # Account types should be correctly parsed from type comment
      assert accounts["Expenses:Food"] == :expense
      assert accounts["Assets:Cash"] == :asset

      # Aliases should also be parsed from the block
      assert accounts["food"] == "Expenses:Food"
      assert accounts["groceries"] == "Expenses:Food"
      assert accounts["cash"] == "Assets:Cash"
    end

    test "aliases in transactions resolve correctly when account has type comment" do
      input = """
      account Expenses:Food  ; type:expense
              alias food
      account Assets:Cash  ; type:asset
              alias cash

      2024/01/15 Grocery Store
          food                    $50.00
          cash
      """

      {:ok, %{transactions: transactions, accounts: accounts}} = LedgerParser.parse_ledger(input, base_dir: ".")

      # Verify account types
      assert accounts["Expenses:Food"] == :expense
      assert accounts["Assets:Cash"] == :asset

      # Verify aliases exist
      assert accounts["food"] == "Expenses:Food"
      assert accounts["cash"] == "Assets:Cash"

      # Verify alias resolution happens automatically during parsing
      [transaction] = transactions

      posting_accounts = Enum.map(transaction.postings, & &1.account)
      assert "Expenses:Food" in posting_accounts
      assert "Assets:Cash" in posting_accounts
      refute "food" in posting_accounts
      refute "cash" in posting_accounts
    end

    test "aliases are automatically expanded during parse_ledger" do
      input = """
      account Assets:Bank:Checking  ; type:asset
              alias checking
              alias bank

      2024/01/15 Deposit
          checking                $1000.00
          Income:Salary

      2024/01/16 Withdrawal
          Expenses:Food           $50.00
          bank
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, base_dir: ".")

      # Both transactions should have aliases resolved automatically
      [txn1, txn2] = transactions

      # First transaction: "checking" -> "Assets:Bank:Checking"
      assert Enum.any?(txn1.postings, &(&1.account == "Assets:Bank:Checking"))
      refute Enum.any?(txn1.postings, &(&1.account == "checking"))

      # Second transaction: "bank" -> "Assets:Bank:Checking"
      assert Enum.any?(txn2.postings, &(&1.account == "Assets:Bank:Checking"))
      refute Enum.any?(txn2.postings, &(&1.account == "bank"))
    end

    test "alias chain expansion during parsing" do
      input = """
      account Assets:Checking
              alias checking
      alias bank = checking

      2024/01/15 Deposit
          bank                    $500.00
          Income:Salary
      """

      {:ok, %{transactions: transactions, accounts: accounts}} = LedgerParser.parse_ledger(input, base_dir: ".")

      # Verify canonical account has correct type
      assert accounts["Assets:Checking"] == :asset

      # Verify alias chain in accounts map
      assert accounts["checking"] == "Assets:Checking"
      assert accounts["bank"] == "Assets:Checking"

      # Verify "bank" resolves to canonical account in transaction
      [transaction] = transactions
      posting_accounts = Enum.map(transaction.postings, & &1.account)
      assert "Assets:Checking" in posting_accounts
      refute "bank" in posting_accounts
      refute "checking" in posting_accounts
    end

    test "multi-currency transaction with aliases" do
      # Multi-currency with cost syntax for proper balance
      input = """
      account Assets:Wise:USD  ; type:asset
              alias wise_usd
      account Assets:Wise:CHF  ; type:asset
              alias wise_chf

      2024/01/15 Currency Exchange
          wise_usd                $100.00 @ 0.90 CHF
          wise_chf                CHF -90.00
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, base_dir: ".")

      [transaction] = transactions
      posting_accounts = Enum.map(transaction.postings, & &1.account)

      assert "Assets:Wise:USD" in posting_accounts
      assert "Assets:Wise:CHF" in posting_accounts
      refute "wise_usd" in posting_accounts
      refute "wise_chf" in posting_accounts
    end

    test "balance calculation with alias-expanded transactions" do
      input = """
      account Assets:Cash  ; type:asset
              alias cash
      account Expenses:Food  ; type:expense
              alias food

      2024/01/15 Grocery Store
          food                    $50.00
          cash

      2024/01/16 Restaurant
          food                    $30.00
          cash
      """

      {:ok, %{transactions: transactions}} = LedgerParser.parse_ledger(input, base_dir: ".")
      balances = ExLedger.balance(transactions)

      # Balances should use canonical account names
      assert Map.has_key?(balances, "Expenses:Food")
      assert Map.has_key?(balances, "Assets:Cash")
      refute Map.has_key?(balances, "food")
      refute Map.has_key?(balances, "cash")

      # Verify amounts are combined correctly
      [%{amount: food_balance, currency: "$"}] = balances["Expenses:Food"]
      [%{amount: cash_balance, currency: "$"}] = balances["Assets:Cash"]
      assert Decimal.eq?(food_balance, Decimal.new(80))
      assert Decimal.eq?(cash_balance, Decimal.new(-80))
    end
  end

  describe "format_balance/2 - zero balance filtering" do
    test "hides zero-balance accounts by default" do
      balances = %{
        "Assets:Cash" => [%{amount: 100.0, currency: "$"}],
        "Assets:Bank" => [%{amount: 0.0, currency: "$"}],
        "Expenses:Food" => [%{amount: 50.0, currency: "$"}],
        "Income:Salary" => [%{amount: -150.0, currency: "$"}]
      }

      result = LedgerParser.format_balance(balances, false)

      # Should include non-zero accounts
      assert result =~ "Cash"
      assert result =~ "Expenses:Food"
      assert result =~ "Income:Salary"

      # Should NOT include zero-balance account
      refute result =~ "Bank"
    end

    test "shows zero-balance accounts when show_empty is true" do
      balances = %{
        "Assets:Cash" => [%{amount: 100.0, currency: "$"}],
        "Assets:Bank" => [%{amount: 0.0, currency: "$"}],
        "Expenses:Food" => [%{amount: 50.0, currency: "$"}],
        "Income:Salary" => [%{amount: -150.0, currency: "$"}]
      }

      result = LedgerParser.format_balance(balances, true)

      # Should include all accounts
      assert result =~ "Cash"
      assert result =~ "Bank"
      assert result =~ "Expenses:Food"
      assert result =~ "Income:Salary"
    end

    test "hides zero-balance accounts by default (using default parameter)" do
      balances = %{
        "Assets:Cash" => [%{amount: 100.0, currency: "$"}],
        "Assets:Bank" => [%{amount: 0.0, currency: "$"}]
      }

      result = LedgerParser.format_balance(balances)

      # Should include non-zero account
      assert result =~ "Cash"

      # Should NOT include zero-balance account
      refute result =~ "Bank"
    end

    test "suppresses totals when show_total is false" do
      balances = %{
        "Assets:Cash" => [%{amount: 100.0, currency: "$"}],
        "Expenses:Food" => [%{amount: -100.0, currency: "$"}]
      }

      result = LedgerParser.format_balance(balances, show_total: false)

      refute result =~ "--------------------"
    end

    test "formats flat balance without parent accounts" do
      balances = %{
        "Assets:Checking" => [%{amount: 50.0, currency: "$"}],
        "Assets:Savings" => [%{amount: 25.0, currency: "$"}]
      }

      result = LedgerParser.format_balance(balances, flat: true, show_total: false)

      assert result =~ "Assets:Checking"
      assert result =~ "Assets:Savings"
      refute result =~ "  Assets\n"
    end
  end

  describe "balance_report/3" do
    test "shows parent accounts for filtered queries" do
      transactions = [
        %{
          kind: :regular,
          date: ~D[2024-01-01],
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: "Paycheck",
          comment: nil,
          predicate: nil,
          period: nil,
          postings: [
            %{
              account: "Assets:Checking",
              amount: %{value: 100.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            },
            %{
              account: "Income:Salary",
              amount: %{value: -100.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        }
      ]

      result = LedgerParser.balance_report(transactions, ~r/Checking/, show_total: false)

      # When showing parent accounts, displays hierarchically:
      # "Assets" (parent) and "Checking" (child), not "Assets:Checking"
      assert result =~ "Checking"
      assert result =~ "Assets"
    end
  end

  describe "check_file/1" do
    test "returns true for a valid ledger file" do
      path = Path.join(System.tmp_dir!(), "valid.ledger")

      File.write!(path, """
      2024/01/15 Grocery Store
          Expenses:Groceries          $50.00
          Assets:Checking
      """)

      assert LedgerParser.check_file(path)
    end

    test "returns false for a fixture with missing includes" do
      path = Path.expand("fixtures/main_includes.ledger", __DIR__)

      refute LedgerParser.check_file(path)
    end

    test "returns false for an invalid ledger file" do
      path = Path.join(System.tmp_dir!(), "invalid.ledger")
      File.write!(path, "not a ledger file")

      refute LedgerParser.check_file(path)
    end
  end

  describe "parse_ledger/2 - bookings.ledger format" do
    test "parses single transaction WITHOUT comma separators (works)" do
      # Test without commas - this should work
      input = """
      2024/01/01 Opening Balance
          Assets:Checking              $5000.00
          Assets:Savings               $10000.00
          Equity:OpeningBalances
      """

      result = LedgerParser.parse_transaction(input)

      case result do
        {:ok, transaction} ->
          assert transaction.date == ~D[2024-01-01]
          assert transaction.payee == "Opening Balance"
          assert length(transaction.postings) == 3

          # Check auto-balanced posting
          equity_posting =
            Enum.find(transaction.postings, fn p -> p.account == "Equity:OpeningBalances" end)

          assert Decimal.eq?(equity_posting.amount.value, Decimal.from_float(-15_000.00))
          assert equity_posting.amount.currency == "$"

        {:error, reason} ->
          flunk("Expected successful parse but got error: #{inspect(reason)}")
      end
    end

    test "parses single transaction WITH comma separators (currently fails)" do
      # Test WITH commas - this reproduces the bookings.ledger bug
      input = """
      2024/01/01 Opening Balance
          Assets:Checking              $5,000.00
          Assets:Savings               $10,000.00
          Equity:OpeningBalances
      """

      result = LedgerParser.parse_transaction(input)

      case result do
        {:ok, transaction} ->
          assert transaction.date == ~D[2024-01-01]
          assert transaction.payee == "Opening Balance"
          assert length(transaction.postings) == 3

          # Check auto-balanced posting
          equity_posting =
            Enum.find(transaction.postings, fn p -> p.account == "Equity:OpeningBalances" end)

          assert Decimal.eq?(equity_posting.amount.value, Decimal.from_float(-15_000.00))
          assert equity_posting.amount.currency == "$"

        {:error, reason} ->
          flunk("Expected successful parse but got error: #{inspect(reason)}")
      end
    end

    test "parses bookings.ledger with auto-balanced postings" do
      # This is the format used in accountguru's bookings.ledger files
      input = """
      2024/01/01 Opening Balance
          Assets:Checking              $5,000.00
          Assets:Savings               $10,000.00
          Equity:OpeningBalances

      2024/01/05 Salary
          Assets:Checking              $4,500.00
          Income:Salary

      2024/01/10 Rent Payment
          Expenses:Rent                $1,200.00
          Assets:Checking

      2024/01/15 Credit Card Purchase
          Expenses:Rent                $100.00
          Liabilities:CreditCard
      """

      result = LedgerParser.parse_ledger(input, source_file: "bookings.ledger")

      case result do
        {:ok, %{transactions: transactions}} ->
          assert length(transactions) == 4

          # Check first transaction
          [t1, _t2, _t3, _t4] = transactions
          assert t1.date == ~D[2024-01-01]
          assert t1.payee == "Opening Balance"
          assert length(t1.postings) == 3

          # Check auto-balanced posting
          equity_posting =
            Enum.find(t1.postings, fn p -> p.account == "Equity:OpeningBalances" end)

          assert Decimal.eq?(equity_posting.amount.value, Decimal.from_float(-15_000.00))
          assert equity_posting.amount.currency == "$"

        {:error, {reason, line, file}} ->
          flunk(
            "Expected successful parse but got error: #{inspect(reason)} at line #{line} in #{file}"
          )

        {:error, error} ->
          flunk("Expected successful parse but got error: #{inspect(error)}")
      end
    end
  end

  describe "journal report helpers" do
    setup do
      transactions = [
        %{
          date: ~D[2024-01-01],
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: "Coffee Shop",
          comment: nil,
          postings: [
            %{
              account: "Expenses:Food",
              amount: %{value: 5.0, currency: "$"},
              metadata: %{},
              tags: ["meal"],
              comments: []
            },
            %{
              account: "Assets:Cash",
              amount: %{value: -5.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        },
        %{
          date: ~D[2024-01-10],
          aux_date: nil,
          state: :uncleared,
          code: "PAY",
          payee: "Employer",
          comment: nil,
          postings: [
            %{
              account: "Assets:Cash",
              amount: %{value: 1200.0, currency: "EUR"},
              metadata: %{},
              tags: ["salary"],
              comments: []
            },
            %{
              account: "Income:Salary",
              amount: %{value: -1200.0, currency: "EUR"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        }
      ]

      accounts = %{
        "Assets:Cash" => :asset,
        "Expenses:Food" => :expense,
        "Income:Salary" => :revenue,
        "Assets:Checking" => :asset
      }

      {:ok, transactions: transactions, accounts: accounts}
    end

    test "lists accounts including declarations", %{
      transactions: transactions,
      accounts: accounts
    } do
      result = LedgerParser.list_accounts(transactions, accounts)

      assert result == [
               "Assets:Cash",
               "Assets:Checking",
               "Expenses:Food",
               "Income:Salary"
             ]
    end

    test "lists payees", %{transactions: transactions} do
      assert LedgerParser.list_payees(transactions) == ["Coffee Shop", "Employer"]
    end

    test "lists commodities", %{transactions: transactions} do
      assert LedgerParser.list_commodities(transactions) == ["$", "EUR"]
    end

    test "lists tags", %{transactions: transactions} do
      assert LedgerParser.list_tags(transactions) == ["meal", "salary"]
    end

    test "returns earliest transaction", %{transactions: transactions} do
      transaction = LedgerParser.first_transaction(transactions)

      assert transaction.date == ~D[2024-01-01]
      assert transaction.payee == "Coffee Shop"
    end

    test "returns latest transaction", %{transactions: transactions} do
      transaction = LedgerParser.last_transaction(transactions)

      assert transaction.date == ~D[2024-01-10]
      assert transaction.payee == "Employer"
    end

    test "builds stats summary", %{transactions: transactions} do
      stats = LedgerParser.stats(transactions)

      assert stats.time_range == {~D[2024-01-01], ~D[2024-01-10]}
      assert stats.unique_accounts == 3
      assert stats.unique_payees == 2
      assert stats.postings_total == 4
    end

    test "runs select query", %{transactions: transactions} do
      query = "date,payee,account,amount from posts where account=~/Expenses/"

      assert {:ok, fields, rows} = LedgerParser.select(transactions, query)
      assert fields == ["date", "payee", "account", "amount"]
      assert length(rows) == 1
      assert Enum.at(rows, 0)["account"] == "Expenses:Food"
    end

    test "builds xact output", %{transactions: transactions} do
      assert {:ok, output} = LedgerParser.build_xact(transactions, ~D[2024-02-01], "Coffee")
      assert String.starts_with?(output, "2024/02/01 Coffee Shop")
    end
  end

  describe "budgeting and forecasting" do
    test "builds budget report from periodic transactions" do
      transactions = [
        %{
          kind: :periodic,
          date: nil,
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: nil,
          comment: nil,
          predicate: nil,
          period: "Monthly",
          postings: [
            %{
              account: "Expenses:Rent",
              amount: %{value: 1000.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            },
            %{
              account: "Assets:Checking",
              amount: %{value: -1000.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        },
        %{
          kind: :regular,
          date: ~D[2024-01-10],
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: "Rent",
          comment: nil,
          predicate: nil,
          period: nil,
          postings: [
            %{
              account: "Expenses:Rent",
              amount: %{value: 900.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            },
            %{
              account: "Assets:Checking",
              amount: %{value: -900.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        }
      ]

      rows = LedgerParser.budget_report(transactions, ~D[2024-01-15])
      rent_row = Enum.find(rows, fn row -> row.account == "Expenses:Rent" end)

      assert Decimal.eq?(rent_row.actual, Decimal.new(900))
      assert Decimal.eq?(rent_row.budget, Decimal.new(1000))
      assert Decimal.eq?(rent_row.remaining, Decimal.new(100))
    end

    test "forecasts balances using periodic transactions" do
      transactions = [
        %{
          kind: :periodic,
          date: nil,
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: nil,
          comment: nil,
          predicate: nil,
          period: "Monthly",
          postings: [
            %{
              account: "Assets:Checking",
              amount: %{value: 100.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            },
            %{
              account: "Income:Salary",
              amount: %{value: -100.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        },
        %{
          kind: :regular,
          date: ~D[2024-01-01],
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: "Opening",
          comment: nil,
          predicate: nil,
          period: nil,
          postings: [
            %{
              account: "Assets:Checking",
              amount: %{value: 50.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            },
            %{
              account: "Income:Salary",
              amount: %{value: -50.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        }
      ]

      forecast = LedgerParser.forecast_balance(transactions, 2)

      assert Decimal.eq?(forecast["Assets:Checking"] |> hd() |> Map.get(:amount), Decimal.new(250))
      assert Decimal.eq?(forecast["Income:Salary"] |> hd() |> Map.get(:amount), Decimal.new(-250))
    end
  end

  describe "timeclock parsing" do
    test "parses timeclock entries and summarizes hours" do
      input = """
      i 2024/03/01 09:00:00 Work:Project  Client A
      o 2024/03/01 17:30:00
      """

      entries = LedgerParser.parse_timeclock_entries(input)
      assert length(entries) == 1

      report = LedgerParser.timeclock_report(entries)

      assert_in_delta report["Work:Project"], 8.5, 0.01
    end

    test "warns about unclosed timeclock entries" do
      input = """
      i 2024/03/01 09:00:00 Work:Project  Client A
      i 2024/03/01 10:00:00 Work:Admin  Admin tasks
      """

      # Capture stderr to check for warning
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          entries = LedgerParser.parse_timeclock_entries(input)
          # No checkout, so no completed entries
          assert Enum.empty?(entries)
        end)

      # Should warn about 2 unclosed entries
      assert output =~ "Warning: 2 unclosed timeclock check-in(s)"
      assert output =~ "Work:Project"
      assert output =~ "Work:Admin"
    end

    test "handles multiple unclosed entries" do
      input = """
      i 2024/03/01 09:00:00 Work:Project  Client A
      i 2024/03/01 10:00:00 Work:Admin  Admin tasks
      i 2024/03/01 11:00:00 Work:Meeting  Team meeting
      """

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          entries = LedgerParser.parse_timeclock_entries(input)
          # No checkout, so no completed entries
          assert Enum.empty?(entries)
        end)

      # Should warn about 3 unclosed entries
      assert output =~ "Warning: 3 unclosed timeclock check-in(s)"
      assert output =~ "Work:Project"
      assert output =~ "Work:Admin"
      assert output =~ "Work:Meeting"
    end
  end

  describe "balance_by_period/5" do
    setup do
      transactions = [
        %{
          kind: :regular,
          date: ~D[2024-01-15],
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: "Grocery Store",
          comment: nil,
          predicate: nil,
          period: nil,
          postings: [
            %{
              account: "Expenses:Food",
              amount: %{value: 100.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            },
            %{
              account: "Assets:Cash",
              amount: %{value: -100.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        },
        %{
          kind: :regular,
          date: ~D[2024-01-25],
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: "Restaurant",
          comment: nil,
          predicate: nil,
          period: nil,
          postings: [
            %{
              account: "Expenses:Food",
              amount: %{value: 50.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            },
            %{
              account: "Assets:Cash",
              amount: %{value: -50.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        },
        %{
          kind: :regular,
          date: ~D[2024-02-10],
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: "Coffee Shop",
          comment: nil,
          predicate: nil,
          period: nil,
          postings: [
            %{
              account: "Expenses:Food",
              amount: %{value: 25.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            },
            %{
              account: "Assets:Cash",
              amount: %{value: -25.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        },
        %{
          kind: :regular,
          date: ~D[2024-03-05],
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: "Supermarket",
          comment: nil,
          predicate: nil,
          period: nil,
          postings: [
            %{
              account: "Expenses:Food",
              amount: %{value: 75.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            },
            %{
              account: "Assets:Cash",
              amount: %{value: -75.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        }
      ]

      {:ok, transactions: transactions}
    end

    test "returns empty result for empty transactions list" do
      result = LedgerParser.balance_by_period([], "monthly")
      assert result == %{"periods" => [], "balances" => %{}}
    end

    test "returns empty result when group_by is 'none'" do
      transactions = [
        %{
          kind: :regular,
          date: ~D[2024-01-15],
          postings: [
            %{account: "Assets:Cash", amount: %{value: 100.0, currency: "$"}}
          ]
        }
      ]

      result = LedgerParser.balance_by_period(transactions, "none")
      assert result == %{"periods" => [], "balances" => %{}}
    end

    test "calculates monthly balances correctly", %{transactions: transactions} do
      result = LedgerParser.balance_by_period(transactions, "monthly")

      periods = result["periods"]
      balances = result["balances"]

      # Should have 3 periods (Jan, Feb, Mar 2024)
      assert length(periods) == 3
      assert Enum.at(periods, 0).label == "2024-01"
      assert Enum.at(periods, 1).label == "2024-02"
      assert Enum.at(periods, 2).label == "2024-03"

      # January: $100 + $50 = $150 food, -$150 cash
      jan_balances = balances["2024-01"]
      assert Decimal.eq?(jan_balances["Expenses:Food"] |> hd() |> Map.get(:amount), Decimal.new(150))
      assert Decimal.eq?(jan_balances["Assets:Cash"] |> hd() |> Map.get(:amount), Decimal.new(-150))

      # February: cumulative = Jan + Feb = $150 + $25 = $175 food, -$175 cash
      feb_balances = balances["2024-02"]
      assert Decimal.eq?(feb_balances["Expenses:Food"] |> hd() |> Map.get(:amount), Decimal.new(175))
      assert Decimal.eq?(feb_balances["Assets:Cash"] |> hd() |> Map.get(:amount), Decimal.new(-175))

      # March: cumulative = Jan + Feb + Mar = $175 + $75 = $250 food, -$250 cash
      mar_balances = balances["2024-03"]
      assert Decimal.eq?(mar_balances["Expenses:Food"] |> hd() |> Map.get(:amount), Decimal.new(250))
      assert Decimal.eq?(mar_balances["Assets:Cash"] |> hd() |> Map.get(:amount), Decimal.new(-250))
    end

    test "calculates quarterly balances correctly", %{transactions: transactions} do
      result = LedgerParser.balance_by_period(transactions, "quarterly")

      periods = result["periods"]
      balances = result["balances"]

      # Should have 1 period (Q1 2024)
      assert length(periods) == 1
      assert Enum.at(periods, 0).label == "2024 Q1"

      # Q1: all transactions = $100 + $50 + $25 + $75 = $250 food, -$250 cash
      q1_balances = balances["2024 Q1"]
      assert Decimal.eq?(q1_balances["Expenses:Food"] |> hd() |> Map.get(:amount), Decimal.new(250))
      assert Decimal.eq?(q1_balances["Assets:Cash"] |> hd() |> Map.get(:amount), Decimal.new(-250))
    end

    test "calculates yearly balances correctly", %{transactions: transactions} do
      result = LedgerParser.balance_by_period(transactions, "yearly")

      periods = result["periods"]
      balances = result["balances"]

      # Should have 1 period (2024)
      assert length(periods) == 1
      assert Enum.at(periods, 0).label == "2024"

      # 2024: all transactions = $250 food, -$250 cash
      year_balances = balances["2024"]
      assert Decimal.eq?(year_balances["Expenses:Food"] |> hd() |> Map.get(:amount), Decimal.new(250))
      assert Decimal.eq?(year_balances["Assets:Cash"] |> hd() |> Map.get(:amount), Decimal.new(-250))
    end

    test "groups yearly balances without carrying prior years" do
      transactions = [
        %{
          kind: :regular,
          date: ~D[2024-06-01],
          postings: [
            %{account: "Expenses:Food", amount: %{value: Decimal.new(40), currency: "$"}},
            %{account: "Assets:Cash", amount: %{value: Decimal.new(-40), currency: "$"}}
          ]
        },
        %{
          kind: :regular,
          date: ~D[2025-01-10],
          postings: [
            %{account: "Expenses:Food", amount: %{value: Decimal.new(60), currency: "$"}},
            %{account: "Assets:Cash", amount: %{value: Decimal.new(-60), currency: "$"}}
          ]
        }
      ]

      result = LedgerParser.balance_by_period(transactions, "yearly")

      periods = result["periods"]
      balances = result["balances"]

      assert Enum.map(periods, & &1.label) == ["2024", "2025"]

      year_2024 = balances["2024"]
      assert Decimal.eq?(year_2024["Expenses:Food"] |> hd() |> Map.get(:amount), Decimal.new(40))
      assert Decimal.eq?(year_2024["Assets:Cash"] |> hd() |> Map.get(:amount), Decimal.new(-40))

      year_2025 = balances["2025"]
      assert Decimal.eq?(year_2025["Expenses:Food"] |> hd() |> Map.get(:amount), Decimal.new(60))
      assert Decimal.eq?(year_2025["Assets:Cash"] |> hd() |> Map.get(:amount), Decimal.new(-60))
    end

    test "applies account filter correctly", %{transactions: transactions} do
      # Filter to only show Expenses:Food
      filter = fn account -> String.starts_with?(account, "Expenses:") end
      result = LedgerParser.balance_by_period(transactions, "monthly", nil, nil, filter)

      balances = result["balances"]

      # January balances should only include Expenses:Food
      jan_balances = balances["2024-01"]
      assert Map.has_key?(jan_balances, "Expenses:Food")
      refute Map.has_key?(jan_balances, "Assets:Cash")
      assert Decimal.eq?(jan_balances["Expenses:Food"] |> hd() |> Map.get(:amount), Decimal.new(150))
    end

    test "respects start_date parameter" do
      transactions = [
        %{
          kind: :regular,
          date: ~D[2024-01-15],
          postings: [
            %{account: "Expenses:Food", amount: %{value: 100.0, currency: "$"}},
            %{account: "Assets:Cash", amount: %{value: -100.0, currency: "$"}}
          ]
        },
        %{
          kind: :regular,
          date: ~D[2024-02-15],
          postings: [
            %{account: "Expenses:Food", amount: %{value: 50.0, currency: "$"}},
            %{account: "Assets:Cash", amount: %{value: -50.0, currency: "$"}}
          ]
        }
      ]

      # Start from February
      result = LedgerParser.balance_by_period(transactions, "monthly", ~D[2024-02-01], nil, nil)

      periods = result["periods"]

      # Should only have February period
      assert length(periods) == 1
      assert Enum.at(periods, 0).label == "2024-02"
    end

    test "respects end_date parameter" do
      transactions = [
        %{
          kind: :regular,
          date: ~D[2024-01-15],
          postings: [
            %{account: "Expenses:Food", amount: %{value: 100.0, currency: "$"}},
            %{account: "Assets:Cash", amount: %{value: -100.0, currency: "$"}}
          ]
        },
        %{
          kind: :regular,
          date: ~D[2024-02-15],
          postings: [
            %{account: "Expenses:Food", amount: %{value: 50.0, currency: "$"}},
            %{account: "Assets:Cash", amount: %{value: -50.0, currency: "$"}}
          ]
        }
      ]

      # End at January
      result = LedgerParser.balance_by_period(transactions, "monthly", nil, ~D[2024-01-31], nil)

      periods = result["periods"]

      # Should only have January period
      assert length(periods) == 1
      assert Enum.at(periods, 0).label == "2024-01"
    end

    test "handles multiple currencies correctly" do
      transactions = [
        %{
          kind: :regular,
          date: ~D[2024-01-15],
          postings: [
            %{account: "Expenses:Food", amount: %{value: 100.0, currency: "$"}},
            %{account: "Assets:Cash", amount: %{value: -100.0, currency: "$"}}
          ]
        },
        %{
          kind: :regular,
          date: ~D[2024-01-20],
          postings: [
            %{account: "Expenses:Food", amount: %{value: 50.0, currency: "EUR"}},
            %{account: "Assets:Cash", amount: %{value: -50.0, currency: "EUR"}}
          ]
        }
      ]

      result = LedgerParser.balance_by_period(transactions, "monthly")

      balances = result["balances"]
      jan_balances = balances["2024-01"]

      # With multi-currency fix: Each currency is tracked separately
      food_expenses = jan_balances["Expenses:Food"]
      usd_food = Enum.find(food_expenses, fn a -> a.currency == "$" end)
      eur_food = Enum.find(food_expenses, fn a -> a.currency == "EUR" end)

      assert Decimal.eq?(usd_food.amount, Decimal.from_float(100.0))
      assert Decimal.eq?(eur_food.amount, Decimal.from_float(50.0))

      cash_balances = jan_balances["Assets:Cash"]
      usd_cash = Enum.find(cash_balances, fn a -> a.currency == "$" end)
      eur_cash = Enum.find(cash_balances, fn a -> a.currency == "EUR" end)

      assert Decimal.eq?(usd_cash.amount, Decimal.from_float(-100.0))
      assert Decimal.eq?(eur_cash.amount, Decimal.from_float(-50.0))
    end

    test "filters out non-regular transactions" do
      transactions = [
        %{
          kind: :regular,
          date: ~D[2024-01-15],
          postings: [
            %{account: "Expenses:Food", amount: %{value: Decimal.from_float(100.0), currency: "$"}},
            %{account: "Assets:Cash", amount: %{value: Decimal.from_float(-100.0), currency: "$"}}
          ]
        },
        %{
          kind: :periodic,
          date: nil,
          period: "Monthly",
          postings: [
            %{account: "Expenses:Rent", amount: %{value: Decimal.from_float(1000.0), currency: "$"}},
            %{account: "Assets:Cash", amount: %{value: Decimal.from_float(-1000.0), currency: "$"}}
          ]
        },
        %{
          kind: :automated,
          date: ~D[2024-01-20],
          predicate: "expr true",
          postings: [
            %{account: "Expenses:Fee", amount: %{value: 5.0, currency: "$"}},
            %{account: "Assets:Cash", amount: %{value: -5.0, currency: "$"}}
          ]
        }
      ]

      result = LedgerParser.balance_by_period(transactions, "monthly")

      balances = result["balances"]
      jan_balances = balances["2024-01"]

      # Should only include regular transaction
      assert Decimal.eq?(jan_balances["Expenses:Food"] |> hd() |> Map.get(:amount), Decimal.new(100))
      refute Map.has_key?(jan_balances, "Expenses:Rent")
      refute Map.has_key?(jan_balances, "Expenses:Fee")
    end

    test "performance: processes each transaction only once" do
      # Create a large dataset to test performance
      # Generate 365 daily transactions
      transactions =
        Enum.map(1..365, fn day_offset ->
          date = Date.add(~D[2024-01-01], day_offset - 1)

          %{
            kind: :regular,
            date: date,
            aux_date: nil,
            state: :uncleared,
            code: "",
            payee: "Transaction #{day_offset}",
            comment: nil,
            predicate: nil,
            period: nil,
            postings: [
              %{
                account: "Expenses:Daily",
                amount: %{value: 10.0, currency: "$"},
                metadata: %{},
                tags: [],
                comments: []
              },
              %{
                account: "Assets:Cash",
                amount: %{value: -10.0, currency: "$"},
                metadata: %{},
                tags: [],
                comments: []
              }
            ]
          }
        end)

      # Time the execution
      {time_micro, result} =
        :timer.tc(fn ->
          LedgerParser.balance_by_period(transactions, "monthly")
        end)

      # Should complete in reasonable time (< 100ms for 365 transactions over 12 months)
      # With old O(N²) algorithm, this would take much longer
      assert time_micro < 100_000, "Expected < 100ms, got #{time_micro / 1000}ms"

      # Verify correctness
      balances = result["balances"]
      periods = result["periods"]

      # Should have 12 monthly periods
      assert length(periods) == 12

      # December should have cumulative balance of all 365 transactions
      dec_balances = balances["2024-12"]
      assert Decimal.eq?(dec_balances["Expenses:Daily"] |> hd() |> Map.get(:amount), Decimal.new(3650))
      assert Decimal.eq?(dec_balances["Assets:Cash"] |> hd() |> Map.get(:amount), Decimal.new(-3650))
    end
  end

end
