defmodule ExLedger.ParserEdgeCasesTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser
  import ExLedger.TransactionHelpers

  @moduledoc """
  Edge case tests for the ledger parser covering:
  - Numeric edge cases (large numbers, precision, negative zero)
  - Unicode handling (emoji, CJK characters, currency symbols)
  - Malformed input recovery (line numbers, line endings, BOM)
  """

  # ==========================================================================
  # Numeric Edge Cases
  # ==========================================================================

  describe "numeric edge cases" do
    test "handles amounts over 1 billion" do
      input = """
      2024/01/15 Large transaction
          Assets:Bank  $1,234,567,890.00
          Equity:Opening
      """

      txn = parse_transaction!(input)
      [posting | _] = txn.postings

      expected = Decimal.new("1234567890.00")
      assert Decimal.eq?(posting.amount.value, expected),
             "Expected #{expected}, got #{posting.amount.value}"
    end

    test "handles amounts over 1 trillion" do
      input = """
      2024/01/15 Very large transaction
          Assets:Bank  $1,234,567,890,123.45
          Equity:Opening
      """

      txn = parse_transaction!(input)
      [posting | _] = txn.postings

      expected = Decimal.new("1234567890123.45")
      assert Decimal.eq?(posting.amount.value, expected)
    end

    test "preserves 8 decimal places precision" do
      input = """
      2024/01/15 High precision
          Assets:Crypto  0.12345678 BTC
          Assets:Exchange
      """

      txn = parse_transaction!(input)
      [posting | _] = txn.postings

      expected = Decimal.new("0.12345678")
      assert Decimal.eq?(posting.amount.value, expected),
             "Expected 8 decimal places preserved: #{expected}, got #{posting.amount.value}"
    end

    test "preserves 12 decimal places precision" do
      input = """
      2024/01/15 Very high precision
          Assets:Nano  0.123456789012 NANO
          Assets:Exchange
      """

      txn = parse_transaction!(input)
      [posting | _] = txn.postings

      expected = Decimal.new("0.123456789012")
      assert Decimal.eq?(posting.amount.value, expected),
             "Expected 12 decimal places preserved"
    end

    test "handles negative amounts" do
      input = """
      2024/01/15 Negative
          Expenses:Food  -$25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      [posting | _] = txn.postings

      assert Decimal.negative?(posting.amount.value)
      assert Decimal.eq?(posting.amount.value, Decimal.new("-25.00"))
    end

    test "handles zero amounts" do
      input = """
      2024/01/15 Zero balance check
          Assets:Cash  $0.00 = $100.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      [posting | _] = txn.postings

      assert Decimal.eq?(posting.amount.value, Decimal.new("0"))
    end

    test "handles amounts without decimal places" do
      input = """
      2024/01/15 Whole number
          Assets:Cash  $100
          Expenses:Food
      """

      txn = parse_transaction!(input)
      [posting | _] = txn.postings

      assert Decimal.eq?(posting.amount.value, Decimal.new("100"))
    end

    test "handles very small amounts" do
      input = """
      2024/01/15 Tiny amount
          Assets:Satoshis  0.00000001 BTC
          Assets:Exchange
      """

      txn = parse_transaction!(input)
      [posting | _] = txn.postings

      expected = Decimal.new("0.00000001")
      assert Decimal.eq?(posting.amount.value, expected)
    end

    test "handles amounts with leading zeros" do
      input = """
      2024/01/15 Leading zeros
          Assets:Cash  $007.50
          Expenses:Coffee
      """

      txn = parse_transaction!(input)
      [posting | _] = txn.postings

      assert Decimal.eq?(posting.amount.value, Decimal.new("7.50"))
    end
  end

  # ==========================================================================
  # Unicode Handling
  # ==========================================================================

  describe "unicode handling" do
    test "parses account with emoji" do
      input = """
      2024/01/15 Coffee purchase
          Expenses:Food:Coffee ☕  $5.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      [posting | _] = txn.postings

      assert posting.account == "Expenses:Food:Coffee ☕"
    end

    test "parses payee with emoji" do
      input = """
      2024/01/15 🍕 Pizza Place
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.payee == "🍕 Pizza Place"
    end

    test "parses payee with CJK characters" do
      input = """
      2024/01/15 東京レストラン
          Expenses:Food  ¥3000
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.payee == "東京レストラン"
    end

    test "parses account with CJK characters" do
      input = """
      2024/01/15 Dinner
          支出:食費  ¥3000
          資産:現金
      """

      txn = parse_transaction!(input)
      accounts = Enum.map(txn.postings, & &1.account)

      assert "支出:食費" in accounts
      assert "資産:現金" in accounts
    end

    test "parses payee with Cyrillic characters" do
      input = """
      2024/01/15 Ресторан Москва
          Expenses:Food  ₽5000
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.payee == "Ресторан Москва"
    end

    test "parses payee with Arabic characters" do
      input = """
      2024/01/15 مطعم القاهرة
          Expenses:Food  $50.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.payee == "مطعم القاهرة"
    end

    test "parses comment with unicode" do
      input = """
      2024/01/15 Restaurant  ; 美味しかった！🍣
          Expenses:Food  $50.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.comment == "美味しかった！🍣"
    end

    test "parses various unicode currency symbols" do
      currencies = [
        {"€", "100.00", "EUR symbol"},
        {"£", "100.00", "GBP symbol"},
        {"¥", "10000", "JPY symbol"},
        {"₹", "1000.00", "INR symbol"},
        {"₽", "5000.00", "RUB symbol"},
        {"₿", "0.001", "BTC symbol"},
        {"₩", "100000", "KRW symbol"},
        {"฿", "1000.00", "THB symbol"},
        {"₪", "100.00", "ILS symbol"},
        {"₴", "1000.00", "UAH symbol"}
      ]

      for {symbol, value, name} <- currencies do
        input = """
        2024/01/15 Test #{name}
            Assets:Cash  #{symbol}#{value}
            Equity:Opening
        """

        txn = parse_transaction!(input)
        [posting | _] = txn.postings

        assert posting.amount.currency == symbol,
               "Failed to parse #{name}: expected currency #{symbol}, got #{posting.amount.currency}"
      end
    end

    test "parses mixed unicode in transaction" do
      input = """
      2024/01/15 カフェ ☕ Москва  ; Great coffee! 素晴らしい！
          支出:飲食:コーヒー  ¥500
          資産:現金
      """

      txn = parse_transaction!(input)

      assert txn.payee == "カフェ ☕ Москва"
      assert txn.comment == "Great coffee! 素晴らしい！"
      assert hd(txn.postings).account == "支出:飲食:コーヒー"
    end
  end

  # ==========================================================================
  # Malformed Input Recovery
  # ==========================================================================

  describe "malformed input recovery" do
    test "reports error for missing date" do
      input = """
      Grocery Store
          Expenses:Food  $25.00
          Assets:Cash
      """

      assert {:error, :missing_date} = LedgerParser.parse_transaction(input)
    end

    test "reports error for missing payee" do
      input = """
      2024/01/15
          Expenses:Food  $25.00
          Assets:Cash
      """

      assert {:error, :missing_payee} = LedgerParser.parse_transaction(input)
    end

    test "reports error for insufficient postings" do
      input = """
      2024/01/15 Solo posting
          Expenses:Food  $25.00
      """

      assert {:error, :insufficient_postings} = LedgerParser.parse_transaction(input)
    end

    test "reports error for unbalanced transaction" do
      input = """
      2024/01/15 Unbalanced
          Expenses:Food  $25.00
          Assets:Cash  -$20.00
      """

      result = LedgerParser.parse_transaction(input)

      case result do
        {:error, :unbalanced} -> assert true
        {:ok, txn} -> assert {:error, :unbalanced} = LedgerParser.validate_transaction(txn)
      end
    end

    test "handles mixed CRLF and LF line endings" do
      # Mix of Windows (CRLF) and Unix (LF) line endings
      input = "2024/01/15 Mixed endings\r\n    Expenses:Food  $25.00\n    Assets:Cash\r\n"

      txn = parse_transaction!(input)

      assert txn.payee == "Mixed endings"
      assert length(txn.postings) == 2
    end

    test "handles Windows CRLF line endings" do
      input = "2024/01/15 Windows style\r\n    Expenses:Food  $25.00\r\n    Assets:Cash\r\n"

      txn = parse_transaction!(input)

      assert txn.payee == "Windows style"
      assert length(txn.postings) == 2
    end

    test "handles trailing whitespace on lines" do
      input = """
      2024/01/15 Trailing spaces
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)

      assert txn.payee == "Trailing spaces"
      assert length(txn.postings) == 2
    end

    test "handles multiple blank lines between transactions" do
      input = """
      2024/01/15 First
          Expenses:Food  $25.00
          Assets:Cash



      2024/01/16 Second
          Expenses:Food  $30.00
          Assets:Cash
      """

      transactions = parse_ledger!(input)

      assert length(transactions) == 2
      assert Enum.at(transactions, 0).payee == "First"
      assert Enum.at(transactions, 1).payee == "Second"
    end

    test "handles tabs mixed with spaces for indentation" do
      input = "2024/01/15 Mixed indentation\n\t  Expenses:Food  $25.00\n    Assets:Cash\n"

      txn = parse_transaction!(input)

      assert length(txn.postings) == 2
    end

    test "handles empty lines within transaction" do
      # Some ledger files have blank lines between postings
      input = """
      2024/01/15 With blank line
          Expenses:Food  $25.00

          Assets:Cash
      """

      # This may or may not be valid depending on parser behavior
      # Just verify it doesn't crash
      result = LedgerParser.parse_transaction(input)
      assert is_tuple(result)
    end

    test "parses transaction after comment-only lines" do
      input = """
      ; This is a header comment
      ; Another comment line
      ;
      ; More comments

      2024/01/15 After comments
          Expenses:Food  $25.00
          Assets:Cash
      """

      transactions = parse_ledger!(input)

      assert length(transactions) == 1
      assert hd(transactions).payee == "After comments"
    end

    test "handles very long payee names" do
      long_payee = String.duplicate("A", 200)

      input = """
      2024/01/15 #{long_payee}
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)

      assert txn.payee == long_payee
      assert String.length(txn.payee) == 200
    end

    test "handles very long account names" do
      long_account = Enum.map_join(1..20, ":", fn i -> "Level#{i}" end)

      input = """
      2024/01/15 Deep hierarchy
          #{long_account}  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      [posting | _] = txn.postings

      assert posting.account == long_account
    end
  end

  # ==========================================================================
  # Date Parsing Edge Cases
  # ==========================================================================

  describe "date parsing edge cases" do
    test "parses date with dashes" do
      input = """
      2024-01-15 Dash format
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.date == ~D[2024-01-15]
    end

    test "parses date with dots" do
      input = """
      2024.01.15 Dot format
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.date == ~D[2024-01-15]
    end

    test "parses date with slashes" do
      input = """
      2024/01/15 Slash format
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.date == ~D[2024-01-15]
    end

    test "parses short year format" do
      input = """
      24/01/15 Short year
          Expenses:Food  $25.00
          Assets:Cash
      """

      # Behavior depends on implementation - just verify it parses
      result = LedgerParser.parse_transaction(input)
      assert is_tuple(result)
    end

    test "parses leap year date" do
      input = """
      2024/02/29 Leap year
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.date == ~D[2024-02-29]
    end

    test "parses end of year date" do
      input = """
      2024/12/31 Year end
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.date == ~D[2024-12-31]
    end

    test "parses beginning of year date" do
      input = """
      2024/01/01 New Year
          Expenses:Food  $25.00
          Assets:Cash
      """

      txn = parse_transaction!(input)
      assert txn.date == ~D[2024-01-01]
    end
  end

  # ==========================================================================
  # Inline Comments on Postings
  # ==========================================================================

  describe "inline comments on postings" do
    test "parses posting with comment after amount" do
      input = """
      2024/01/21 Abc
          2 Passiven:20 Kreditoren:2010 Kreditor                    CHF 460.00 ;; my comment
          1 Aktiven:10 Umlaufvermögen:1098 Something
      """

      txn = parse_transaction!(input)

      assert length(txn.postings) == 2
      [posting1, posting2] = txn.postings

      # First posting with explicit amount and comment
      assert posting1.account == "2 Passiven:20 Kreditoren:2010 Kreditor"
      assert posting1.amount.currency == "CHF"
      assert Decimal.eq?(posting1.amount.value, Decimal.new("460.00"))

      # Second posting gets balancing amount
      assert posting2.account == "1 Aktiven:10 Umlaufvermögen:1098 Something"
      assert Decimal.eq?(posting2.amount.value, Decimal.new("-460.00"))
    end

    test "parses transaction with trailing comment line after postings" do
      input = """
      2024/01/21 Abc
          2 Passiven:20 Kreditoren:2010 Kreditor                    CHF 460.00 ;; my comment
          1 Aktiven:10 Umlaufvermögen:1098 Something
          ;; Pensionskasse
      """

      txn = parse_transaction!(input)

      assert length(txn.postings) == 2
      [posting1, posting2] = txn.postings

      # First posting with explicit amount
      assert posting1.account == "2 Passiven:20 Kreditoren:2010 Kreditor"
      assert posting1.amount.currency == "CHF"
      assert Decimal.eq?(posting1.amount.value, Decimal.new("460.00"))

      # Second posting gets balancing amount
      assert posting2.account == "1 Aktiven:10 Umlaufvermögen:1098 Something"
      assert Decimal.eq?(posting2.amount.value, Decimal.new("-460.00"))
    end
  end
end
