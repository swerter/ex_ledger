defmodule ExLedger.Parser.Transaction do
  @moduledoc """
  Transaction parsing and validation.

  Handles parsing individual transactions, balancing postings,
  and validating that transactions are balanced.
  """

  alias ExLedger.Parser.Core

  @amount_regex Core.amount_regex()

  @doc """
  Parses a single transaction from a string.

  Returns `{:ok, transaction}` or `{:error, reason}`.
  """
  @spec parse_transaction(String.t()) :: {:ok, Core.transaction()} | {:error, Core.parse_error()}
  def parse_transaction(input) do
    with :ok <- check_basic_structure(input) do
      case select_transaction_parser(input).(input) do
        {:ok, [transaction], "", _, _, _} ->
          transaction = balance_postings(transaction)

          case validate_transaction(transaction) do
            :ok -> {:ok, transaction}
            error -> error
          end

        {:ok, _, rest, _, _, _} ->
          {:error, {:unexpected_input, rest}}

        {:error, _reason, _rest, _context, _line, _column} ->
          {:error, :parse_error}
      end
    end
  end

  @doc """
  Parses a date string in YYYY/MM/DD format.
  """
  @spec parse_date(String.t()) :: {:ok, Date.t()} | {:error, :invalid_date_format}
  def parse_date(date_string) when is_binary(date_string) do
    Core.run_parser(
      &Core.date_parser/1,
      date_string,
      fn {:date, date} -> {:ok, date} end,
      :invalid_date_format
    )
  end

  @doc """
  Parses a posting line.
  """
  @spec parse_posting(String.t()) :: {:ok, map()} | {:error, :invalid_posting}
  def parse_posting(line) do
    Core.run_parser(
      &Core.posting_parser/1,
      line,
      fn posting -> {:ok, posting} end,
      :invalid_posting
    )
  end

  @doc """
  Parses an amount string like $4.50 or -$20.00.
  """
  @spec parse_amount(String.t()) :: {:ok, Core.amount()} | {:error, :invalid_amount}
  def parse_amount(amount_string) when is_binary(amount_string) do
    Core.run_parser(&Core.amount_parser/1, amount_string, &{:ok, &1}, :invalid_amount)
  end

  @doc """
  Parses a note/comment line and determines its type.
  """
  @spec parse_note(String.t()) ::
          {:ok, {:tag, String.t()} | {:metadata, String.t(), String.t()} | {:comment, String.t()}}
          | {:error, :invalid_note}
  def parse_note(note_string) when is_binary(note_string) do
    Core.run_parser(&Core.note_parser/1, note_string, &{:ok, &1}, :invalid_note)
  end

  @doc """
  Balances postings by calculating the missing amount.
  """
  @spec balance_postings(Core.transaction()) :: Core.transaction()
  @spec balance_postings([Core.posting()]) :: [Core.posting()]
  def balance_postings(%{postings: postings} = transaction) do
    balanced_postings = balance_postings(postings)
    %{transaction | postings: balanced_postings}
  end

  def balance_postings(postings) when is_list(postings) do
    nil_count = Enum.count(postings, fn p -> is_nil(p.amount) end)

    case nil_count do
      1 -> balance_single_missing_amount(postings)
      _ -> postings
    end
  end

  @doc """
  Validates that a transaction is balanced (all postings sum to zero).
  """
  @spec validate_transaction(Core.transaction()) ::
          :ok | {:error, :multiple_nil_amounts | :multi_currency_missing_amount | :unbalanced}
  def validate_transaction(%{postings: postings}) do
    nil_count = Enum.count(postings, fn p -> is_nil(p.amount) end)

    cond do
      nil_count > 1 ->
        {:error, :multiple_nil_amounts}

      nil_count == 1 ->
        validate_single_missing_amount(postings)

      nil_count == 0 ->
        validate_balanced_postings(postings)

      true ->
        :ok
    end
  end

  # Private functions

  @spec check_basic_structure(String.t()) :: :ok | {:error, Core.parse_error()}
  defp check_basic_structure(input) do
    lines = String.split(input, "\n")
    first_line = Enum.at(lines, 0, "")
    trimmed_first = String.trim_leading(first_line)
    directive? = starts_with_directive?(trimmed_first)
    min_postings = if directive?, do: 1, else: 2
    postings_count = count_postings(lines)

    [
      check_missing_predicate(trimmed_first),
      check_missing_period(trimmed_first),
      check_directive_postings(directive?, postings_count, min_postings),
      check_missing_date(directive?, first_line),
      check_missing_payee(directive?, first_line),
      check_invalid_indentation(lines),
      check_min_postings(postings_count, min_postings),
      check_insufficient_spacing(lines)
    ]
    |> Enum.find(& &1)
    |> case do
      nil -> :ok
      error -> error
    end
  end

  defp check_missing_predicate(trimmed_first) do
    if starts_with_automated?(trimmed_first) and String.trim(trimmed_first) == "=" do
      {:error, :missing_predicate}
    end
  end

  defp check_missing_period(trimmed_first) do
    if starts_with_periodic?(trimmed_first) and String.trim(trimmed_first) == "~" do
      {:error, :missing_period}
    end
  end

  defp check_directive_postings(true, postings_count, min_postings) do
    if postings_count < min_postings do
      {:error, :insufficient_postings}
    end
  end

  defp check_directive_postings(false, _postings_count, _min_postings), do: nil

  defp check_missing_date(false, first_line) do
    if not Regex.match?(~r/^\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2}/, first_line) do
      {:error, :missing_date}
    end
  end

  defp check_missing_date(true, _first_line), do: nil

  defp check_missing_payee(false, first_line) do
    if not Regex.match?(
         ~r/^\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2}(?:=\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})?\s+(?:[*!]\s+)?(?:\([^)]+\)\s+)?(.+)/,
         first_line
       ) do
      {:error, :missing_payee}
    end
  end

  defp check_missing_payee(true, _first_line), do: nil

  defp check_invalid_indentation(lines) do
    if has_invalid_indentation?(lines) do
      {:error, :invalid_indentation}
    end
  end

  defp check_min_postings(postings_count, min_postings) do
    if postings_count < min_postings do
      {:error, :insufficient_postings}
    end
  end

  defp check_insufficient_spacing(lines) do
    if has_insufficient_spacing?(lines) do
      {:error, :insufficient_spacing}
    end
  end

  defp select_transaction_parser(input) do
    trimmed = String.trim_leading(input)

    cond do
      String.starts_with?(trimmed, "=") -> &Core.automated_transaction_parser/1
      String.starts_with?(trimmed, "~") -> &Core.periodic_transaction_parser/1
      true -> &Core.transaction_parser/1
    end
  end

  @spec count_postings([String.t()]) :: non_neg_integer()
  defp count_postings(lines) do
    lines
    |> Enum.drop(1)
    |> Enum.count(fn line ->
      Regex.match?(~r/^\s+[^\s;]/, line)
    end)
  end

  @spec has_invalid_indentation?([String.t()]) :: boolean()
  defp has_invalid_indentation?(lines) do
    lines
    |> Enum.drop(1)
    |> Enum.filter(fn line -> String.trim(line) != "" end)
    |> Enum.any?(fn line ->
      not Regex.match?(~r/^(\s+|\t)/, line)
    end)
  end

  @spec has_insufficient_spacing?([String.t()]) :: boolean()
  defp has_insufficient_spacing?(lines) do
    lines
    |> Enum.drop(1)
    |> Enum.filter(&posting_line?/1)
    |> Enum.any?(&line_missing_double_space?/1)
  end

  defp posting_line?(line) do
    Regex.match?(~r/^\s+[^\s;]/, line)
  end

  defp line_missing_double_space?(line) do
    trimmed = line |> String.split(";", parts: 2) |> List.first()

    case Regex.scan(@amount_regex, trimmed, return: :index) do
      [] ->
        false

      matches ->
        [{start, len}] = List.last(matches)
        amount_str = String.slice(trimmed, start, len)

        actual_start =
          case Regex.run(~r/^\s+/, amount_str) do
            [leading_ws] -> start + String.length(leading_ws)
            nil -> start
          end

        prefix = String.slice(trimmed, 0, actual_start)

        adjusted_prefix =
          case Regex.run(~r/([A-Z]{1,5})\s+[-+]?\s*$/, prefix) do
            [full_match, _currency] ->
              String.slice(prefix, 0, String.length(prefix) - String.length(full_match))

            nil ->
              prefix
          end

        Regex.match?(~r/\s$/, adjusted_prefix) and not Regex.match?(~r/\s{2,}$/, adjusted_prefix)
    end
  end

  defp starts_with_directive?(line) do
    starts_with_automated?(line) or starts_with_periodic?(line)
  end

  defp starts_with_automated?(line) do
    String.starts_with?(line, "=")
  end

  defp starts_with_periodic?(line) do
    String.starts_with?(line, "~")
  end

  defp balance_single_missing_amount(postings) do
    currencies = posting_currencies(postings)

    if Enum.count(currencies) > 1 do
      postings
    else
      apply_missing_amount(postings)
    end
  end

  defp posting_currencies(postings) do
    postings
    |> Enum.filter(fn p ->
      !is_nil(p.amount) and p.amount.value != 0 and p.amount.value != 0.0
    end)
    |> Enum.map(fn p -> p.amount.currency end)
    |> Enum.uniq()
  end

  defp apply_missing_amount(postings) do
    total =
      postings
      |> Enum.filter(fn p -> !is_nil(p.amount) end)
      |> Enum.map(fn p -> p.amount.value end)
      |> Enum.sum()

    {currency, currency_position} =
      postings
      |> Enum.find(fn p -> !is_nil(p.amount) end)
      |> then(fn p -> {p.amount.currency, Map.get(p.amount, :currency_position)} end)

    Enum.map(postings, &fill_missing_amount(&1, total, currency, currency_position))
  end

  @spec fill_missing_amount(Core.posting(), float(), String.t() | nil, :leading | :trailing | nil) ::
          Core.posting()
  defp fill_missing_amount(posting, total, currency, currency_position) do
    if is_nil(posting.amount) do
      %{
        posting
        | amount: %{value: -total, currency: currency, currency_position: currency_position}
      }
    else
      posting
    end
  end

  defp validate_single_missing_amount(postings) do
    if length(posting_currencies(postings)) > 1 do
      {:error, :multi_currency_missing_amount}
    else
      :ok
    end
  end

  defp validate_balanced_postings(postings) do
    currency_totals = sum_postings_by_currency(postings)

    if Enum.all?(currency_totals, fn {_currency, total} -> abs(total) < 0.01 end) do
      :ok
    else
      validate_multi_currency(currency_totals)
    end
  end

  defp validate_multi_currency(currency_totals) do
    if map_size(currency_totals) > 1 do
      :ok
    else
      {:error, :unbalanced}
    end
  end

  defp sum_postings_by_currency(postings) do
    Enum.reduce(postings, %{}, fn %{amount: %{value: value, currency: currency}}, acc ->
      Map.update(acc, currency, value, &(&1 + value))
    end)
  end
end
