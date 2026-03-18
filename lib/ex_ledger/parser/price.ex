defmodule ExLedger.Parser.Price do
  @moduledoc """
  Parser for price directives (P DATE COMMODITY PRICE).

  Provides extraction, parsing, and lookup functionality for price data.
  """

  alias ExLedger.Parser.{Core, Transaction}

  @type price_directive :: Core.price_directive()
  @type price_db :: %{{String.t(), String.t()} => [{Date.t(), float()}]}

  @doc """
  Extracts all price directives from input.

  Returns a list of price directive maps with date, commodity, and price.

  ## Examples

      iex> input = \"\"\"
      ...> P 2026-01-15 EUR CHF 0.9432
      ...> P 2026-01-15 USD CHF 0.8821
      ...> \"\"\"
      iex> Price.extract_price_directives(input)
      [
        %{date: ~D[2026-01-15], commodity: "EUR", price: %{value: 0.9432, currency: "CHF", currency_position: :leading}},
        %{date: ~D[2026-01-15], commodity: "USD", price: %{value: 0.8821, currency: "CHF", currency_position: :leading}}
      ]
  """
  @spec extract_price_directives(String.t()) :: [price_directive()]
  def extract_price_directives(input) when is_binary(input) do
    input
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case parse_price_directive(line) do
        {:ok, price} -> [price | acc]
        :skip -> acc
      end
    end)
    |> Enum.reverse()
  end

  @doc """
  Parses a single price directive line.

  Format: P DATE COMMODITY PRICE
  - DATE: YYYY/MM/DD or YYYY-MM-DD
  - COMMODITY: The source commodity symbol (e.g., EUR, USD, AAPL)
  - PRICE: The price amount with target currency (e.g., CHF 0.9432 or $150.00)

  ## Examples

      iex> Price.parse_price_directive("P 2026-01-15 EUR CHF 0.9432")
      {:ok, %{date: ~D[2026-01-15], commodity: "EUR", price: %{value: 0.9432, currency: "CHF", currency_position: :leading}}}

      iex> Price.parse_price_directive("P 2026/01/15 AAPL $150.00")
      {:ok, %{date: ~D[2026-01-15], commodity: "AAPL", price: %{value: 150.0, currency: "$", currency_position: :leading}}}
  """
  @spec parse_price_directive(String.t()) :: {:ok, price_directive()} | :skip
  def parse_price_directive(line) when is_binary(line) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "P ") do
      parse_price_line(trimmed)
    else
      :skip
    end
  end

  @doc """
  Builds a price database from a list of price directives.

  The database is indexed by {source_commodity, target_commodity} tuples,
  with prices sorted by date descending for efficient lookup.

  ## Examples

      iex> prices = [
      ...>   %{date: ~D[2026-01-15], commodity: "EUR", price: %{value: 0.9432, currency: "CHF"}},
      ...>   %{date: ~D[2026-02-01], commodity: "EUR", price: %{value: 0.9455, currency: "CHF"}}
      ...> ]
      iex> db = Price.build_price_db(prices)
      iex> db[{"EUR", "CHF"}]
      [{~D[2026-02-01], 0.9455}, {~D[2026-01-15], 0.9432}]
  """
  @spec build_price_db([price_directive()]) :: price_db()
  def build_price_db(prices) when is_list(prices) do
    prices
    |> Enum.group_by(
      fn %{commodity: commodity, price: %{currency: currency}} ->
        {commodity, currency}
      end,
      fn %{date: date, price: %{value: value}} ->
        {date, value}
      end
    )
    |> Enum.into(%{}, fn {key, entries} ->
      # Sort by date descending for efficient lookup
      sorted = Enum.sort_by(entries, fn {date, _} -> date end, {:desc, Date})
      {key, sorted}
    end)
  end

  @doc """
  Looks up the price for a commodity on a given date.

  Returns the most recent price on or before the given date.

  ## Examples

      iex> db = %{{"EUR", "CHF"} => [{~D[2026-02-01], 0.9455}, {~D[2026-01-15], 0.9432}]}
      iex> Price.lookup_price("EUR", "CHF", ~D[2026-01-20], db)
      {:ok, 0.9432}

      iex> Price.lookup_price("EUR", "CHF", ~D[2026-02-15], db)
      {:ok, 0.9455}

      iex> Price.lookup_price("EUR", "CHF", ~D[2026-01-01], db)
      {:error, :no_price_found}
  """
  @spec lookup_price(String.t(), String.t(), Date.t(), price_db()) ::
          {:ok, float()} | {:error, :no_price_found}
  def lookup_price(from_commodity, to_commodity, date, price_db) do
    case Map.get(price_db, {from_commodity, to_commodity}) do
      nil ->
        {:error, :no_price_found}

      entries ->
        # Find the most recent price on or before the date
        case Enum.find(entries, fn {price_date, _} ->
               Date.compare(price_date, date) != :gt
             end) do
          {_price_date, value} -> {:ok, value}
          nil -> {:error, :no_price_found}
        end
    end
  end

  @doc """
  Returns all available commodity pairs in the price database.

  ## Examples

      iex> db = %{{"EUR", "CHF"} => [...], {"USD", "CHF"} => [...]}
      iex> Price.available_pairs(db)
      [{"EUR", "CHF"}, {"USD", "CHF"}]
  """
  @spec available_pairs(price_db()) :: [{String.t(), String.t()}]
  def available_pairs(price_db) do
    Map.keys(price_db)
  end

  @doc """
  Returns all commodities that can be converted to the target currency.

  ## Examples

      iex> db = %{{"EUR", "CHF"} => [...], {"USD", "CHF"} => [...], {"GBP", "EUR"} => [...]}
      iex> Price.commodities_convertible_to("CHF", db)
      ["EUR", "USD"]
  """
  @spec commodities_convertible_to(String.t(), price_db()) :: [String.t()]
  def commodities_convertible_to(target, price_db) do
    price_db
    |> Map.keys()
    |> Enum.filter(fn {_from, to} -> to == target end)
    |> Enum.map(fn {from, _to} -> from end)
    |> Enum.sort()
  end

  # Private functions

  defp parse_price_line(line) do
    # Format: P DATE COMMODITY PRICE
    # Example: P 2026-01-15 EUR CHF 0.9432
    # Example: P 2026/01/15 AAPL $150.00

    # Remove the P prefix and trim
    rest = line |> String.trim_leading("P") |> String.trim()

    # Split into parts: date, commodity, and price (which may have multiple parts)
    parts = String.split(rest, ~r/\s+/, parts: 3)

    case parts do
      [date_str, commodity, price_str] ->
        with {:ok, date} <- Transaction.parse_date(date_str),
             {:ok, amount} <- Transaction.parse_amount(price_str) do
          {:ok,
           %{
             date: date,
             commodity: commodity,
             price: amount
           }}
        else
          _ -> :skip
        end

      _ ->
        :skip
    end
  end
end
