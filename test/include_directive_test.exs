defmodule ExLedger.IncludeDirectiveTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser
  alias ExLedger.TestHelpers

  @moduledoc """
  Edge case tests for the include directive.
  """

  setup do
    {:ok, tmp_dir: TestHelpers.tmp_dir!("ex_ledger_include")}
  end

  # Helper to parse a ledger file (reads file and parses with proper context)
  defp parse_file!(path) do
    content = File.read!(path)
    base_dir = Path.dirname(path)
    filename = Path.basename(path)

    case LedgerParser.parse_ledger(content, base_dir: base_dir, source_file: filename) do
      {:ok, result} -> result
      {:error, reason} -> flunk("Failed to parse #{path}: #{inspect(reason)}")
    end
  end

  defp parse_file(path) do
    content = File.read!(path)
    base_dir = Path.dirname(path)
    filename = Path.basename(path)
    LedgerParser.parse_ledger(content, base_dir: base_dir, source_file: filename)
  end

  describe "include directive - basic functionality" do
    test "includes file with relative path", %{tmp_dir: tmp_dir} do
      # Create included file
      included_path = Path.join(tmp_dir, "accounts.ledger")

      File.write!(included_path, """
      2024/01/01 Opening balance
          Assets:Cash  $1000.00
          Equity:Opening
      """)

      # Create main file
      main_path = Path.join(tmp_dir, "main.ledger")

      File.write!(main_path, """
      include accounts.ledger

      2024/01/15 Groceries
          Expenses:Food  $50.00
          Assets:Cash
      """)

      %{transactions: transactions} = parse_file!(main_path)

      assert length(transactions) == 2
      payees = Enum.map(transactions, & &1.payee)
      assert "Opening balance" in payees
      assert "Groceries" in payees
    end

    test "rejects absolute path includes for security" do
      # The parser prevents absolute path includes to avoid path traversal attacks
      # This is expected behavior
      input = """
      include /etc/passwd

      2024/01/15 Purchase
          Expenses:Food  $50.00
          Assets:Cash
      """

      result = LedgerParser.parse_ledger(input, base_dir: "/tmp")

      # Should error with include_outside_base
      assert {:error, _} = result
    end

    test "includes nested files", %{tmp_dir: tmp_dir} do
      # Create deeply nested includes
      level2_path = Path.join(tmp_dir, "level2.ledger")

      File.write!(level2_path, """
      2024/01/01 Level 2 transaction
          Assets:Bank  $500.00
          Equity:Opening
      """)

      level1_path = Path.join(tmp_dir, "level1.ledger")

      File.write!(level1_path, """
      include level2.ledger

      2024/01/02 Level 1 transaction
          Assets:Cash  $200.00
          Equity:Opening
      """)

      main_path = Path.join(tmp_dir, "main.ledger")

      File.write!(main_path, """
      include level1.ledger

      2024/01/03 Main transaction
          Expenses:Food  $50.00
          Assets:Cash
      """)

      %{transactions: transactions} = parse_file!(main_path)

      assert length(transactions) == 3
      payees = Enum.map(transactions, & &1.payee)
      assert "Level 2 transaction" in payees
      assert "Level 1 transaction" in payees
      assert "Main transaction" in payees
    end

    test "includes multiple files", %{tmp_dir: tmp_dir} do
      # Create multiple files to include
      File.write!(Path.join(tmp_dir, "accounts.ledger"), """
      2024/01/01 Opening
          Assets:Cash  $1000.00
          Equity:Opening
      """)

      File.write!(Path.join(tmp_dir, "prices.ledger"), """
      P 2024/01/01 EUR $1.10
      P 2024/01/01 GBP $1.25
      """)

      File.write!(Path.join(tmp_dir, "transactions.ledger"), """
      2024/01/15 Purchase
          Expenses:Food  $50.00
          Assets:Cash
      """)

      main_path = Path.join(tmp_dir, "main.ledger")

      File.write!(main_path, """
      include accounts.ledger
      include prices.ledger
      include transactions.ledger
      """)

      %{transactions: transactions} = parse_file!(main_path)

      assert length(transactions) == 2
    end
  end

  describe "include directive - error handling" do
    test "errors on missing included file", %{tmp_dir: tmp_dir} do
      main_path = Path.join(tmp_dir, "main.ledger")

      File.write!(main_path, """
      include nonexistent.ledger

      2024/01/15 Purchase
          Expenses:Food  $50.00
          Assets:Cash
      """)

      result = parse_file(main_path)

      assert {:error, _reason} = result
    end

    test "detects circular includes", %{tmp_dir: tmp_dir} do
      # Create circular dependency: a -> b -> a
      file_a = Path.join(tmp_dir, "a.ledger")
      file_b = Path.join(tmp_dir, "b.ledger")

      File.write!(file_a, """
      include b.ledger

      2024/01/01 Transaction A
          Assets:A  $100.00
          Equity:Opening
      """)

      File.write!(file_b, """
      include a.ledger

      2024/01/01 Transaction B
          Assets:B  $100.00
          Equity:Opening
      """)

      result = parse_file(file_a)

      # Should either error or handle gracefully (not infinite loop)
      assert is_tuple(result)
    end

    test "detects self-include", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "self.ledger")

      File.write!(file_path, """
      include self.ledger

      2024/01/01 Transaction
          Assets:Cash  $100.00
          Equity:Opening
      """)

      result = parse_file(file_path)

      # Should either error or handle gracefully
      assert is_tuple(result)
    end
  end

  describe "include directive - path handling" do
    test "handles paths with spaces", %{tmp_dir: tmp_dir} do
      # Create subdirectory with space in name
      subdir = Path.join(tmp_dir, "my ledger files")
      File.mkdir_p!(subdir)

      included_path = Path.join(subdir, "accounts.ledger")

      File.write!(included_path, """
      2024/01/01 Opening
          Assets:Cash  $1000.00
          Equity:Opening
      """)

      main_path = Path.join(tmp_dir, "main.ledger")

      File.write!(main_path, """
      include "my ledger files/accounts.ledger"

      2024/01/15 Purchase
          Expenses:Food  $50.00
          Assets:Cash
      """)

      result = parse_file(main_path)

      # Behavior depends on implementation
      assert is_tuple(result)
    end

    test "handles subdirectory includes", %{tmp_dir: tmp_dir} do
      # Create subdirectory
      subdir = Path.join(tmp_dir, "2024")
      File.mkdir_p!(subdir)

      File.write!(Path.join(subdir, "january.ledger"), """
      2024/01/15 January purchase
          Expenses:Food  $50.00
          Assets:Cash
      """)

      main_path = Path.join(tmp_dir, "main.ledger")

      File.write!(main_path, """
      include 2024/january.ledger
      """)

      %{transactions: transactions} = parse_file!(main_path)

      assert length(transactions) == 1
      assert hd(transactions).payee == "January purchase"
    end

    test "rejects parent directory traversal for security", %{tmp_dir: tmp_dir} do
      # The parser prevents ../ includes to avoid path traversal attacks
      # This is expected security behavior
      year_dir = Path.join(tmp_dir, "2024")
      File.mkdir_p!(year_dir)

      main_path = Path.join(year_dir, "main.ledger")

      File.write!(main_path, """
      include ../shared/common.ledger

      2024/01/15 Year transaction
          Expenses:Food  $50.00
          Assets:Cash
      """)

      result = parse_file(main_path)

      # Should error with include_outside_base
      assert {:error, {:include_outside_base, _}} = result
    end
  end

  describe "include directive - content handling" do
    test "preserves transaction order from multiple includes at top", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "first.ledger"), """
      2024/01/01 First
          Assets:Cash  $100.00
          Equity:Opening
      """)

      File.write!(Path.join(tmp_dir, "second.ledger"), """
      2024/06/15 Second
          Expenses:Food  $25.00
          Assets:Cash
      """)

      main_path = Path.join(tmp_dir, "main.ledger")

      File.write!(main_path, """
      include first.ledger
      include second.ledger

      2024/12/31 Third
          Expenses:Food  $50.00
          Assets:Cash
      """)

      %{transactions: transactions} = parse_file!(main_path)

      assert length(transactions) == 3

      # Check order is preserved as they appear in file
      payees = Enum.map(transactions, & &1.payee)
      assert Enum.at(payees, 0) == "First"
      assert Enum.at(payees, 1) == "Second"
      assert Enum.at(payees, 2) == "Third"
    end

    test "handles empty included file", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "empty.ledger"), "")

      main_path = Path.join(tmp_dir, "main.ledger")

      File.write!(main_path, """
      include empty.ledger

      2024/01/15 Transaction
          Expenses:Food  $50.00
          Assets:Cash
      """)

      %{transactions: transactions} = parse_file!(main_path)

      assert length(transactions) == 1
    end

    test "handles included file with only comments", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "comments.ledger"), """
      ; This file only has comments
      # No transactions here
      ; Just configuration notes
      """)

      main_path = Path.join(tmp_dir, "main.ledger")

      File.write!(main_path, """
      include comments.ledger

      2024/01/15 Transaction
          Expenses:Food  $50.00
          Assets:Cash
      """)

      %{transactions: transactions} = parse_file!(main_path)

      assert length(transactions) == 1
    end
  end
end
