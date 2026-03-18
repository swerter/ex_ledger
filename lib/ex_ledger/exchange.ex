defmodule ExLedger.Exchange do
  @moduledoc """
  Currency conversion using price database.

  Provides functions to convert amounts, postings, and transactions
  to a target currency using historical price data.

  ## Limitations

  - **Floating point precision**: Calculations use native floats, which may
    accumulate small precision errors. For high-precision financial reporting,
    consider rounding results appropriately.

  - **Single-hop transitive paths**: When no direct conversion exists (e.g., EUR→CHF),
    the module attempts conversion through one intermediate currency (EUR→USD→CHF).
    Multi-hop paths (EUR→USD→GBP→CHF) are not supported.

  - **Commodity aliases**: Commodity aliases parsed from declarations are not
    automatically resolved. Use canonical commodity symbols in transactions.
  """

  alias ExLedger.Parser.Price

  @type amount :: %{value: float(), currency: String.t() | nil, currency_position: atom() | nil}
  @type posting :: map()
  @type transaction :: map()
  @type price_db :: Price.price_db()

  @doc """
  Converts all transactions to a target currency.

  This is the main entry point for currency conversion, similar to
  ledger-cli's `--exchange` flag.

  ## Examples

      iex> prices = [
      ...>   %{date: ~D[2026-01-15], commodity: "EUR", price: %{value: 0.9432, currency: "CHF"}}
      ...> ]
      iex> price_db = Price.build_price_db(prices)
      iex> transactions = [%{date: ~D[2026-01-15], postings: [...]}]
      iex> Exchange.exchange(transactions, "CHF", price_db)
      {:ok, converted_transactions}
  """
  @spec exchange([transaction()], String.t(), price_db()) ::
          {:ok, [transaction()]} | {:error, {:no_conversion_path, String.t(), String.t()}}
  def exchange(transactions, target_currency, price_db) do
    result =
      Enum.reduce_while(transactions, {:ok, []}, fn transaction, {:ok, acc} ->
        case convert_transaction(transaction, target_currency, price_db) do
          {:ok, converted} ->
            {:cont, {:ok, [converted | acc]}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Converts all postings in a transaction to the target currency.

  Uses the transaction date for price lookup. Raises if transaction has no date.
  """
  @spec convert_transaction(transaction(), String.t(), price_db()) ::
          {:ok, transaction()} | {:error, {:no_conversion_path, String.t(), String.t()}}
  def convert_transaction(transaction, target_currency, price_db) when is_map(transaction) do
    date = transaction[:date] || raise ArgumentError, "transaction must have a date for conversion"

    result =
      Enum.reduce_while(transaction.postings, {:ok, []}, fn posting, {:ok, acc} ->
        case convert_posting(posting, target_currency, date, price_db) do
          {:ok, converted} ->
            {:cont, {:ok, [converted | acc]}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, converted_postings} ->
        {:ok, %{transaction | postings: Enum.reverse(converted_postings)}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Converts a single posting to the target currency.

  If the posting is already in the target currency, it's returned unchanged.
  If no direct conversion path exists, attempts transitive conversion.
  """
  @spec convert_posting(posting(), String.t(), Date.t(), price_db()) ::
          {:ok, posting()} | {:error, {:no_conversion_path, String.t(), String.t()}}
  def convert_posting(posting, target_currency, date, price_db) do
    case posting[:amount] do
      nil ->
        {:ok, posting}

      %{currency: nil} ->
        {:ok, posting}

      %{currency: currency} when currency == target_currency ->
        {:ok, posting}

      %{currency: from_currency, value: value} = amount ->
        case convert_value(value, from_currency, target_currency, date, price_db) do
          {:ok, converted_value} ->
            converted_amount = %{
              amount
              | value: converted_value,
                currency: target_currency
            }

            {:ok, %{posting | amount: converted_amount}}

          {:error, _} = error ->
            error
        end
    end
  end

  @doc """
  Converts a single amount to the target currency.

  ## Examples

      iex> amount = %{value: 100.0, currency: "EUR", currency_position: :leading}
      iex> Exchange.convert_amount(amount, "CHF", ~D[2026-01-15], price_db)
      {:ok, %{value: 94.32, currency: "CHF", currency_position: :leading}}
  """
  @spec convert_amount(amount(), String.t(), Date.t(), price_db()) ::
          {:ok, amount()} | {:error, {:no_conversion_path, String.t(), String.t()}}
  def convert_amount(amount, target_currency, date, price_db)

  def convert_amount(%{currency: nil} = amount, _target_currency, _date, _price_db) do
    {:ok, amount}
  end

  def convert_amount(%{currency: currency} = amount, target_currency, _date, _price_db)
      when currency == target_currency do
    {:ok, amount}
  end

  def convert_amount(%{currency: from_currency, value: value} = amount, target_currency, date, price_db) do
    case convert_value(value, from_currency, target_currency, date, price_db) do
      {:ok, converted_value} ->
        {:ok, %{amount | value: converted_value, currency: target_currency}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Converts a numeric value from one currency to another.

  Attempts direct conversion first, then tries transitive paths.
  """
  @spec convert_value(float(), String.t(), String.t(), Date.t(), price_db()) ::
          {:ok, float()} | {:error, {:no_conversion_path, String.t(), String.t()}}
  def convert_value(value, from_currency, to_currency, date, price_db) do
    # Try direct conversion
    case Price.lookup_price(from_currency, to_currency, date, price_db) do
      {:ok, rate} ->
        {:ok, value * rate}

      {:error, :no_price_found} ->
        # Try inverse conversion (if we have TO->FROM, use 1/rate)
        case Price.lookup_price(to_currency, from_currency, date, price_db) do
          {:ok, rate} ->
            {:ok, value / rate}

          {:error, :no_price_found} ->
            # Try transitive conversion through intermediate currencies
            try_transitive_conversion(value, from_currency, to_currency, date, price_db)
        end
    end
  end

  # Attempts to find a conversion path through intermediate currencies
  defp try_transitive_conversion(value, from_currency, to_currency, date, price_db) do
    # Get all intermediate currencies in a single pass
    {forward, inverse} =
      price_db
      |> Map.keys()
      |> Enum.reduce({[], []}, fn {from, to}, {fwd, inv} ->
        fwd = if from == from_currency, do: [to | fwd], else: fwd
        inv = if to == from_currency, do: [from | inv], else: inv
        {fwd, inv}
      end)

    all_intermediates = Enum.uniq(forward ++ inverse)

    # Try each intermediate
    result =
      Enum.find_value(all_intermediates, fn intermediate ->
        with {:ok, rate1} <- get_rate(from_currency, intermediate, date, price_db),
             {:ok, rate2} <- get_rate(intermediate, to_currency, date, price_db) do
          {:ok, value * rate1 * rate2}
        else
          _ -> nil
        end
      end)

    case result do
      {:ok, _} = success -> success
      nil -> {:error, {:no_conversion_path, from_currency, to_currency}}
    end
  end

  # Get rate with inverse fallback
  defp get_rate(from, to, date, price_db) do
    case Price.lookup_price(from, to, date, price_db) do
      {:ok, rate} ->
        {:ok, rate}

      {:error, :no_price_found} ->
        case Price.lookup_price(to, from, date, price_db) do
          {:ok, rate} -> {:ok, 1.0 / rate}
          error -> error
        end
    end
  end

  @doc """
  Checks if a conversion path exists between two currencies.

  Returns true if there's a direct, inverse, or transitive path.
  """
  @spec can_convert?(String.t(), String.t(), Date.t(), price_db()) :: boolean()
  def can_convert?(from_currency, to_currency, date, price_db) do
    case convert_value(1.0, from_currency, to_currency, date, price_db) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  Returns all currencies that can be converted to the target currency.

  Includes currencies with direct, inverse, and transitive paths.
  """
  @spec convertible_currencies(String.t(), Date.t(), price_db()) :: [String.t()]
  def convertible_currencies(target_currency, date, price_db) do
    # Get all unique currencies from the price database
    all_currencies =
      price_db
      |> Map.keys()
      |> Enum.flat_map(fn {from, to} -> [from, to] end)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == target_currency))

    # Filter to those that can be converted
    Enum.filter(all_currencies, fn currency ->
      can_convert?(currency, target_currency, date, price_db)
    end)
    |> Enum.sort()
  end
end
