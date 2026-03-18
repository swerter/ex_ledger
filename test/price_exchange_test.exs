defmodule ExLedger.PriceExchangeTest do
  @moduledoc """
  Tests for price directives, price database, and currency exchange.
  """

  use ExUnit.Case
  alias ExLedger.LedgerParser
  alias ExLedger.Parser.Price
  alias ExLedger.Exchange

  describe "Price.extract_price_directives/1" do
    test "extracts single price directive" do
      input = "P 2026-01-15 EUR CHF 0.9432"

      prices = Price.extract_price_directives(input)

      assert length(prices) == 1
      [price] = prices
      assert price.date == ~D[2026-01-15]
      assert price.commodity == "EUR"
      assert price.price.value == 0.9432
      assert price.price.currency == "CHF"
    end

    test "extracts multiple price directives" do
      input = """
      P 2026-01-15 EUR CHF 0.9432
      P 2026-01-15 USD CHF 0.8821
      P 2026-02-01 EUR CHF 0.9455
      """

      prices = Price.extract_price_directives(input)

      assert length(prices) == 3
      assert Enum.at(prices, 0).commodity == "EUR"
      assert Enum.at(prices, 1).commodity == "USD"
      assert Enum.at(prices, 2).date == ~D[2026-02-01]
    end

    test "handles date with slash separator" do
      input = "P 2026/01/15 EUR CHF 0.9432"

      [price] = Price.extract_price_directives(input)

      assert price.date == ~D[2026-01-15]
    end

    test "handles dollar sign currency" do
      input = "P 2026-01-15 AAPL $150.00"

      [price] = Price.extract_price_directives(input)

      assert price.commodity == "AAPL"
      assert price.price.value == 150.0
      assert price.price.currency == "$"
    end

    test "ignores non-price lines" do
      input = """
      ; This is a comment
      P 2026-01-15 EUR CHF 0.9432

      2026-01-15 Test Transaction
          Expenses:Test  $10.00
          Assets:Cash

      commodity CHF
      """

      prices = Price.extract_price_directives(input)

      assert length(prices) == 1
    end

    test "returns empty list for no price directives" do
      input = """
      2026-01-15 Test Transaction
          Expenses:Test  $10.00
          Assets:Cash
      """

      prices = Price.extract_price_directives(input)

      assert prices == []
    end
  end

  describe "Price.build_price_db/1" do
    test "builds price database indexed by currency pair" do
      prices = [
        %{date: ~D[2026-01-15], commodity: "EUR", price: %{value: 0.9432, currency: "CHF"}},
        %{date: ~D[2026-02-01], commodity: "EUR", price: %{value: 0.9455, currency: "CHF"}}
      ]

      db = Price.build_price_db(prices)

      assert Map.has_key?(db, {"EUR", "CHF"})
      entries = db[{"EUR", "CHF"}]
      # Should be sorted by date descending
      assert length(entries) == 2
      assert Enum.at(entries, 0) == {~D[2026-02-01], 0.9455}
      assert Enum.at(entries, 1) == {~D[2026-01-15], 0.9432}
    end

    test "groups multiple currency pairs" do
      prices = [
        %{date: ~D[2026-01-15], commodity: "EUR", price: %{value: 0.9432, currency: "CHF"}},
        %{date: ~D[2026-01-15], commodity: "USD", price: %{value: 0.8821, currency: "CHF"}}
      ]

      db = Price.build_price_db(prices)

      assert Map.has_key?(db, {"EUR", "CHF"})
      assert Map.has_key?(db, {"USD", "CHF"})
    end
  end

  describe "Price.lookup_price/4" do
    setup do
      prices = [
        %{date: ~D[2026-01-15], commodity: "EUR", price: %{value: 0.9432, currency: "CHF"}},
        %{date: ~D[2026-02-01], commodity: "EUR", price: %{value: 0.9455, currency: "CHF"}},
        %{date: ~D[2026-01-15], commodity: "USD", price: %{value: 0.8821, currency: "CHF"}}
      ]

      db = Price.build_price_db(prices)
      {:ok, db: db}
    end

    test "returns price for exact date match", %{db: db} do
      assert {:ok, 0.9432} = Price.lookup_price("EUR", "CHF", ~D[2026-01-15], db)
    end

    test "returns most recent price on or before date", %{db: db} do
      # Date between Jan 15 and Feb 1 should return Jan 15 price
      assert {:ok, 0.9432} = Price.lookup_price("EUR", "CHF", ~D[2026-01-20], db)
    end

    test "returns latest price for date after all prices", %{db: db} do
      assert {:ok, 0.9455} = Price.lookup_price("EUR", "CHF", ~D[2026-03-01], db)
    end

    test "returns error for date before any price", %{db: db} do
      assert {:error, :no_price_found} = Price.lookup_price("EUR", "CHF", ~D[2026-01-01], db)
    end

    test "returns error for unknown currency pair", %{db: db} do
      assert {:error, :no_price_found} = Price.lookup_price("GBP", "CHF", ~D[2026-01-15], db)
    end
  end

  describe "Exchange.convert_value/5" do
    setup do
      prices = [
        %{date: ~D[2026-01-15], commodity: "EUR", price: %{value: 0.9432, currency: "CHF"}},
        %{date: ~D[2026-01-15], commodity: "USD", price: %{value: 0.8821, currency: "CHF"}}
      ]

      db = Price.build_price_db(prices)
      {:ok, db: db}
    end

    test "converts value using direct price", %{db: db} do
      {:ok, result} = Exchange.convert_value(100.0, "EUR", "CHF", ~D[2026-01-15], db)
      assert_in_delta result, 94.32, 0.01
    end

    test "converts value using inverse price", %{db: db} do
      {:ok, result} = Exchange.convert_value(100.0, "CHF", "EUR", ~D[2026-01-15], db)
      # 100 / 0.9432 = ~106.02
      assert_in_delta result, 106.02, 0.1
    end

    test "returns error for no conversion path", %{db: db} do
      assert {:error, {:no_conversion_path, "GBP", "CHF"}} =
               Exchange.convert_value(100.0, "GBP", "CHF", ~D[2026-01-15], db)
    end
  end

  describe "Exchange.convert_value/5 transitive conversion" do
    setup do
      # EUR -> USD, USD -> CHF but no direct EUR -> CHF
      prices = [
        %{date: ~D[2026-01-15], commodity: "EUR", price: %{value: 1.10, currency: "USD"}},
        %{date: ~D[2026-01-15], commodity: "USD", price: %{value: 0.88, currency: "CHF"}}
      ]

      db = Price.build_price_db(prices)
      {:ok, db: db}
    end

    test "converts through intermediate currency", %{db: db} do
      {:ok, result} = Exchange.convert_value(100.0, "EUR", "CHF", ~D[2026-01-15], db)
      # 100 EUR * 1.10 USD/EUR * 0.88 CHF/USD = 96.8 CHF
      assert_in_delta result, 96.8, 0.1
    end
  end

  describe "Exchange.exchange/3" do
    setup do
      prices = [
        %{date: ~D[2026-01-15], commodity: "EUR", price: %{value: 0.9432, currency: "CHF"}}
      ]

      db = Price.build_price_db(prices)
      {:ok, db: db}
    end

    test "converts all postings in transactions", %{db: db} do
      transactions = [
        %{
          date: ~D[2026-01-15],
          postings: [
            %{account: "Expenses:Office", amount: %{value: 85.0, currency: "EUR", currency_position: :leading}},
            %{account: "Assets:Bank", amount: %{value: -85.0, currency: "EUR", currency_position: :leading}}
          ]
        }
      ]

      {:ok, [converted]} = Exchange.exchange(transactions, "CHF", db)

      [posting1, posting2] = converted.postings
      assert posting1.amount.currency == "CHF"
      assert_in_delta posting1.amount.value, 80.17, 0.1
      assert posting2.amount.currency == "CHF"
      assert_in_delta posting2.amount.value, -80.17, 0.1
    end

    test "leaves amounts without currency unchanged", %{db: db} do
      transactions = [
        %{
          date: ~D[2026-01-15],
          postings: [
            %{account: "Expenses:Office", amount: %{value: 85.0, currency: nil, currency_position: nil}},
            %{account: "Assets:Bank", amount: nil}
          ]
        }
      ]

      {:ok, [converted]} = Exchange.exchange(transactions, "CHF", db)

      [posting1, posting2] = converted.postings
      assert posting1.amount.currency == nil
      assert posting2.amount == nil
    end

    test "leaves amounts already in target currency unchanged", %{db: db} do
      transactions = [
        %{
          date: ~D[2026-01-15],
          postings: [
            %{account: "Expenses:Office", amount: %{value: 100.0, currency: "CHF", currency_position: :leading}}
          ]
        }
      ]

      {:ok, [converted]} = Exchange.exchange(transactions, "CHF", db)

      [posting] = converted.postings
      assert posting.amount.currency == "CHF"
      assert posting.amount.value == 100.0
    end
  end

  describe "Exchange.convertible_currencies/3" do
    test "returns currencies that can be converted to target" do
      prices = [
        %{date: ~D[2026-01-15], commodity: "EUR", price: %{value: 0.9432, currency: "CHF"}},
        %{date: ~D[2026-01-15], commodity: "USD", price: %{value: 0.8821, currency: "CHF"}},
        %{date: ~D[2026-01-15], commodity: "GBP", price: %{value: 1.15, currency: "EUR"}}
      ]

      db = Price.build_price_db(prices)

      # Direct conversions to CHF
      convertible = Exchange.convertible_currencies("CHF", ~D[2026-01-15], db)
      assert "EUR" in convertible
      assert "USD" in convertible
      # GBP can convert via EUR->CHF (transitive)
      assert "GBP" in convertible
    end

    test "returns empty list when no conversions available" do
      db = Price.build_price_db([])
      assert Exchange.convertible_currencies("CHF", ~D[2026-01-15], db) == []
    end
  end

  describe "LedgerParser.parse_ledger/2 returns prices" do
    test "includes prices in parse result" do
      input = """
      P 2026-01-15 EUR CHF 0.9432

      2026-01-15 Test
          Expenses:Test  CHF 10.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)

      assert length(result.transactions) == 1
      assert length(result.prices) == 1
      [price] = result.prices
      assert price.commodity == "EUR"
    end

    test "includes commodities in parse result" do
      input = """
      commodity CHF
          format CHF 1'000.00
          note Swiss Franc

      2026/01/15 Test
          Expenses:Test  CHF 10.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)

      assert Map.has_key?(result.commodities, "CHF")
      commodity = result.commodities["CHF"]
      assert commodity.format == "CHF 1'000.00"
      assert commodity.note == "Swiss Franc"
    end

    test "parse result has correct structure" do
      {:ok, result} = LedgerParser.parse_ledger("")

      assert Map.has_key?(result, :transactions)
      assert Map.has_key?(result, :accounts)
      assert Map.has_key?(result, :prices)
      assert Map.has_key?(result, :commodities)
    end
  end

  describe "commodity definitions parsing" do
    test "parses commodity with all fields" do
      input = """
      commodity CHF
          format CHF 1'000.00
          note Swiss Franc
          alias SFr
          default
          nomarket

      2026-01-15 Test
          Expenses:Test  CHF 10.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)

      commodity = result.commodities["CHF"]
      assert commodity.symbol == "CHF"
      assert commodity.format == "CHF 1'000.00"
      assert commodity.note == "Swiss Franc"
      assert commodity.alias == "SFr"
      assert commodity.default == true
      assert commodity.nomarket == true
    end

    test "parses commodity with minimal fields" do
      input = """
      commodity USD

      2026-01-15 Test
          Expenses:Test  $10.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)

      commodity = result.commodities["USD"]
      assert commodity.symbol == "USD"
      assert commodity.format == nil
      assert commodity.note == nil
      assert commodity.default == false
    end

    test "parses multiple commodities" do
      input = """
      commodity CHF
          format CHF 1'000.00

      commodity EUR
          format EUR 1.000,00

      2026-01-15 Test
          Expenses:Test  CHF 10.00
          Assets:Cash
      """

      {:ok, result} = LedgerParser.parse_ledger(input)

      assert Map.has_key?(result.commodities, "CHF")
      assert Map.has_key?(result.commodities, "EUR")
    end
  end
end
