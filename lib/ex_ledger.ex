defmodule ExLedger do
  @moduledoc """
  Main module for ExLedger - a ledger-cli format parser and processor.

  Provides utility functions for formatting dates and amounts in ledger format.
  """

  @month_names ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  Formats a Date struct into ledger register format: YY-Mon-DD

  ## Examples

      iex> ExLedger.format_date(~D[2009-10-29])
      "09-Oct-29"

      iex> ExLedger.format_date(~D[2009-11-01])
      "09-Nov-01"
  """
  @spec format_date(Date.t()) :: String.t()
  def format_date(%Date{year: year, month: month, day: day}) do
    year_short = rem(year, 100)
    month_name = Enum.at(@month_names, month - 1)

    "#{pad_two(year_short)}-#{month_name}-#{pad_two(day)}"
  end

  @doc """
  Formats a float amount into ledger format with currency symbol and 2 decimal places.

  ## Examples

      iex> ExLedger.format_amount(4.50)
      "    $4.50"

      iex> ExLedger.format_amount(-4.50)
      "   -$4.50"

      iex> ExLedger.format_amount(20.00)
      "   $20.00"
  """
  @spec format_amount(number()) :: String.t()
  def format_amount(amount) when is_float(amount) or is_integer(amount) do
    normalized_amount = amount * 1.0
    sign = if normalized_amount < 0, do: "-", else: ""
    abs_amount = abs(normalized_amount)

    formatted = :erlang.float_to_binary(abs_amount, decimals: 2)
    String.pad_leading("#{sign}$#{formatted}", 9)
  end

  @doc """
  Returns list of month abbreviations.
  """
  @spec month_names() :: [String.t()]
  def month_names, do: @month_names

  defp pad_two(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
  end
end
