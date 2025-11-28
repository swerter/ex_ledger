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

      assert {:error, :invalid_account_declaration} = LedgerParser.parse_account_declaration(input)
    end

    test "returns error for missing type" do
      input = "account Assets:Checking"

      assert {:error, :invalid_account_declaration} = LedgerParser.parse_account_declaration(input)
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

      assert {:error, {:missing_payee, 5, nil}} = LedgerParser.parse_ledger(input)
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

  describe "parse_ledger/1 - include directive (no file resolution)" do
    test "parses transactions without include directives" do
      # parse_ledger/1 doesn't resolve includes, so include lines are ignored
      input = """
      2009/10/29 Panera Bread
          Expenses:Food               $4.50
          Assets:Checking
      """

      assert {:ok, transactions} = LedgerParser.parse_ledger(input)
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
      # Create a temporary directory for test files
      test_dir = System.tmp_dir!() |> Path.join("ex_ledger_test_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(test_dir)

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, test_dir: test_dir}
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
      assert {:ok, transactions, accounts} = LedgerParser.parse_ledger_with_includes(content, test_dir)

      # Should have both transactions
      assert length(transactions) == 2
      assert Enum.at(transactions, 0).payee == "Opening Balance"
      assert Enum.at(transactions, 1).payee == "Panera Bread"
      # No account declarations in this test
      assert accounts == %{}
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
      assert {:ok, transactions, _accounts} = LedgerParser.parse_ledger_with_includes(content, test_dir)

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
               LedgerParser.parse_ledger_with_includes(content, test_dir)
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
      assert {:ok, transactions, _accounts} = LedgerParser.parse_ledger_with_includes(content, test_dir)

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
               LedgerParser.parse_ledger_with_includes(content, test_dir)
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
      assert {:ok, transactions, _accounts} = LedgerParser.parse_ledger_with_includes(content, test_dir)

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
      assert {:ok, transactions, accounts} = LedgerParser.parse_ledger_with_includes(content, test_dir)

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
      assert {:ok, transactions, accounts} = LedgerParser.parse_ledger_with_includes(content, test_dir)

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
      assert {:error, _} = LedgerParser.parse_ledger_with_includes(content, test_dir)
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
            %{account: "checking", amount: %{value: -10.0, currency: "$"}, metadata: %{}, tags: [], comments: []},
            %{account: "food", amount: %{value: 10.0, currency: "$"}, metadata: %{}, tags: [], comments: []}
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
  end
end
