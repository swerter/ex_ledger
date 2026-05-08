defmodule ExLedger.Predicate.AmountExpr do
  @moduledoc """
  Evaluates amount expressions in automated transaction postings.

  Amount expressions can be:
  - Fixed amounts: `$50.00`, `100 EUR` - used as-is
  - Multipliers: `1`, `-1`, `0.10` - multiply the matched posting's amount

  The distinction is based on whether a currency is specified:
  - With currency → fixed amount
  - Without currency (bare number) → multiplier

  ## Examples

      # Fixed amount - always $25
      iex> AmountExpr.evaluate(%{value: Decimal.new("25"), currency: "$"}, matched_amount)
      %{value: Decimal.new("25"), currency: "$"}

      # Multiplier -1 - negate matched amount
      iex> AmountExpr.evaluate(%{value: Decimal.new("-1"), currency: nil}, %{value: Decimal.new("50"), currency: "$"})
      %{value: Decimal.new("-50"), currency: "$"}

      # Multiplier 0.10 - 10% of matched amount
      iex> AmountExpr.evaluate(%{value: Decimal.new("0.10"), currency: nil}, %{value: Decimal.new("100"), currency: "$"})
      %{value: Decimal.new("10.00"), currency: "$"}
  """

  @type amount :: %{
          value: Decimal.t(),
          currency: String.t() | nil,
          currency_position: :leading | :trailing | nil
        }

  @doc """
  Evaluates an amount expression against a matched posting's amount.

  ## Parameters

  - `expr_amount` - The amount from the automated transaction posting
  - `matched_amount` - The amount from the posting that matched the predicate

  ## Returns

  A new amount map with the calculated value and appropriate currency.
  """
  @spec evaluate(amount() | nil, amount() | nil) :: amount() | nil
  def evaluate(nil, _matched_amount), do: nil
  def evaluate(_expr_amount, nil), do: nil

  def evaluate(expr_amount, matched_amount) do
    expr_currency = Map.get(expr_amount, :currency)
    expr_value = Map.get(expr_amount, :value)

    if is_fixed_amount?(expr_currency) do
      # Fixed amount - use as-is
      expr_amount
    else
      # Multiplier - multiply matched amount
      evaluate_multiplier(expr_value, matched_amount)
    end
  end

  @doc """
  Determines if an amount expression is a fixed amount or a multiplier.

  - Fixed: has a currency (e.g., `$50`, `100 EUR`)
  - Multiplier: no currency (e.g., `1`, `-1`, `0.10`)
  """
  @spec is_fixed_amount?(String.t() | nil) :: boolean()
  def is_fixed_amount?(nil), do: false
  def is_fixed_amount?(_currency), do: true

  @doc """
  Determines if an amount expression is a multiplier.
  """
  @spec is_multiplier?(amount()) :: boolean()
  def is_multiplier?(%{currency: nil}), do: true
  def is_multiplier?(%{currency: _}), do: false
  def is_multiplier?(_), do: false

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp evaluate_multiplier(multiplier, matched_amount) do
    matched_value = Map.get(matched_amount, :value)
    matched_currency = Map.get(matched_amount, :currency)
    matched_position = Map.get(matched_amount, :currency_position)

    multiplier_decimal = to_decimal(multiplier)
    matched_decimal = to_decimal(matched_value)

    result_value = Decimal.mult(matched_decimal, multiplier_decimal)

    %{
      value: result_value,
      currency: matched_currency,
      currency_position: matched_position
    }
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)
end
