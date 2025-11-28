defmodule ExLedger.LineNumberTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser

  describe "parse_ledger/2 - line number tracking with account declarations" do
    test "reports correct line number when error occurs after account declarations" do
      input = """
      account Expenses:Groceries
          assert commodity == "CHF"
          alias postkonto




      account 1 Assets:Checking


      sdf
      """

      # Line 11 has "sdf" which should cause a missing_date error
      assert {:error, {reason, line, _source_file}} = LedgerParser.parse_ledger(input, "test.ledger")
      assert reason == :missing_date
      assert line == 11
    end

    test "reports correct line number with simple account declaration" do
      input = """
      account Assets:Checking

      invalid line here
      """

      # Line 3 has "invalid line here" which should cause a missing_date error
      assert {:error, {reason, line, _source_file}} = LedgerParser.parse_ledger(input, "test.ledger")
      assert reason == :missing_date
      assert line == 3
    end

    test "reports correct line number with multiple account declarations" do
      input = """
      account Assets:Checking

      account Expenses:Food

      account Income:Salary

      bad data
      """

      # Line 7 has "bad data"
      assert {:error, {reason, line, _source_file}} = LedgerParser.parse_ledger(input, "test.ledger")
      assert reason == :missing_date
      assert line == 7
    end

    test "reports correct line number with account declaration and valid transaction before error" do
      input = """
      account Assets:Checking

      2024/01/15 Grocery Store
          Expenses:Groceries          $50.00
          Assets:Checking

      error line
      """

      # Line 7 has "error line"
      assert {:error, {reason, line, _source_file}} = LedgerParser.parse_ledger(input, "test.ledger")
      assert reason == :missing_date
      assert line == 7
    end

    test "successfully parses when no errors present" do
      input = """
      account Assets:Checking

      2024/01/15 Grocery Store
          Expenses:Groceries          $50.00
          Assets:Checking
      """

      assert {:ok, transactions} = LedgerParser.parse_ledger(input, "test.ledger")
      assert length(transactions) == 1
    end
  end

  describe "parse_ledger_with_includes/4 - line number tracking in imported files" do
    setup do
      # Create temporary test files
      test_dir = System.tmp_dir!()

      accounts_file = Path.join(test_dir, "test_accounts.ledger")
      File.write!(accounts_file, """
      account Expenses:Groceries
          assert commodity == "CHF"
          alias postkonto




      account 1 Assets:Checking


      sdf
      """)

      main_file_content = """
      include test_accounts.ledger

      2024/01/15 Grocery Store
          Expenses:Groceries          $50.00
          Assets:Checking
      """

      %{test_dir: test_dir, accounts_file: accounts_file, main_file_content: main_file_content}
    end

    test "reports correct line number in imported file", %{test_dir: test_dir, main_file_content: main_file_content} do
      result = LedgerParser.parse_ledger_with_includes(main_file_content, test_dir, MapSet.new(), "main.ledger")

      assert {:error, {reason, line, source_file, import_chain}} = result
      assert reason == :missing_date
      assert line == 11  # Line 11 in test_accounts.ledger where "sdf" appears
      assert source_file == "test_accounts.ledger"
      assert import_chain == [{"main.ledger", 1}]  # Imported from line 1 of main.ledger
    end
  end
end
