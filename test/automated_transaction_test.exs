defmodule ExLedger.AutomatedTransactionTest do
  use ExUnit.Case, async: true

  alias ExLedger.LedgerParser

  # ============================================================================
  # PHASE 0: Tests for CURRENT parser behavior
  # These tests validate what the parser currently captures (predicate as string)
  # ============================================================================

  describe "current parser - basic automated transaction structure" do
    test "parses automated transaction with simple account regex" do
      input = """
      = /Expenses:Food/
          (Budget:Food)  $-50

      2024/01/15 Test
          Expenses:Food  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))

      assert auto != nil
      assert auto.predicate == "/Expenses:Food/"
      assert length(auto.postings) == 1
    end

    test "parses automated transaction with anchored regex" do
      input = """
      = /^Expenses:/
          (Budget:General)  $-50

      2024/01/15 Test
          Expenses:Food  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      assert auto.predicate == "/^Expenses:/"
    end

    test "parses payee match predicate" do
      input = """
      = payee =~ /Grocery/
          (Budget:Food)  $-25

      2024/01/15 Grocery Store
          Expenses:Food  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      assert auto.predicate == "payee =~ /Grocery/"
    end

    test "parses AND expression predicate" do
      input = """
      = /^Expenses:/ and payee =~ /Deductible/
          Liabilities:Tax  $10

      2024/01/15 Deductible Corp
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      assert auto.predicate == "/^Expenses:/ and payee =~ /Deductible/"
    end

    test "parses OR expression predicate" do
      input = """
      = payee =~ /Grocery/ or payee =~ /Restaurant/
          (Budget:Food)  $-25

      2024/01/15 Grocery Store
          Expenses:Food  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      assert auto.predicate == "payee =~ /Grocery/ or payee =~ /Restaurant/"
    end

    test "parses grouped expression with parentheses" do
      input = """
      = ( payee =~ /Office/ or payee =~ /Services/ ) and /^Expenses:/
          Liabilities:Tax  $10

      2024/01/15 Office Supplies
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      assert auto.predicate == "( payee =~ /Office/ or payee =~ /Services/ ) and /^Expenses:/"
    end

    test "parses complex nested predicate from user example" do
      input = """
      = ( payee =~ /Office Supplies Co/ or payee =~ /ProfessionalServices GmbH/ ) and /^Expenses:/
          Liabilities:Tax  $10
          Assets:Tax:Prepaid  $-10

      2024/01/15 Office Supplies Co
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))

      assert auto.predicate ==
               "( payee =~ /Office Supplies Co/ or payee =~ /ProfessionalServices GmbH/ ) and /^Expenses:/"
    end
  end

  describe "current parser - automated transaction postings" do
    test "parses virtual unbalanced posting" do
      input = """
      = /Expenses:Food/
          (Budget:Food)  $-50

      2024/01/15 Test
          Expenses:Food  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      posting = hd(auto.postings)

      assert posting.account == "Budget:Food"
      assert posting.virtual == true
      assert posting.must_balance == false
      assert posting.amount.value == Decimal.new("-50")
      assert posting.amount.currency == "$"
    end

    test "parses virtual balanced posting" do
      input = """
      = /Expenses:Food/
          [Tracking:Food]  $50

      2024/01/15 Test
          Expenses:Food  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      posting = hd(auto.postings)

      assert posting.account == "Tracking:Food"
      assert posting.virtual == true
      assert posting.must_balance == true
    end

    test "parses regular (non-virtual) posting" do
      input = """
      = /Expenses:/
          Liabilities:Tax  $10

      2024/01/15 Test
          Expenses:Food  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      posting = hd(auto.postings)

      assert posting.account == "Liabilities:Tax"
      assert posting.virtual == false
    end

    test "parses multiple postings" do
      input = """
      = /Expenses:/
          Liabilities:Tax  $10
          Assets:Tax:Prepaid  $-10

      2024/01/15 Test
          Expenses:Food  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))

      assert length(auto.postings) == 2
      accounts = Enum.map(auto.postings, & &1.account)
      assert "Liabilities:Tax" in accounts
      assert "Assets:Tax:Prepaid" in accounts
    end

    test "parses posting with bare multiplier (no currency)" do
      input = """
      = /Expenses:Food/
          (Budget:Food)  -1

      2024/01/15 Test
          Expenses:Food  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      posting = hd(auto.postings)

      # Bare number parsed as amount without currency
      assert posting.amount.value == Decimal.new("-1")
      assert posting.amount.currency == nil
    end

    test "parses fractional multiplier" do
      input = """
      = /Expenses:/
          Liabilities:Tax  0.077

      2024/01/15 Test
          Expenses:Food  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      posting = hd(auto.postings)

      assert posting.amount.value == Decimal.new("0.077")
      assert posting.amount.currency == nil
    end

    test "parses posting with metadata" do
      input = """
      = /Expenses:/
          ; Category: Auto-generated
          Liabilities:Tax  $10

      2024/01/15 Test
          Expenses:Food  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      posting = hd(auto.postings)

      assert posting.metadata["Category"] == "Auto-generated"
    end

    test "parses posting with tag" do
      input = """
      = /Expenses:/
          ; :auto-generated:
          Liabilities:Tax  $10

      2024/01/15 Test
          Expenses:Food  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      posting = hd(auto.postings)

      assert "auto-generated" in posting.tags
    end
  end

  describe "current parser - multiple automated transactions" do
    test "parses multiple automated transactions in file" do
      input = """
      = /Expenses:Food/
          (Budget:Food)  -1

      = /Expenses:Transport/
          (Budget:Transport)  -1

      2024/01/15 Grocery
          Expenses:Food  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      automated = Enum.filter(result.transactions, &(&1.kind == :automated))

      assert length(automated) == 2
      predicates = Enum.map(automated, & &1.predicate)
      assert "/Expenses:Food/" in predicates
      assert "/Expenses:Transport/" in predicates
    end

    test "automated transaction at end of file" do
      input = """
      2024/01/15 Grocery
          Expenses:Food  $50
          Assets:Cash

      = /Expenses:Food/
          (Budget:Food)  -1
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      assert auto != nil
      assert auto.predicate == "/Expenses:Food/"
    end
  end

  describe "current parser - edge cases" do
    test "handles whitespace before predicate" do
      input = """
      =   /Expenses:Food/
          (Budget:Food)  -1

      2024/01/15 Test
          Expenses:Food  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      assert auto.predicate == "/Expenses:Food/"
    end

    test "handles special characters in regex" do
      input = """
      = /Expenses:Food & Dining/
          (Budget:Food)  -1

      2024/01/15 Test
          Expenses:Food  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))
      assert auto.predicate == "/Expenses:Food & Dining/"
    end
  end

  # ============================================================================
  # PHASE 1: Predicate Parser Tests
  # These require implementing ExLedger.Predicate.Parser
  # ============================================================================

  alias ExLedger.Predicate.Parser

  describe "predicate parser - simple patterns" do
    test "parses account regex to AST" do
      assert {:ok, {:account_regex, regex}} = Parser.parse("/Expenses:Food/")
      assert Regex.match?(regex, "Expenses:Food")
      refute Regex.match?(regex, "Assets:Cash")
    end

    test "parses anchored account regex" do
      assert {:ok, {:account_regex, regex}} = Parser.parse("/^Expenses:/")
      assert Regex.match?(regex, "Expenses:Food")
      refute Regex.match?(regex, "Budget:Expenses:Food")
    end

    test "parses payee match" do
      assert {:ok, {:payee_regex, regex}} = Parser.parse("payee =~ /Grocery/")
      assert Regex.match?(regex, "Grocery Store")
      refute Regex.match?(regex, "Gas Station")
    end

    test "parses note match" do
      assert {:ok, {:note_regex, regex}} = Parser.parse("note =~ /reimbursable/")
      assert Regex.match?(regex, "reimbursable by client")
    end

    test "parses has_tag" do
      assert {:ok, {:has_tag, regex}} = Parser.parse("has_tag(/business/)")
      assert Regex.match?(regex, "business")
    end

    test "parses tag value match" do
      assert {:ok, {:tag_value, "Project", regex}} = Parser.parse(~s[tag("Project") =~ /Alpha/])
      assert Regex.match?(regex, "Alpha-123")
    end

    test "parses amount greater than with dollar" do
      assert {:ok, {:amount_gt, value, "$"}} = Parser.parse("amount > $100")
      assert Decimal.eq?(value, Decimal.new("100"))
    end

    test "parses amount less than with dollar" do
      assert {:ok, {:amount_lt, value, "$"}} = Parser.parse("amount < $10")
      assert Decimal.eq?(value, Decimal.new("10"))
    end

    test "parses amount equal" do
      assert {:ok, {:amount_eq, value, "$"}} = Parser.parse("amount == $50")
      assert Decimal.eq?(value, Decimal.new("50"))
    end

    test "parses amount with trailing currency code" do
      assert {:ok, {:amount_gt, value, "EUR"}} = Parser.parse("amount > 100 EUR")
      assert Decimal.eq?(value, Decimal.new("100"))
    end

    test "parses amount with decimal" do
      assert {:ok, {:amount_gt, value, "$"}} = Parser.parse("amount > $99.99")
      assert Decimal.eq?(value, Decimal.new("99.99"))
    end
  end

  describe "predicate parser - compound expressions" do
    test "parses AND expression" do
      assert {:ok, {:and, {:account_regex, _}, {:payee_regex, _}}} =
               Parser.parse("/Expenses:/ and payee =~ /Grocery/")
    end

    test "parses OR expression" do
      assert {:ok, {:or, {:payee_regex, _}, {:payee_regex, _}}} =
               Parser.parse("payee =~ /Grocery/ or payee =~ /Restaurant/")
    end

    test "parses nested AND/OR with grouping" do
      assert {:ok, {:and, {:or, _, _}, {:account_regex, _}}} =
               Parser.parse("( payee =~ /Office/ or payee =~ /Services/ ) and /^Expenses:/")
    end

    test "parses complex user example predicate" do
      predicate =
        "( payee =~ /Office Supplies Co/ or payee =~ /ProfessionalServices GmbH/ ) and /^Expenses:/"

      assert {:ok, ast} = Parser.parse(predicate)
      assert match?({:and, {:or, _, _}, {:account_regex, _}}, ast)
    end

    test "parses multiple AND conditions" do
      assert {:ok, ast} = Parser.parse("/Expenses:/ and payee =~ /Grocery/ and amount > $50")

      # Should be left-associative: ((Expenses and Grocery) and amount)
      assert match?({:and, {:and, _, _}, _}, ast)
    end

    test "parses multiple OR conditions" do
      assert {:ok, ast} =
               Parser.parse("payee =~ /Grocery/ or payee =~ /Market/ or payee =~ /Store/")

      assert match?({:or, {:or, _, _}, _}, ast)
    end

    test "AND has higher precedence than OR" do
      # "a or b and c" should parse as "a or (b and c)"
      assert {:ok, ast} =
               Parser.parse("/Assets:/ or /Expenses:/ and payee =~ /Grocery/")

      assert match?({:or, {:account_regex, _}, {:and, _, _}}, ast)
    end

    test "parses NOT expression" do
      assert {:ok, {:not, {:account_regex, _}}} = Parser.parse("not /Expenses:/")
    end

    test "parses NOT with AND" do
      assert {:ok, {:and, {:not, _}, _}} =
               Parser.parse("not /Assets:/ and /Expenses:/")
    end
  end

  describe "predicate parser - edge cases" do
    test "handles whitespace variations" do
      assert {:ok, _} = Parser.parse("  /Expenses:/  ")
      assert {:ok, _} = Parser.parse("payee=~/Grocery/")
      assert {:ok, _} = Parser.parse("payee  =~  /Grocery/")
    end

    test "handles regex with special characters" do
      assert {:ok, {:account_regex, regex}} = Parser.parse("/Expenses:Food & Dining/")
      assert Regex.match?(regex, "Expenses:Food & Dining")
    end

    test "handles escaped forward slash in regex" do
      assert {:ok, {:account_regex, regex}} = Parser.parse("/path\\/to\\/account/")
      assert Regex.match?(regex, "path/to/account")
    end

    test "returns error for invalid input" do
      assert {:error, _} = Parser.parse("invalid predicate")
      assert {:error, _} = Parser.parse("")
    end

    test "handles complex real-world predicate" do
      predicate = "( payee =~ /Office Supplies Co/ or payee =~ /ProfessionalServices GmbH/ ) and /^Expenses:/"

      {:ok, ast} = Parser.parse(predicate)

      # Verify structure
      {:and, or_clause, account_clause} = ast
      {:or, payee1, payee2} = or_clause

      assert match?({:payee_regex, _}, payee1)
      assert match?({:payee_regex, _}, payee2)
      assert match?({:account_regex, _}, account_clause)

      # Verify the regexes work
      {:payee_regex, regex1} = payee1
      {:payee_regex, regex2} = payee2
      {:account_regex, account_regex} = account_clause

      assert Regex.match?(regex1, "Office Supplies Co")
      assert Regex.match?(regex2, "ProfessionalServices GmbH")
      assert Regex.match?(account_regex, "Expenses:Office")
    end
  end

  # ============================================================================
  # PHASE 2: Predicate Evaluator Tests
  # These require implementing ExLedger.Predicate.Evaluator
  # ============================================================================

  alias ExLedger.Predicate.Evaluator

  describe "predicate evaluator - account matching" do
    test "matches account regex" do
      ast = {:account_regex, ~r/Expenses:Food/}
      ctx = Evaluator.context(%{}, %{account: "Expenses:Food"})
      assert Evaluator.matches?(ast, ctx)
    end

    test "does not match non-matching account" do
      ast = {:account_regex, ~r/Expenses:Food/}
      ctx = Evaluator.context(%{}, %{account: "Expenses:Transport"})
      refute Evaluator.matches?(ast, ctx)
    end

    test "anchored regex only matches at start" do
      ast = {:account_regex, ~r/^Expenses:/}
      ctx1 = Evaluator.context(%{}, %{account: "Expenses:Food"})
      ctx2 = Evaluator.context(%{}, %{account: "Budget:Expenses:Food"})
      assert Evaluator.matches?(ast, ctx1)
      refute Evaluator.matches?(ast, ctx2)
    end

    test "nil account does not crash" do
      ast = {:account_regex, ~r/Expenses:/}
      ctx = Evaluator.context(%{}, %{account: nil})
      refute Evaluator.matches?(ast, ctx)
    end
  end

  describe "predicate evaluator - payee matching" do
    test "matches payee regex" do
      ast = {:payee_regex, ~r/Grocery/}
      ctx = Evaluator.context(%{payee: "Grocery Store"}, %{account: "Expenses:Food"})
      assert Evaluator.matches?(ast, ctx)
    end

    test "nil payee does not crash" do
      ast = {:payee_regex, ~r/Grocery/}
      ctx = Evaluator.context(%{payee: nil}, %{account: "Expenses:Food"})
      refute Evaluator.matches?(ast, ctx)
    end

    test "payee regex is case sensitive" do
      ast = {:payee_regex, ~r/GROCERY/}
      ctx = Evaluator.context(%{payee: "Grocery Store"}, %{})
      refute Evaluator.matches?(ast, ctx)
    end

    test "payee regex case insensitive with flag" do
      ast = {:payee_regex, ~r/grocery/i}
      ctx = Evaluator.context(%{payee: "Grocery Store"}, %{})
      assert Evaluator.matches?(ast, ctx)
    end
  end

  describe "predicate evaluator - note matching" do
    test "matches transaction comment" do
      ast = {:note_regex, ~r/reimbursable/}
      ctx = Evaluator.context(%{comment: "reimbursable by client"}, %{comments: []})
      assert Evaluator.matches?(ast, ctx)
    end

    test "matches posting comment" do
      ast = {:note_regex, ~r/reimbursable/}
      ctx = Evaluator.context(%{}, %{comments: ["reimbursable expense"]})
      assert Evaluator.matches?(ast, ctx)
    end

    test "matches either transaction or posting comment" do
      ast = {:note_regex, ~r/important/}
      ctx1 = Evaluator.context(%{comment: "important transaction"}, %{comments: []})
      ctx2 = Evaluator.context(%{}, %{comments: ["important posting"]})
      assert Evaluator.matches?(ast, ctx1)
      assert Evaluator.matches?(ast, ctx2)
    end
  end

  describe "predicate evaluator - tag matching" do
    test "has_tag matches existing tag" do
      ast = {:has_tag, ~r/business/}
      ctx = Evaluator.context(%{}, %{tags: ["business", "deductible"]})
      assert Evaluator.matches?(ast, ctx)
    end

    test "has_tag does not match missing tag" do
      ast = {:has_tag, ~r/personal/}
      ctx = Evaluator.context(%{}, %{tags: ["business"]})
      refute Evaluator.matches?(ast, ctx)
    end

    test "has_tag with empty tags list" do
      ast = {:has_tag, ~r/any/}
      ctx = Evaluator.context(%{}, %{tags: []})
      refute Evaluator.matches?(ast, ctx)
    end

    test "tag_value matches metadata" do
      ast = {:tag_value, "Project", ~r/Alpha/}
      ctx = Evaluator.context(%{}, %{metadata: %{"Project" => "Alpha-123"}})
      assert Evaluator.matches?(ast, ctx)
    end

    test "tag_value does not match wrong value" do
      ast = {:tag_value, "Project", ~r/Alpha/}
      ctx = Evaluator.context(%{}, %{metadata: %{"Project" => "Beta"}})
      refute Evaluator.matches?(ast, ctx)
    end

    test "tag_value with missing key" do
      ast = {:tag_value, "Project", ~r/Alpha/}
      ctx = Evaluator.context(%{}, %{metadata: %{}})
      refute Evaluator.matches?(ast, ctx)
    end
  end

  describe "predicate evaluator - amount comparisons" do
    test "amount > threshold matches" do
      ast = {:amount_gt, Decimal.new("100"), "$"}
      ctx = Evaluator.context(%{}, %{amount: %{value: Decimal.new("150"), currency: "$"}})
      assert Evaluator.matches?(ast, ctx)
    end

    test "amount > threshold does not match equal" do
      ast = {:amount_gt, Decimal.new("100"), "$"}
      ctx = Evaluator.context(%{}, %{amount: %{value: Decimal.new("100"), currency: "$"}})
      refute Evaluator.matches?(ast, ctx)
    end

    test "amount > threshold does not match less" do
      ast = {:amount_gt, Decimal.new("100"), "$"}
      ctx = Evaluator.context(%{}, %{amount: %{value: Decimal.new("50"), currency: "$"}})
      refute Evaluator.matches?(ast, ctx)
    end

    test "amount > threshold respects currency" do
      ast = {:amount_gt, Decimal.new("100"), "$"}
      ctx = Evaluator.context(%{}, %{amount: %{value: Decimal.new("150"), currency: "EUR"}})
      refute Evaluator.matches?(ast, ctx)
    end

    test "amount < threshold matches" do
      ast = {:amount_lt, Decimal.new("100"), "$"}
      ctx = Evaluator.context(%{}, %{amount: %{value: Decimal.new("50"), currency: "$"}})
      assert Evaluator.matches?(ast, ctx)
    end

    test "amount == threshold matches" do
      ast = {:amount_eq, Decimal.new("100"), "$"}
      ctx = Evaluator.context(%{}, %{amount: %{value: Decimal.new("100"), currency: "$"}})
      assert Evaluator.matches?(ast, ctx)
    end

    test "amount comparison with nil currency matches any" do
      ast = {:amount_gt, Decimal.new("100"), nil}
      ctx = Evaluator.context(%{}, %{amount: %{value: Decimal.new("150"), currency: "EUR"}})
      assert Evaluator.matches?(ast, ctx)
    end

    test "amount comparison with nil amount" do
      ast = {:amount_gt, Decimal.new("100"), "$"}
      ctx = Evaluator.context(%{}, %{amount: nil})
      refute Evaluator.matches?(ast, ctx)
    end
  end

  describe "predicate evaluator - compound expressions" do
    test "AND requires both conditions" do
      ast = {:and, {:account_regex, ~r/^Expenses:/}, {:payee_regex, ~r/Grocery/}}
      ctx1 = Evaluator.context(%{payee: "Grocery Store"}, %{account: "Expenses:Food"})
      ctx2 = Evaluator.context(%{payee: "Gas Station"}, %{account: "Expenses:Food"})
      ctx3 = Evaluator.context(%{payee: "Grocery Store"}, %{account: "Assets:Cash"})
      assert Evaluator.matches?(ast, ctx1)
      refute Evaluator.matches?(ast, ctx2)
      refute Evaluator.matches?(ast, ctx3)
    end

    test "OR matches either condition" do
      ast = {:or, {:payee_regex, ~r/Grocery/}, {:payee_regex, ~r/Market/}}
      ctx1 = Evaluator.context(%{payee: "Grocery Store"}, %{})
      ctx2 = Evaluator.context(%{payee: "Farmers Market"}, %{})
      ctx3 = Evaluator.context(%{payee: "Gas Station"}, %{})
      assert Evaluator.matches?(ast, ctx1)
      assert Evaluator.matches?(ast, ctx2)
      refute Evaluator.matches?(ast, ctx3)
    end

    test "NOT inverts result" do
      ast = {:not, {:account_regex, ~r/^Expenses:/}}
      ctx1 = Evaluator.context(%{}, %{account: "Expenses:Food"})
      ctx2 = Evaluator.context(%{}, %{account: "Assets:Cash"})
      refute Evaluator.matches?(ast, ctx1)
      assert Evaluator.matches?(ast, ctx2)
    end

    test "complex nested expression" do
      # ( payee =~ /Office/ or payee =~ /Services/ ) and /^Expenses:/
      ast =
        {:and,
         {:or, {:payee_regex, ~r/Office/}, {:payee_regex, ~r/Services/}},
         {:account_regex, ~r/^Expenses:/}}

      ctx1 = Evaluator.context(%{payee: "Office Supplies Co"}, %{account: "Expenses:Office"})
      ctx2 = Evaluator.context(%{payee: "Professional Services"}, %{account: "Expenses:Consulting"})
      ctx3 = Evaluator.context(%{payee: "Office Supplies Co"}, %{account: "Assets:Equipment"})
      ctx4 = Evaluator.context(%{payee: "Random Store"}, %{account: "Expenses:Food"})

      assert Evaluator.matches?(ast, ctx1)
      assert Evaluator.matches?(ast, ctx2)
      refute Evaluator.matches?(ast, ctx3)
      refute Evaluator.matches?(ast, ctx4)
    end
  end

  describe "predicate evaluator - convenience functions" do
    test "evaluate parses and matches in one call" do
      ctx = Evaluator.context(%{payee: "Grocery Store"}, %{account: "Expenses:Food"})
      assert {:ok, true} = Evaluator.evaluate("/Expenses:/ and payee =~ /Grocery/", ctx)
      assert {:ok, false} = Evaluator.evaluate("/Assets:/", ctx)
    end

    test "evaluate returns error for invalid predicate" do
      ctx = Evaluator.context(%{}, %{})
      assert {:error, _} = Evaluator.evaluate("invalid", ctx)
    end

    test "find_matching_postings finds all matching postings" do
      transaction = %{
        payee: "Office Supplies Co",
        postings: [
          %{account: "Expenses:Office", amount: %{value: Decimal.new("100"), currency: "$"}},
          %{account: "Assets:Cash", amount: %{value: Decimal.new("-100"), currency: "$"}}
        ]
      }

      {:ok, matches} = Evaluator.find_matching_postings("/^Expenses:/", transaction)
      assert length(matches) == 1
      {posting, index} = hd(matches)
      assert posting.account == "Expenses:Office"
      assert index == 0
    end

    test "find_matching_postings with complex predicate" do
      transaction = %{
        payee: "Office Supplies Co",
        postings: [
          %{account: "Expenses:Office", amount: %{value: Decimal.new("100"), currency: "$"}},
          %{account: "Expenses:Supplies", amount: %{value: Decimal.new("50"), currency: "$"}},
          %{account: "Assets:Cash", amount: %{value: Decimal.new("-150"), currency: "$"}}
        ]
      }

      predicate = "/^Expenses:/ and amount > $75"
      {:ok, matches} = Evaluator.find_matching_postings(predicate, transaction)
      assert length(matches) == 1
      {posting, _} = hd(matches)
      assert posting.account == "Expenses:Office"
    end
  end

  # ============================================================================
  # PHASE 3: Amount Expression Tests
  # These require implementing ExLedger.Predicate.AmountExpr
  # ============================================================================

  alias ExLedger.Predicate.AmountExpr

  describe "amount expression evaluation - multipliers" do
    test "multiplier 1 copies amount" do
      expr = %{value: Decimal.new("1"), currency: nil}
      matched = %{value: Decimal.new("50"), currency: "$", currency_position: :leading}
      result = AmountExpr.evaluate(expr, matched)

      assert Decimal.eq?(result.value, Decimal.new("50"))
      assert result.currency == "$"
      assert result.currency_position == :leading
    end

    test "multiplier -1 negates amount" do
      expr = %{value: Decimal.new("-1"), currency: nil}
      matched = %{value: Decimal.new("50"), currency: "$"}
      result = AmountExpr.evaluate(expr, matched)

      assert Decimal.eq?(result.value, Decimal.new("-50"))
      assert result.currency == "$"
    end

    test "fractional multiplier 0.10 calculates 10%" do
      expr = %{value: Decimal.new("0.10"), currency: nil}
      matched = %{value: Decimal.new("100"), currency: "$"}
      result = AmountExpr.evaluate(expr, matched)

      assert Decimal.eq?(result.value, Decimal.new("10.00"))
      assert result.currency == "$"
    end

    test "fractional multiplier 0.077 calculates 7.7%" do
      expr = %{value: Decimal.new("0.077"), currency: nil}
      matched = %{value: Decimal.new("100"), currency: "$"}
      result = AmountExpr.evaluate(expr, matched)

      assert Decimal.eq?(result.value, Decimal.new("7.700"))
    end

    test "negative fractional multiplier" do
      expr = %{value: Decimal.new("-0.10"), currency: nil}
      matched = %{value: Decimal.new("100"), currency: "$"}
      result = AmountExpr.evaluate(expr, matched)

      assert Decimal.eq?(result.value, Decimal.new("-10.00"))
    end

    test "multiplier preserves currency from matched amount" do
      expr = %{value: Decimal.new("-1"), currency: nil}
      matched = %{value: Decimal.new("50"), currency: "EUR", currency_position: :trailing}
      result = AmountExpr.evaluate(expr, matched)

      assert result.currency == "EUR"
      assert result.currency_position == :trailing
    end
  end

  describe "amount expression evaluation - fixed amounts" do
    test "fixed amount ignores matched amount" do
      expr = %{value: Decimal.new("-25"), currency: "$", currency_position: :leading}
      matched = %{value: Decimal.new("100"), currency: "$"}
      result = AmountExpr.evaluate(expr, matched)

      assert Decimal.eq?(result.value, Decimal.new("-25"))
      assert result.currency == "$"
    end

    test "fixed amount uses its own currency" do
      expr = %{value: Decimal.new("50"), currency: "EUR", currency_position: :trailing}
      matched = %{value: Decimal.new("100"), currency: "$"}
      result = AmountExpr.evaluate(expr, matched)

      assert Decimal.eq?(result.value, Decimal.new("50"))
      assert result.currency == "EUR"
    end

    test "fixed amount with different currency than matched" do
      expr = %{value: Decimal.new("10"), currency: "CHF"}
      matched = %{value: Decimal.new("100"), currency: "EUR"}
      result = AmountExpr.evaluate(expr, matched)

      assert result.currency == "CHF"
      assert Decimal.eq?(result.value, Decimal.new("10"))
    end
  end

  describe "amount expression evaluation - edge cases" do
    test "nil expression returns nil" do
      matched = %{value: Decimal.new("100"), currency: "$"}
      assert AmountExpr.evaluate(nil, matched) == nil
    end

    test "nil matched amount returns nil" do
      expr = %{value: Decimal.new("-1"), currency: nil}
      assert AmountExpr.evaluate(expr, nil) == nil
    end

    test "is_multiplier? detects multipliers" do
      assert AmountExpr.is_multiplier?(%{value: Decimal.new("1"), currency: nil})
      assert AmountExpr.is_multiplier?(%{value: Decimal.new("-1"), currency: nil})
      assert AmountExpr.is_multiplier?(%{value: Decimal.new("0.10"), currency: nil})
      refute AmountExpr.is_multiplier?(%{value: Decimal.new("50"), currency: "$"})
      refute AmountExpr.is_multiplier?(%{value: Decimal.new("100"), currency: "EUR"})
    end

    test "is_fixed_amount? detects fixed amounts" do
      assert AmountExpr.is_fixed_amount?("$")
      assert AmountExpr.is_fixed_amount?("EUR")
      refute AmountExpr.is_fixed_amount?(nil)
    end
  end

  # ============================================================================
  # PHASE 4: Full Automated Transaction Application Tests
  # These require implementing ExLedger.Automated
  # ============================================================================

  alias ExLedger.Automated

  describe "automated transaction application - posting generation" do
    test "generates posting for matching transaction" do
      input = """
      = /Expenses:Food/
          (Budget:Food)  -1

      2024/01/15 Grocery Store
          Expenses:Food  $50.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      assert length(txn.postings) == 3
      budget = Enum.find(txn.postings, &(&1.account == "Budget:Food"))
      assert budget != nil
      assert budget.virtual == true
      assert Decimal.eq?(budget.amount.value, Decimal.new("-50.00"))
    end

    test "does not generate posting for non-matching transaction" do
      input = """
      = /Expenses:Food/
          (Budget:Food)  -1

      2024/01/15 Gas Station
          Expenses:Transport  $50.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      assert length(txn.postings) == 2
      refute Enum.any?(txn.postings, &(&1.account == "Budget:Food"))
    end

    test "applies to each matching posting separately" do
      input = """
      = /Expenses:/
          (Budget:All)  -1

      2024/01/15 Multiple Items
          Expenses:Food  $30.00
          Expenses:Supplies  $20.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      budget_postings = Enum.filter(txn.postings, &(&1.account == "Budget:All"))
      assert length(budget_postings) == 2

      # Verify both amounts are present (negated from original)
      amounts = Enum.map(budget_postings, & &1.amount.value)
      assert Enum.any?(amounts, &Decimal.eq?(&1, Decimal.new("-30.00")))
      assert Enum.any?(amounts, &Decimal.eq?(&1, Decimal.new("-20.00")))
    end

    test "preserves currency from matched posting" do
      input = """
      = /Expenses:/
          (Budget:All)  -1

      2024/01/15 Purchase
          Expenses:Food  50 EUR
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      budget = Enum.find(txn.postings, &(&1.account == "Budget:All"))
      assert budget.amount.currency == "EUR"
      assert Decimal.eq?(budget.amount.value, Decimal.new("-50"))
    end

    test "adds provenance metadata to generated postings" do
      input = """
      = /Expenses:Food/
          (Budget:Food)  -1

      2024/01/15 Grocery
          Expenses:Food  $50.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      budget = Enum.find(txn.postings, &(&1.account == "Budget:Food"))
      assert budget.metadata["Generated_by"] == "/Expenses:Food/"
      assert budget.generated == true
    end

    test "uses fixed amount instead of multiplier" do
      input = """
      = /Expenses:Food/
          (Budget:Food)  $-25.00

      2024/01/15 Grocery
          Expenses:Food  $50.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      budget = Enum.find(txn.postings, &(&1.account == "Budget:Food"))
      # Fixed $-25.00, not based on matched $50.00
      assert Decimal.eq?(budget.amount.value, Decimal.new("-25.00"))
    end

    test "calculates percentage with fractional multiplier" do
      input = """
      = /Expenses:/
          Liabilities:Tax  0.077

      2024/01/15 Purchase
          Expenses:Equipment  $100.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      tax = Enum.find(txn.postings, &(&1.account == "Liabilities:Tax"))
      assert Decimal.eq?(tax.amount.value, Decimal.new("7.700"))
    end
  end

  describe "automated transaction application - complex predicates" do
    test "AND predicate requires both conditions" do
      input = """
      = /^Expenses:/ and payee =~ /Organic/
          (Budget:Organic)  -1

      2024/01/15 Organic Market
          Expenses:Food  $50.00
          Assets:Cash

      2024/01/16 Regular Store
          Expenses:Food  $30.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)

      organic_txn = Enum.find(transactions, &(&1.payee == "Organic Market"))
      regular_txn = Enum.find(transactions, &(&1.payee == "Regular Store"))

      assert Enum.any?(organic_txn.postings, &(&1.account == "Budget:Organic"))
      refute Enum.any?(regular_txn.postings, &(&1.account == "Budget:Organic"))
    end

    test "OR predicate matches either condition" do
      input = """
      = payee =~ /Grocery/ or payee =~ /Market/
          (Budget:Food)  -1

      2024/01/15 Grocery Store
          Expenses:Food  $50.00
          Assets:Cash

      2024/01/16 Farmers Market
          Expenses:Food  $30.00
          Assets:Cash

      2024/01/17 Gas Station
          Expenses:Transport  $40.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)

      grocery = Enum.find(transactions, &(&1.payee == "Grocery Store"))
      market = Enum.find(transactions, &(&1.payee == "Farmers Market"))
      gas = Enum.find(transactions, &(&1.payee == "Gas Station"))

      assert Enum.any?(grocery.postings, &(&1.account == "Budget:Food"))
      assert Enum.any?(market.postings, &(&1.account == "Budget:Food"))
      refute Enum.any?(gas.postings, &(&1.account == "Budget:Food"))
    end

    test "complex grouped predicate from user example" do
      input = """
      = ( payee =~ /Office Supplies Co/ or payee =~ /ProfessionalServices GmbH/ ) and /^Expenses:/
          Liabilities:Tax  0.10
          Assets:Tax:Prepaid  -0.10

      2024/01/15 Office Supplies Co
          Expenses:Office  $100
          Assets:Cash

      2024/01/16 Random Store
          Expenses:Office  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)

      office_txn = Enum.find(transactions, &(&1.payee == "Office Supplies Co"))
      random_txn = Enum.find(transactions, &(&1.payee == "Random Store"))

      # Office Supplies Co should have tax postings
      assert Enum.any?(office_txn.postings, &(&1.account == "Liabilities:Tax"))
      assert Enum.any?(office_txn.postings, &(&1.account == "Assets:Tax:Prepaid"))

      # Random Store should NOT have tax postings (wrong payee)
      refute Enum.any?(random_txn.postings, &(&1.account == "Liabilities:Tax"))
    end
  end

  describe "automated transaction application - ordering and chaining" do
    test "multiple automated transactions apply in order" do
      input = """
      = /Expenses:Food/
          (Budget:Food)  -1

      = /Expenses:/
          (Budget:All)  -1

      2024/01/15 Grocery
          Expenses:Food  $50.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      # Both rules should match Expenses:Food
      assert Enum.any?(txn.postings, &(&1.account == "Budget:Food"))
      assert Enum.any?(txn.postings, &(&1.account == "Budget:All"))
    end

    test "automated transactions do not chain (no recursion)" do
      input = """
      = /Expenses:Food/
          Expenses:Tax  0.10

      = /Expenses:Tax/
          (Budget:Tax)  -1

      2024/01/15 Grocery
          Expenses:Food  $100.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      # Should have Expenses:Tax (generated from first rule)
      assert Enum.any?(txn.postings, &(&1.account == "Expenses:Tax"))

      # Should NOT have Budget:Tax (second rule doesn't apply to generated postings)
      refute Enum.any?(txn.postings, &(&1.account == "Budget:Tax"))
    end

    test "filters out automated transactions from result" do
      input = """
      = /Expenses:Food/
          (Budget:Food)  -1

      2024/01/15 Grocery
          Expenses:Food  $50.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)

      # Only regular transactions in output
      assert length(transactions) == 1
      assert hd(transactions).kind == :regular
    end
  end

  describe "automated transaction application - derived postings tracking" do
    test "tracks derived postings separately" do
      input = """
      = /Expenses:Food/
          (Budget:Food)  -1

      2024/01/15 Grocery
          Expenses:Food  $50.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      assert length(txn.derived_postings) == 1
      assert hd(txn.derived_postings).account == "Budget:Food"
    end
  end

  # ============================================================================
  # PHASE 5: Metadata-Only Automated Transactions
  # Automated transactions that only add tags/metadata to matched postings
  # ============================================================================

  describe "metadata-only automated transactions - parsing" do
    test "parses automated transaction with only tags" do
      input = """
      = /^Expenses:/
          ; tax:

      2024/01/15 Office
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))

      assert auto != nil
      assert auto.predicate == "/^Expenses:/"
      assert length(auto.postings) == 1

      posting = hd(auto.postings)
      assert posting.enrichment_only == true
      assert "tax" in posting.tags
    end

    test "parses automated transaction with only metadata" do
      input = """
      = /^Expenses:/
          ; Category: Business
          ; TaxYear: 2024

      2024/01/15 Office
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))

      posting = hd(auto.postings)
      assert posting.metadata["Category"] == "Business"
      assert posting.metadata["TaxYear"] == "2024"
    end

    test "parses automated transaction with mixed tags and metadata" do
      input = """
      = /^Expenses:/
          ; tax:
          ; Category: Business

      2024/01/15 Office
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))

      posting = hd(auto.postings)
      assert "tax" in posting.tags
      assert posting.metadata["Category"] == "Business"
    end

    test "parses colon-style tag format" do
      input = """
      = /^Expenses:/
          ; :deductible:

      2024/01/15 Office
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      auto = Enum.find(result.transactions, &(&1.kind == :automated))

      posting = hd(auto.postings)
      assert "deductible" in posting.tags
    end
  end

  describe "metadata-only automated transactions - application" do
    test "applies tags to matched postings" do
      input = """
      = /^Expenses:/
          ; business:

      2024/01/15 Office
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      expense = Enum.find(txn.postings, &(&1.account == "Expenses:Office"))
      assert "business" in expense.tags
    end

    test "applies metadata to matched postings" do
      input = """
      = /^Expenses:/
          ; Category: Business

      2024/01/15 Office
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      expense = Enum.find(txn.postings, &(&1.account == "Expenses:Office"))
      assert expense.metadata["Category"] == "Business"
    end

    test "does not apply to non-matching postings" do
      input = """
      = /^Expenses:/
          ; business:

      2024/01/15 Office
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      # Assets:Cash should NOT have the tag
      cash = Enum.find(txn.postings, &(&1.account == "Assets:Cash"))
      refute "business" in (cash.tags || [])
    end

    test "applies to multiple matching postings" do
      input = """
      = /^Expenses:/
          ; deductible:

      2024/01/15 Multiple
          Expenses:Office  $100
          Expenses:Supplies  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      office = Enum.find(txn.postings, &(&1.account == "Expenses:Office"))
      supplies = Enum.find(txn.postings, &(&1.account == "Expenses:Supplies"))

      assert "deductible" in office.tags
      assert "deductible" in supplies.tags
    end

    test "complex predicate with payee match" do
      input = """
      = ( payee =~ /Office Supplies Co/ or payee =~ /ProfessionalServices GmbH/ ) and /^Expenses:/
          ; tax:
          ; rule_id: tax-deductible-providers

      2024/01/15 Office Supplies Co
          Expenses:Office  $100
          Assets:Cash

      2024/01/16 Random Store
          Expenses:Office  $50
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)

      office_txn = Enum.find(transactions, &(&1.payee == "Office Supplies Co"))
      random_txn = Enum.find(transactions, &(&1.payee == "Random Store"))

      office_expense = Enum.find(office_txn.postings, &(&1.account == "Expenses:Office"))
      random_expense = Enum.find(random_txn.postings, &(&1.account == "Expenses:Office"))

      # Office Supplies Co should have tax tag and metadata
      assert "tax" in office_expense.tags
      assert office_expense.metadata["rule_id"] == "tax-deductible-providers"

      # Random Store should NOT have tax tag
      refute "tax" in (random_expense.tags || [])
    end

    test "does not duplicate existing tags" do
      input = """
      = /^Expenses:/
          ; business:

      2024/01/15 Office
          ; :business:
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      expense = Enum.find(txn.postings, &(&1.account == "Expenses:Office"))
      # Should only have one "business" tag
      assert Enum.count(expense.tags, &(&1 == "business")) == 1
    end

    test "enrichment rule does not create derived postings" do
      input = """
      = /^Expenses:/
          ; tax:

      2024/01/15 Office
          Expenses:Office  $100
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)
      transactions = Automated.apply_all(result.transactions)
      txn = hd(transactions)

      # Should still only have 2 postings (no generated postings)
      assert length(txn.postings) == 2
      assert txn.derived_postings == []
    end
  end
end
