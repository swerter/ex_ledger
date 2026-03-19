defmodule ExLedger.Parser.Helpers do
  @moduledoc """
  Shared helper functions used across parser modules.
  """

  @doc """
  Converts a value to Decimal.

  Accepts Decimal, float, or integer values.
  """
  @spec to_decimal(Decimal.t() | number()) :: Decimal.t()
  def to_decimal(%Decimal{} = d), do: d
  def to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  def to_decimal(n) when is_integer(n), do: Decimal.new(n)

  @doc """
  Ensures a numeric string has exactly two decimal places.

  ## Examples

      iex> ensure_two_decimals("42")
      "42.00"

      iex> ensure_two_decimals("42.5")
      "42.50"

      iex> ensure_two_decimals("42.50")
      "42.50"
  """
  @spec ensure_two_decimals(String.t()) :: String.t()
  def ensure_two_decimals(str) do
    case String.split(str, ".") do
      [int_part] -> int_part <> ".00"
      [int_part, dec_part] when byte_size(dec_part) == 1 -> int_part <> "." <> dec_part <> "0"
      _ -> str
    end
  end

  @doc """
  Filters transactions to only include regular transactions (not automated/periodic).
  """
  @spec regular_transactions([map()]) :: [map()]
  def regular_transactions(transactions) when is_list(transactions) do
    Enum.filter(transactions, &regular_transaction?/1)
  end

  @doc """
  Checks if a transaction is a regular transaction (has a date and is not automated/periodic).
  """
  @spec regular_transaction?(map()) :: boolean()
  def regular_transaction?(transaction) do
    Map.get(transaction, :kind, :regular) == :regular and not is_nil(transaction.date)
  end

  @doc """
  Returns all postings from a list of transactions.
  """
  @spec all_postings([map()]) :: [map()]
  def all_postings(transactions) when is_list(transactions) do
    Enum.flat_map(transactions, & &1.postings)
  end

  @doc """
  Returns all postings from regular transactions only.
  """
  @spec regular_postings([map()]) :: [map()]
  def regular_postings(transactions) when is_list(transactions) do
    transactions
    |> regular_transactions()
    |> all_postings()
  end

  @doc """
  Formats an amount value for a given currency.
  """
  @spec format_amount_for_currency(Decimal.t() | number(), String.t() | nil, atom() | nil) ::
          String.t()
  def format_amount_for_currency(value, currency, currency_position \\ :leading)

  def format_amount_for_currency(%Decimal{} = value, currency, currency_position) do
    sign = if Decimal.negative?(value), do: "-", else: ""
    abs_value = Decimal.abs(value)
    formatted = abs_value |> Decimal.round(2) |> Decimal.to_string(:normal)
    # Ensure we always have 2 decimal places
    formatted = ensure_two_decimals(formatted)
    position = currency_position || :leading

    case {currency, position} do
      {nil, _} ->
        sign <> formatted

      {"", _} ->
        sign <> formatted

      {"$", :leading} ->
        "$" <> sign <> formatted

      {currency, :leading} ->
        "#{currency} #{sign}#{formatted}"

      {currency, :trailing} ->
        "#{sign}#{formatted} #{currency}"
    end
  end

  def format_amount_for_currency(value, currency, currency_position)
      when is_number(value) do
    format_amount_for_currency(Decimal.from_float(value * 1.0), currency, currency_position)
  end

  @doc """
  Extracts the currency from a posting's amount.
  """
  @spec posting_currency(map()) :: String.t() | nil
  def posting_currency(%{amount: %{currency: currency}}), do: currency
  def posting_currency(_posting), do: nil

  @doc """
  Extracts the value from a posting's amount.
  """
  @spec posting_amount_value(map()) :: number() | nil
  def posting_amount_value(%{amount: %{value: value}}), do: value
  def posting_amount_value(_posting), do: nil

  @doc """
  Returns a sorted list of unique items.
  """
  @spec uniq_sort([any()]) :: [any()]
  def uniq_sort(items) do
    items
    |> Enum.uniq()
    |> Enum.sort()
  end
end
