defmodule ExLedger.LedgerParserPrimitivesTest do
  use ExUnit.Case
  alias ExLedger.LedgerParser
  import ExLedger.TransactionHelpers

  @moduledoc """
  Tests for primitive parsing functions: parse_date, parse_posting, parse_note,
  parse_account_declaration, and parse_amount.
  """

  describe "parse_date/1" do
    test "parses YYYY/MM/DD format" do
      assert {:ok, ~D[2009-10-29]} = LedgerParser.parse_date("2009/10/29")
      assert {:ok, ~D[2009-10-30]} = LedgerParser.parse_date("2009/10/30")
      assert {:ok, ~D[2009-10-31]} = LedgerParser.parse_date("2009/10/31")
    end

    test "returns error for invalid date" do
      assert {:error, _reason} = LedgerParser.parse_date("invalid")
      assert {:error, _reason} = LedgerParser.parse_date("10-29-2009")
    end

    test "parses date with dot separator" do
      assert {:ok, ~D[2009-10-29]} = LedgerParser.parse_date("2009.10.29")
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
end
