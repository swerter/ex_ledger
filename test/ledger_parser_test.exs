defmodule ExLedger.LedgerParserTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser

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

    test "requires minimum 2-space indentation for postings" do
      input = """
      2009/11/01 Panera Bread
       Expenses:Food               $4.50
       Assets:Checking
      """

      assert {:error, :invalid_indentation} = LedgerParser.parse_transaction(input)
    end

    test "accepts postings with 2-space indentation" do
      input = """
      2009/11/01 Panera Bread
        Expenses:Food               $4.50
        Assets:Checking
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)
      assert length(transaction.postings) == 2
    end

    test "accepts postings with 4-space indentation" do
      input = """
      2009/11/01 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)
      assert length(transaction.postings) == 2
    end

    test "accepts postings with tab indentation" do
      input = "2009/11/01 Panera Bread\n\tExpenses:Food               $4.50\n\tAssets:Checking\n"

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)
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

    test "accepts 2 or more spaces between account and amount" do
      input = """
      2009/11/01 Panera Bread
          Expenses:Food  $4.50
          Assets:Checking
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)
      assert Enum.at(transaction.postings, 0).amount == %{value: 4.50, currency: "$"}
    end

    test "parses account names with spaces when properly separated from amount" do
      input = """
      2009/11/01 Store Purchase
          Expenses:Home Improvement  $125.50
          Assets:Checking
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

      [posting1, posting2] = transaction.postings
      assert posting1.account == "Expenses:Home Improvement"
      assert posting1.amount == %{value: 125.50, currency: "$"}
      assert posting2.account == "Assets:Checking"
    end

    test "parses multi-word account names with multiple spaces in name" do
      input = """
      2009/11/01 Credit Card Payment
          Liabilities:Credit Card Account  $50.00
          Assets:Checking Account
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

      [posting1, posting2] = transaction.postings
      assert posting1.account == "Liabilities:Credit Card Account"
      assert posting1.amount == %{value: 50.00, currency: "$"}
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

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

      assert transaction.date == ~D[2009-10-29]
      assert transaction.code == "XFER"
      assert transaction.payee == "Panera Bread"
      assert length(transaction.postings) == 2

      [posting1, posting2] = transaction.postings

      assert posting1.account == "Expenses:Food"
      assert posting1.amount == %{value: 4.50, currency: "$"}

      assert posting2.account == "Assets:Checking"
      # Should be automatically calculated as negative of first posting
      assert posting2.amount == %{value: -4.50, currency: "$"}
    end

    test "parses transaction with DEP code and income deposit" do
      input = """
      2009/10/30 (DEP) Pay day!
          Assets:Checking            $20.00
          Income
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

      assert transaction.date == ~D[2009-10-30]
      assert transaction.code == "DEP"
      assert transaction.payee == "Pay day!"
      assert length(transaction.postings) == 2

      [posting1, posting2] = transaction.postings

      assert posting1.account == "Assets:Checking"
      assert posting1.amount == %{value: 20.00, currency: "$"}

      assert posting2.account == "Income"
      # Should be automatically calculated as negative of first posting
      assert posting2.amount == %{value: -20.00, currency: "$"}
    end

    test "parses transaction with long hexadecimal code" do
      input = """
      2009/10/31 (559385768438A8D7) Panera Bread
          Expenses:Food               $4.50
          Liabilities:Credit Card
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

      assert transaction.date == ~D[2009-10-31]
      assert transaction.code == "559385768438A8D7"
      assert transaction.payee == "Panera Bread"
      assert length(transaction.postings) == 2

      [posting1, posting2] = transaction.postings

      assert posting1.account == "Expenses:Food"
      assert posting1.amount == %{value: 4.50, currency: "$"}

      assert posting2.account == "Liabilities:Credit Card"
      # Should be automatically calculated as negative of first posting
      assert posting2.amount == %{value: -4.50, currency: "$"}
    end

    test "parses transaction without code" do
      input = """
      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

      assert transaction.date == ~D[2009-10-29]
      assert transaction.code == ""
      assert transaction.payee == "Panera Bread"

      [_posting1, posting2] = transaction.postings
      assert posting2.amount == %{value: -4.50, currency: "$"}
    end

    test "parses transaction with both amounts specified" do
      input = """
      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking            -$4.50
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

      [posting1, posting2] = transaction.postings

      assert posting1.amount == %{value: 4.50, currency: "$"}
      assert posting2.amount == %{value: -4.50, currency: "$"}
    end

    test "parses transaction with payee and comment" do
      input = """
      2009/11/01 Panera Bread  ; Got something to eat
          Expenses:Food               $4.50
          Assets:Checking
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

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

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

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

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

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

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

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

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

      [posting1, _posting2] = transaction.postings

      assert posting1.metadata == %{
               "Type" => "Dining",
               "Location" => "Downtown",
               "Payment" => "Cash"
             }
    end

    test "parses transaction at sign in description" do
      input = """
      2025/01/10 LUFTHANSA-GRO 131.91 EUR @0.91677
        ; todo: file missing
        5 Personal:58 Other:5880 Other Personal expenses  CHF 60.18
        1 Assets:10 Turnover:1022 Abb                          USD -136.30
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)

      assert transaction.date == ~D[2025-01-10]
      assert transaction.code == ""
      assert transaction.payee == "LUFTHANSA-GRO 131.91 EUR @0.91677"
      assert length(transaction.postings) == 2

      [posting1, posting2] = transaction.postings

      assert posting1.account == "5 Personal:58 Other:5880 Other Personal expenses"
      assert posting1.amount == %{value: 60.18, currency: "CHF"}

      assert posting2.account == "1 Assets:10 Turnover:1022 Abb"
      # Should be automatically calculated as negative of first posting
      assert posting2.amount == %{value: -136.30, currency: "USD"}

      balance_should_txt = """
      USD -136.30  1 Assets:10 Turnover:1022 Abb
        CHF 60.18  5 Personal:58 Other:5880 Other Personal expenses
      --------------------
        CHF 60.18
      USD -136.30
      """

      balance_txt =
        transaction
        |> ExLedger.LedgerParser.balance()
        |> ExLedger.LedgerParser.format_balance()

      assert balance_txt == balance_should_txt
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
      assert {:error, _reason} = LedgerParser.parse_date("2009-10-29")
    end
  end

  describe "parse_posting/1" do
    test "parses posting with amount" do
      input = "    Expenses:Food               $4.50"

      assert {:ok, posting} = LedgerParser.parse_posting(input)

      assert posting.account == "Expenses:Food"
      assert posting.amount == %{value: 4.50, currency: "$"}
    end

    test "parses posting without amount (to be auto-balanced)" do
      input = "    Assets:Checking"

      assert {:ok, posting} = LedgerParser.parse_posting(input)

      assert posting.account == "Assets:Checking"
      assert posting.amount == nil
    end

    test "parses posting with negative amount" do
      input = "    Assets:Checking            -$4.50"

      assert {:ok, posting} = LedgerParser.parse_posting(input)

      assert posting.account == "Assets:Checking"
      assert posting.amount == %{value: -4.50, currency: "$"}
    end

    test "parses posting with multi-level account" do
      input = "    Liabilities:Credit Card     $4.50"

      assert {:ok, posting} = LedgerParser.parse_posting(input)

      assert posting.account == "Liabilities:Credit Card"
      assert posting.amount == %{value: 4.50, currency: "$"}
    end

    test "parses posting with different amounts" do
      assert {:ok, posting} = LedgerParser.parse_posting("    Income    $20.00")
      assert posting.amount == %{value: 20.00, currency: "$"}
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

  describe "parse_amount/1" do
    test "parses dollar amounts with cents" do
      assert {:ok, %{value: 4.50, currency: "$"}} = LedgerParser.parse_amount("$4.50")
      assert {:ok, %{value: 20.00, currency: "$"}} = LedgerParser.parse_amount("$20.00")
    end

    test "parses negative dollar amounts" do
      assert {:ok, %{value: -4.50, currency: "$"}} = LedgerParser.parse_amount("-$4.50")
      assert {:ok, %{value: -20.00, currency: "$"}} = LedgerParser.parse_amount("-$20.00")
    end

    test "parses dollar amounts without cents" do
      assert {:ok, %{value: 4.0, currency: "$"}} = LedgerParser.parse_amount("$4")
      assert {:ok, %{value: 20.0, currency: "$"}} = LedgerParser.parse_amount("$20")
    end

    test "returns error for invalid amounts" do
      assert {:error, _reason} = LedgerParser.parse_amount("invalid")
      assert {:error, _reason} = LedgerParser.parse_amount("")
    end
  end

  describe "balance_postings/1" do
    test "balances postings when second amount is nil" do
      postings = [
        %{account: "Expenses:Food", amount: %{value: 4.50, currency: "$"}},
        %{account: "Assets:Checking", amount: nil}
      ]

      result = LedgerParser.balance_postings(postings)

      assert Enum.at(result, 1).amount == %{value: -4.50, currency: "$"}
    end

    test "balances postings when first amount is nil" do
      postings = [
        %{account: "Assets:Checking", amount: nil},
        %{account: "Income", amount: %{value: 20.00, currency: "$"}}
      ]

      result = LedgerParser.balance_postings(postings)

      assert Enum.at(result, 0).amount == %{value: -20.00, currency: "$"}
    end

    test "does not modify postings when all amounts are specified" do
      postings = [
        %{account: "Expenses:Food", amount: %{value: 4.50, currency: "$"}},
        %{account: "Assets:Checking", amount: %{value: -4.50, currency: "$"}}
      ]

      result = LedgerParser.balance_postings(postings)

      assert result == postings
    end

    test "balances with multiple postings (one nil)" do
      postings = [
        %{account: "Expenses:Food", amount: %{value: 3.00, currency: "$"}},
        %{account: "Expenses:Drink", amount: %{value: 1.50, currency: "$"}},
        %{account: "Assets:Checking", amount: nil}
      ]

      result = LedgerParser.balance_postings(postings)

      assert Enum.at(result, 2).amount == %{value: -4.50, currency: "$"}
    end
  end

  describe "parse_ledger/1" do
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

      assert {:ok, transactions} = LedgerParser.parse_ledger(input)

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
          |> Enum.sum()

        assert_in_delta total, 0.0, 0.01
      end)
    end

    test "handles empty input" do
      assert {:ok, []} = LedgerParser.parse_ledger("")
      assert {:ok, []} = LedgerParser.parse_ledger("\n\n")
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

      assert {:error, {:missing_payee, 5}} = LedgerParser.parse_ledger(input)
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
  end

  describe "get_account_postings/2" do
    setup do
      transactions = [
        %{
          date: ~D[2009-10-29],
          code: "XFER",
          payee: "Panera Bread",
          postings: [
            %{account: "Expenses:Food", amount: %{value: 4.50, currency: "$"}},
            %{account: "Assets:Checking", amount: %{value: -4.50, currency: "$"}}
          ]
        },
        %{
          date: ~D[2009-10-30],
          code: "DEP",
          payee: "Pay day!",
          postings: [
            %{account: "Assets:Checking", amount: %{value: 20.00, currency: "$"}},
            %{account: "Income", amount: %{value: -20.00, currency: "$"}}
          ]
        },
        %{
          date: ~D[2009-10-30],
          code: "XFER",
          payee: "Panera Bread",
          postings: [
            %{account: "Expenses:Food", amount: %{value: 4.50, currency: "$"}},
            %{account: "Assets:Checking", amount: %{value: -4.50, currency: "$"}}
          ]
        },
        %{
          date: ~D[2009-10-31],
          code: "559385768438A8D7",
          payee: "Panera Bread",
          postings: [
            %{account: "Expenses:Food", amount: %{value: 4.50, currency: "$"}},
            %{account: "Liabilities:Credit Card", amount: %{value: -4.50, currency: "$"}}
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
      assert Enum.at(result, 0) == %{
               date: ~D[2009-10-29],
               description: "Panera Bread",
               account: "Expenses:Food",
               amount: 4.50,
               balance: 4.50
             }

      # Second posting: 09-Oct-30 Panera Bread   Expenses:Food       $4.50     $9.00
      assert Enum.at(result, 1) == %{
               date: ~D[2009-10-30],
               description: "Panera Bread",
               account: "Expenses:Food",
               amount: 4.50,
               balance: 9.00
             }

      # Third posting: 09-Oct-31 Panera Bread   Expenses:Food       $4.50     $13.50
      assert Enum.at(result, 2) == %{
               date: ~D[2009-10-31],
               description: "Panera Bread",
               account: "Expenses:Food",
               amount: 4.50,
               balance: 13.50
             }
    end

    test "returns postings for Assets:Checking account with running balance", %{
      transactions: transactions
    } do
      result = LedgerParser.get_account_postings(transactions, "Assets:Checking")

      assert length(result) == 3

      # First: 09-Oct-29 Panera Bread   Assets:Checking   -$4.50    -$4.50
      assert Enum.at(result, 0) == %{
               date: ~D[2009-10-29],
               description: "Panera Bread",
               account: "Assets:Checking",
               amount: -4.50,
               balance: -4.50
             }

      # Second: 09-Oct-30 Pay day!   Assets:Checking   $20.00    $15.50
      assert Enum.at(result, 1) == %{
               date: ~D[2009-10-30],
               description: "Pay day!",
               account: "Assets:Checking",
               amount: 20.00,
               balance: 15.50
             }

      # Third: 09-Oct-30 Panera Bread   Assets:Checking   -$4.50    $11.00
      assert Enum.at(result, 2) == %{
               date: ~D[2009-10-30],
               description: "Panera Bread",
               account: "Assets:Checking",
               amount: -4.50,
               balance: 11.00
             }
    end

    test "returns postings for Income account with running balance", %{transactions: transactions} do
      result = LedgerParser.get_account_postings(transactions, "Income")

      assert length(result) == 1

      assert Enum.at(result, 0) == %{
               date: ~D[2009-10-30],
               description: "Pay day!",
               account: "Income",
               amount: -20.00,
               balance: -20.00
             }
    end

    test "returns postings for Liabilities:Credit Card account with running balance", %{
      transactions: transactions
    } do
      result = LedgerParser.get_account_postings(transactions, "Liabilities:Credit Card")

      assert length(result) == 1

      assert Enum.at(result, 0) == %{
               date: ~D[2009-10-31],
               description: "Panera Bread",
               account: "Liabilities:Credit Card",
               amount: -4.50,
               balance: -4.50
             }
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
      assert Enum.at(result, 0).balance == 4.50
      assert Enum.at(result, 1).balance == 9.00
      assert Enum.at(result, 2).balance == 13.50

      # Verify each balance is cumulative
      Enum.reduce(result, 0.0, fn posting, acc ->
        expected_balance = acc + posting.amount
        assert_in_delta posting.balance, expected_balance, 0.01
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
end
