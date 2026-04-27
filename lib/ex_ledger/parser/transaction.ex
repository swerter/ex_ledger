defmodule ExLedger.Parser.Transaction do
  @moduledoc """
  Transaction parsing and validation.

  Handles parsing individual transactions, balancing postings,
  and validating that transactions are balanced.
  """

  alias ExLedger.Parser.Core
  import ExLedger.Parser.Helpers, only: [to_decimal: 1]

  @amount_regex Core.amount_regex()

  @doc """
  Parses a single transaction from a string.

  Returns `{:ok, transaction}` or `{:error, reason}`.
  """
  @spec parse_transaction(String.t()) :: {:ok, Core.transaction()} | {:error, Core.parse_error()}
  def parse_transaction(input) do
    # Normalize line endings (convert CRLF to LF)
    input = String.replace(input, "\r\n", "\n")

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

  Only balances among regular postings - virtual unbalanced postings are excluded.
  """
  @spec balance_postings(Core.transaction()) :: Core.transaction()
  @spec balance_postings([Core.posting()]) :: [Core.posting()]
  def balance_postings(%{postings: postings} = transaction) do
    balanced_postings = balance_postings(postings)
    %{transaction | postings: balanced_postings}
  end

  def balance_postings(postings) when is_list(postings) do
    # Separate virtual unbalanced postings from others
    # Track indices to preserve order
    indexed_postings = Enum.with_index(postings)

    {virtual_unbalanced_indices, balanceable_with_indices} =
      Enum.split_with(indexed_postings, fn {p, _idx} ->
        Map.get(p, :virtual, false) and not Map.get(p, :must_balance, false)
      end)

    virtual_unbalanced_set =
      MapSet.new(Enum.map(virtual_unbalanced_indices, fn {_, idx} -> idx end))

    balanceable = Enum.map(balanceable_with_indices, fn {p, _} -> p end)

    nil_count = Enum.count(balanceable, fn p -> is_nil(p.amount) end)

    balanced =
      case nil_count do
        1 -> balance_single_missing_amount(balanceable)
        _ -> balanceable
      end

    # Reconstruct postings in original order using indices.
    # `balanced` may contain more postings than `balanceable` when the
    # multi-currency expansion turns one empty posting into several — append
    # any leftover balanced postings after the loop.
    {result, leftover} =
      Enum.map_reduce(postings, balanced, fn posting, remaining_balanced ->
        idx = Enum.find_index(postings, fn p -> p == posting end)

        if MapSet.member?(virtual_unbalanced_set, idx) do
          {posting, remaining_balanced}
        else
          # Take the next balanced posting
          case remaining_balanced do
            [next | rest] -> {next, rest}
            [] -> {posting, []}
          end
        end
      end)

    result ++ leftover
  end

  @doc """
  Validates that a transaction is balanced (all postings sum to zero).

  Virtual postings are handled specially:
  - Virtual unbalanced (parentheses): excluded from balance validation
  - Virtual balanced (brackets): must balance among themselves
  - Regular postings: must balance among themselves
  """
  @spec validate_transaction(Core.transaction()) ::
          :ok | {:error, :multiple_nil_amounts | :multi_currency_missing_amount | :unbalanced}
  def validate_transaction(%{postings: postings} = transaction) do
    kind = Map.get(transaction, :kind, :regular)
    # Separate virtual and regular postings
    {virtual_balanced, _virtual_unbalanced, regular} = split_posting_types(postings)

    # For automated/periodic transactions, skip validation if only virtual unbalanced postings
    skip_validation? =
      kind in [:automated, :periodic] and
        regular == [] and virtual_balanced == []

    if skip_validation? do
      :ok
    else
      # Validate regular postings
      with :ok <- validate_posting_group(regular, kind),
           # Validate virtual balanced postings (if any)
           :ok <- validate_posting_group(virtual_balanced, kind) do
        :ok
      end
    end
  end

  defp split_posting_types(postings) do
    Enum.reduce(postings, {[], [], []}, fn posting, {vb, vu, r} ->
      virtual? = Map.get(posting, :virtual, false)
      must_balance? = Map.get(posting, :must_balance, false)

      cond do
        virtual? and must_balance? -> {[posting | vb], vu, r}
        virtual? and not must_balance? -> {vb, [posting | vu], r}
        true -> {vb, vu, [posting | r]}
      end
    end)
  end

  defp validate_posting_group([], _kind), do: :ok

  defp validate_posting_group(postings, kind) do
    nil_count = Enum.count(postings, fn p -> is_nil(p.amount) end)
    non_virtual_count = Enum.count(postings, fn p -> not Map.get(p, :virtual, false) end)

    cond do
      # For automated/periodic, allow single posting without amount
      kind in [:automated, :periodic] and length(postings) == 1 ->
        :ok

      nil_count > 1 and non_virtual_count > 1 ->
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
    if not Regex.match?(~r/^\d{4}[\/\-\.]\d{1,2}[\/\-\.]\d{1,2}/, first_line) do
      {:error, :missing_date}
    end
  end

  defp check_missing_date(true, _first_line), do: nil

  defp check_missing_payee(false, first_line) do
    if not Regex.match?(
         ~r/^\d{4}[\/\-\.]\d{1,2}[\/\-\.]\d{1,2}(?:=\d{4}[\/\-\.]\d{1,2}[\/\-\.]\d{1,2})?\s+(?:[*!]\s+)?(?:\([^)]+\)\s+)?(.+)/,
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

    # Remove cost syntax (@ or @@) and balance assertion syntax (=) before checking spacing
    # Cost syntax: "10 AAPL @ $150.00" or "10 AAPL @@ $1500.00"
    # Assertion syntax: "0 = 100 CHF" or "100 CHF = 200 CHF"
    line_without_cost =
      trimmed
      |> String.replace(~r/\s+(@@?\s+|=\s*).+$/, "")

    case Regex.scan(@amount_regex, line_without_cost, return: :index) do
      [] ->
        false

      matches ->
        [{start, len}] = List.last(matches)
        amount_str = String.slice(line_without_cost, start, len)

        actual_start =
          case Regex.run(~r/^\s+/, amount_str) do
            [leading_ws] -> start + String.length(leading_ws)
            nil -> start
          end

        prefix = String.slice(line_without_cost, 0, actual_start)

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
      expand_missing_amount_for_currencies(postings)
    else
      apply_missing_amount(postings)
    end
  end

  # When a single posting has no amount and the other postings span multiple
  # currencies, ledger-cli expands the empty posting into one posting per
  # currency so each currency balances to zero independently. This is the
  # standard pattern for opening balances spanning multiple currencies.
  defp expand_missing_amount_for_currencies(postings) do
    case Enum.find_index(postings, fn p -> is_nil(p.amount) end) do
      nil ->
        postings

      nil_index ->
        nil_posting = Enum.at(postings, nil_index)

        currency_totals =
          postings
          |> Enum.filter(fn p -> not is_nil(p.amount) end)
          |> sum_postings_by_currency()

        expansion =
          Enum.map(currency_totals, fn {currency, total} ->
            position = currency_position_for(postings, currency)

            %{
              nil_posting
              | amount: %{
                  value: Decimal.negate(total),
                  currency: currency,
                  currency_position: position
                }
            }
          end)

        {before_postings, [_ | after_postings]} = Enum.split(postings, nil_index)
        before_postings ++ expansion ++ after_postings
    end
  end

  defp currency_position_for(postings, currency) do
    postings
    |> Enum.find(fn p ->
      not is_nil(p.amount) and amount_currency_matches?(p, currency)
    end)
    |> case do
      nil -> nil
      posting -> currency_position_from_posting(posting, currency)
    end
  end

  defp amount_currency_matches?(%{amount: amount} = posting, currency) do
    cost = Map.get(posting, :cost)

    if not is_nil(cost) do
      cost.amount.currency == currency
    else
      amount.currency == currency
    end
  end

  defp currency_position_from_posting(%{amount: amount} = posting, currency) do
    cost = Map.get(posting, :cost)

    if not is_nil(cost) and cost.amount.currency == currency do
      Map.get(cost.amount, :currency_position)
    else
      Map.get(amount, :currency_position)
    end
  end

  defp posting_currencies(postings) do
    postings
    |> Enum.filter(fn p ->
      !is_nil(p.amount) and not decimal_zero?(p.amount.value)
    end)
    |> Enum.map(fn p -> p.amount.currency end)
    |> Enum.uniq()
  end

  defp decimal_zero?(%Decimal{} = value), do: Decimal.eq?(value, Decimal.new(0))
  defp decimal_zero?(value) when is_number(value), do: value == 0

  defp apply_missing_amount(postings) do
    # Calculate total using effective values (considering cost)
    total =
      postings
      |> Enum.filter(fn p -> !is_nil(p.amount) end)
      |> Enum.map(&posting_effective_value/1)
      |> Enum.map(&to_decimal/1)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    # Find the cost currency if any posting has a cost
    {currency, currency_position} = find_balance_currency(postings)

    Enum.map(postings, &fill_missing_amount(&1, total, currency, currency_position))
  end

  # Calculate the effective value of a posting for balance purposes
  # If posting has cost, use the cost value; otherwise use the amount
  defp posting_effective_value(%{amount: amount} = posting) do
    cost = Map.get(posting, :cost)

    if not is_nil(cost) do
      case cost.type do
        :per_unit -> Decimal.mult(to_decimal(amount.value), to_decimal(cost.amount.value))
        :total -> to_decimal(cost.amount.value)
      end
    else
      amount.value
    end
  end

  # Find the currency to use for balancing
  # If any posting has a cost, use the cost currency
  defp find_balance_currency(postings) do
    posting_with_cost = Enum.find(postings, fn p -> not is_nil(Map.get(p, :cost)) end)

    if posting_with_cost do
      cost = posting_with_cost.cost
      {cost.amount.currency, Map.get(cost.amount, :currency_position)}
    else
      posting = Enum.find(postings, fn p -> not is_nil(p.amount) end)

      if posting do
        {posting.amount.currency, Map.get(posting.amount, :currency_position)}
      else
        {nil, nil}
      end
    end
  end

  @spec fill_missing_amount(
          Core.posting(),
          Decimal.t(),
          String.t() | nil,
          :leading | :trailing | nil
        ) ::
          Core.posting()
  defp fill_missing_amount(posting, total, currency, currency_position) do
    if is_nil(posting.amount) do
      %{
        posting
        | amount: %{
            value: Decimal.negate(total),
            currency: currency,
            currency_position: currency_position
          }
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
    zero = Decimal.new(0)

    if Enum.all?(currency_totals, fn {_currency, total} -> Decimal.eq?(total, zero) end) do
      :ok
    else
      validate_multi_currency(currency_totals)
    end
  end

  defp validate_multi_currency(currency_totals) do
    # Multi-currency transactions: ledger-cli allows different currencies
    # to have non-zero totals - it tracks them separately.
    # Only single-currency transactions must balance to zero.
    if map_size(currency_totals) > 1 do
      :ok
    else
      {:error, :unbalanced}
    end
  end

  defp sum_postings_by_currency(postings) do
    Enum.reduce(postings, %{}, fn posting, acc ->
      {currency, value} = posting_balance_contribution(posting)
      value = to_decimal(value)
      Map.update(acc, currency, value, &Decimal.add(&1, value))
    end)
  end

  # Get the currency and value a posting contributes for balance calculation
  defp posting_balance_contribution(%{amount: amount} = posting) do
    cost = Map.get(posting, :cost)

    if not is_nil(cost) do
      effective_value =
        case cost.type do
          :per_unit -> Decimal.mult(to_decimal(amount.value), to_decimal(cost.amount.value))
          :total -> to_decimal(cost.amount.value)
        end

      {cost.amount.currency, effective_value}
    else
      {amount.currency, amount.value}
    end
  end
end
