defmodule ExLedger.Parser.Helpers do
  @moduledoc """
  Shared helper functions used across parser modules.
  """

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
  @spec format_amount_for_currency(number(), String.t() | nil, atom() | nil) :: String.t()
  def format_amount_for_currency(value, currency, currency_position \\ :leading) do
    sign = if value < 0, do: "-", else: ""
    abs_value = abs(value)
    formatted = :erlang.float_to_binary(abs_value, decimals: 2)
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
