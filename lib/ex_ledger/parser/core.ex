defmodule ExLedger.Parser.Core do
  @moduledoc """
  NimbleParsec definitions and parsing primitives for ledger format.

  Provides the core parsing infrastructure used by other parser modules.
  """

  import NimbleParsec

  @type amount :: %{
          value: float(),
          currency: String.t() | nil,
          currency_position: :leading | :trailing | nil
        }

  @type posting :: %{
          account: String.t(),
          amount: amount() | nil,
          metadata: %{String.t() => String.t()},
          tags: [String.t()],
          comments: [String.t()],
          virtual: boolean(),
          must_balance: boolean(),
          cost: cost() | nil,
          actual_date: Date.t() | nil,
          effective_date: Date.t() | nil
        }

  @type cost :: %{
          type: :per_unit | :total,
          amount: amount()
        }

  @type transaction :: %{
          kind: :regular | :automated | :periodic,
          date: Date.t() | nil,
          aux_date: Date.t() | nil,
          state: :cleared | :pending | :uncleared,
          code: String.t(),
          payee: String.t() | nil,
          comment: String.t() | nil,
          metadata: %{String.t() => String.t() | [String.t()]},
          predicate: String.t() | nil,
          period: String.t() | nil,
          postings: [posting()],
          source_file: String.t() | nil,
          source_line: non_neg_integer() | nil
        }

  @type account_declaration :: %{
          name: String.t(),
          type: :expense | :revenue | :asset | :liability | :equity,
          aliases: [String.t()],
          assertions: [String.t()]
        }

  @type parse_error ::
          :missing_date
          | :missing_payee
          | :missing_predicate
          | :missing_period
          | :invalid_indentation
          | :insufficient_postings
          | :insufficient_spacing
          | :parse_error
          | :unbalanced
          | :multiple_nil_amounts
          | :multi_currency_missing_amount
          | :invalid_account_type
          | {:unexpected_input, String.t()}

  @type parse_error_detail :: %{
          reason: parse_error(),
          line: non_neg_integer(),
          file: String.t() | nil,
          import_chain: [{String.t(), non_neg_integer()}] | nil
        }

  @type ledger_error ::
          {:include_not_found, String.t()}
          | {:circular_include, String.t()}
          | {:include_outside_base, String.t()}
          | parse_error_detail()

  @amount_regex ~r/(?:\$|[A-Z]{1,5})?\s*[-+]?\d+(?:\.\d{1,2})?(?:\s*(?:\$|[A-Z]{1,5}))?/

  @doc """
  Regex pattern for matching amounts in ledger format.
  """
  def amount_regex, do: @amount_regex

  # Basic building blocks
  whitespace = ascii_string([?\s, ?\t], min: 1)
  optional_whitespace = ascii_string([?\s, ?\t], min: 0)

  # Account type keywords
  account_type =
    choice([
      string("expense") |> replace(:expense),
      string("revenue") |> replace(:revenue),
      string("asset") |> replace(:asset),
      string("liability") |> replace(:liability),
      string("equity") |> replace(:equity)
    ])
    |> unwrap_and_tag(:account_type)

  # Account declaration: account NAME  ;; type:TYPE
  account_declaration =
    ignore(string("account"))
    |> ignore(whitespace)
    |> utf8_string([not: ?;, not: ?\n], min: 1)
    |> reduce({:trim_string, []})
    |> unwrap_and_tag(:account_name)
    |> ignore(optional_whitespace)
    |> ignore(string(";"))
    |> ignore(optional(string(";")))
    |> ignore(optional_whitespace)
    |> ignore(string("type:"))
    |> concat(account_type)
    |> reduce({:build_account_declaration, []})

  defparsec(:account_declaration_parser, account_declaration)

  # Date: YYYY/MM/DD, YYYY/M/D, YYYY-MM-DD, or YYYY-M-D
  year = integer(4)
  month = integer(min: 1, max: 2)
  day = integer(min: 1, max: 2)
  date_separator = choice([string("/"), string("-")])

  date_value =
    year
    |> ignore(date_separator)
    |> concat(month)
    |> ignore(date_separator)
    |> concat(day)
    |> reduce({:to_date, []})

  date = date_value |> unwrap_and_tag(:date)

  aux_date =
    ignore(string("="))
    |> concat(date_value |> unwrap_and_tag(:aux_date))

  defparsec(:date_parser, date)

  # Transaction code: (CODE)
  code =
    ignore(string("("))
    |> ascii_string([?a..?z, ?A..?Z, ?0..?9], min: 1)
    |> ignore(string(")"))
    |> unwrap_and_tag(:code)

  # Payee/description - everything up to semicolon or end of line
  payee =
    utf8_string([not: ?;, not: ?\n], min: 1)
    |> reduce({:trim_string, []})
    |> unwrap_and_tag(:payee)

  # Comment after payee on first line
  transaction_comment =
    ignore(string(";"))
    |> ignore(optional_whitespace)
    |> utf8_string([not: ?\n], min: 0)
    |> unwrap_and_tag(:comment)
    |> optional()

  # Transaction state flag
  state_flag =
    choice([
      string("*") |> replace(:cleared),
      string("!") |> replace(:pending)
    ])
    |> unwrap_and_tag(:state)

  # Transaction header line
  transaction_header =
    date
    |> optional(aux_date)
    |> ignore(whitespace)
    |> optional(state_flag |> ignore(whitespace))
    |> optional(code |> ignore(whitespace))
    |> concat(payee)
    |> ignore(optional_whitespace)
    |> optional(transaction_comment)
    |> ignore(string("\n"))

  automated_header =
    ignore(optional_whitespace)
    |> ignore(string("="))
    |> ignore(optional_whitespace)
    |> utf8_string([not: ?\n], min: 1)
    |> reduce({:trim_string, []})
    |> unwrap_and_tag(:predicate)
    |> ignore(string("\n"))

  periodic_header =
    ignore(optional_whitespace)
    |> ignore(string("~"))
    |> ignore(optional_whitespace)
    |> utf8_string([not: ?\n], min: 1)
    |> reduce({:trim_string, []})
    |> unwrap_and_tag(:period)
    |> ignore(string("\n"))

  # Negative sign indicator
  sign = ascii_char([?-]) |> replace(:negative)

  # Currency symbol or code
  currency_symbol = ascii_char([?$]) |> replace("$")
  currency_code = ascii_string([?A..?Z, ?a..?z], min: 1)

  currency =
    choice([
      currency_symbol,
      currency_code
    ])
    |> unwrap_and_tag(:currency)

  # Amount number parts
  decimal_string = ascii_string([?0..?9], min: 1)

  three_digits =
    ascii_char([?0..?9])
    |> concat(ascii_char([?0..?9]))
    |> concat(ascii_char([?0..?9]))
    |> reduce({:chars_to_string, []})

  integer_with_commas =
    ascii_string([?0..?9], min: 1)
    |> repeat(ignore(string(",")) |> concat(three_digits))
    |> reduce({:flatten_integer_parts, []})
    |> unwrap_and_tag(:integer_part)

  amount_number =
    integer_with_commas
    |> optional(
      ignore(string("."))
      |> concat(decimal_string |> unwrap_and_tag(:decimal_string))
    )

  amount_leading_currency =
    optional(sign)
    |> concat(currency)
    |> ignore(optional_whitespace)
    |> optional(sign)
    |> ignore(optional_whitespace)
    |> concat(amount_number)
    |> post_traverse({:tag_currency_position, [:leading]})
    |> reduce({:to_amount, []})

  amount_trailing_currency =
    optional(sign)
    |> concat(amount_number)
    |> ignore(optional_whitespace)
    |> concat(currency)
    |> post_traverse({:tag_currency_position, [:trailing]})
    |> reduce({:to_amount, []})

  amount_bare_number =
    optional(sign)
    |> concat(amount_number)
    |> reduce({:to_amount, []})

  amount_value =
    choice([
      amount_leading_currency,
      amount_trailing_currency,
      amount_bare_number
    ])

  defparsec(:amount_parser, amount_value)

  # Account name - can be regular, virtual (parentheses), or virtual balanced (brackets)
  # Regular account: Assets:Cash
  # Virtual unbalanced: (Budget:Food)
  # Virtual balanced: [Tracking:Receipts]
  regular_account_name =
    utf8_string([not: ?\n, not: ?\s, not: ?(, not: ?), not: ?[, not: ?]], min: 1)
    |> repeat(ascii_char([?\s]) |> utf8_string([not: ?\n, not: ?\s, not: ?(, not: ?), not: ?[, not: ?]], min: 1))
    |> reduce({:join_account_parts, []})

  virtual_unbalanced_account =
    ignore(string("("))
    |> concat(
      utf8_string([not: ?\n, not: ?)], min: 1)
      |> reduce({:trim_string, []})
    )
    |> ignore(string(")"))
    |> post_traverse({:tag_virtual_unbalanced, []})

  virtual_balanced_account =
    ignore(string("["))
    |> concat(
      utf8_string([not: ?\n, not: ?]], min: 1)
      |> reduce({:trim_string, []})
    )
    |> ignore(string("]"))
    |> post_traverse({:tag_virtual_balanced, []})

  account_name =
    choice([
      virtual_unbalanced_account,
      virtual_balanced_account,
      regular_account_name |> unwrap_and_tag(:account)
    ])

  # Indentation
  indentation =
    choice([
      ascii_string([?\t], min: 1),
      ascii_string([?\s], min: 1)
    ])

  metadata_key =
    ascii_char([?A..?Z])
    |> utf8_string([?a..?z, ?A..?Z, ?0..?9, ?_], min: 0)
    |> reduce({:join_metadata_key, []})

  # Inline comment
  inline_comment =
    ignore(optional_whitespace)
    |> ignore(ascii_string([?;], min: 1))
    |> ignore(optional_whitespace)
    |> utf8_string([not: ?\n], min: 0)
    |> optional()

  # Cost/price: @ AMOUNT (per-unit) or @@ AMOUNT (total)
  per_unit_cost =
    ignore(whitespace)
    |> ignore(string("@"))
    |> lookahead_not(string("@"))
    |> ignore(whitespace)
    |> concat(amount_value)
    |> post_traverse({:tag_cost, [:per_unit]})

  total_cost =
    ignore(whitespace)
    |> ignore(string("@@"))
    |> ignore(whitespace)
    |> concat(amount_value)
    |> post_traverse({:tag_cost, [:total]})

  cost_spec = choice([total_cost, per_unit_cost])

  posting_with_optional_amount =
    ignore(indentation)
    |> concat(account_name)
    |> optional(
      ignore(ascii_string([?\s, ?\t], min: 2))
      |> concat(amount_value |> unwrap_and_tag(:amount))
      |> optional(cost_spec)
    )
    |> ignore(inline_comment)
    |> ignore(optional_whitespace)
    |> ignore(optional(string("\n")))
    |> reduce({:to_posting, []})

  # Note line
  note_line =
    ignore(indentation)
    |> ignore(ascii_string([?;], min: 1))
    |> ignore(ascii_string([?\s], min: 0))
    |> choice([
      # Tag: :TagName:
      ignore(string(":"))
      |> utf8_string([not: ?:], min: 1)
      |> ignore(string(":"))
      |> unwrap_and_tag(:tag),
      # Metadata: Key: Value
      metadata_key
      |> ignore(string(":"))
      |> ignore(ascii_string([?\s], min: 0))
      |> utf8_string([not: ?\n], min: 0)
      |> reduce({:to_metadata, []}),
      # Comment
      utf8_string([not: ?\n], min: 0)
      |> unwrap_and_tag(:note_comment)
    ])
    |> ignore(optional(string("\n")))

  # Posting with notes
  posting =
    times(note_line, min: 0)
    |> concat(posting_with_optional_amount)
    |> reduce({:attach_notes_to_posting, []})

  transaction_metadata_line =
    ignore(indentation)
    |> ignore(ascii_string([?;], min: 1))
    |> ignore(ascii_string([?\s], min: 0))
    |> concat(metadata_key)
    |> ignore(string(":"))
    |> ignore(ascii_string([?\s], min: 0))
    |> utf8_string([not: ?\n], min: 0)
    |> reduce({:to_metadata, []})
    |> ignore(optional(string("\n")))

  # Transaction parsers
  defparsec(
    :transaction_parser,
    transaction_header
    |> times(transaction_metadata_line, min: 0)
    |> times(posting, min: 2)
    |> reduce({:build_transaction, []})
  )

  defparsec(
    :automated_transaction_parser,
    automated_header
    |> times(transaction_metadata_line, min: 0)
    |> times(posting, min: 1)
    |> reduce({:build_transaction, []})
  )

  defparsec(
    :periodic_transaction_parser,
    periodic_header
    |> times(transaction_metadata_line, min: 0)
    |> times(posting, min: 1)
    |> reduce({:build_transaction, []})
  )

  # Note parser
  note_tag =
    ignore(ascii_string([?;], min: 1))
    |> ignore(optional_whitespace)
    |> ignore(string(":"))
    |> utf8_string([not: ?:], min: 1)
    |> ignore(string(":"))
    |> reduce({:to_tag, []})

  note_metadata =
    ignore(ascii_string([?;], min: 1))
    |> ignore(optional_whitespace)
    |> concat(metadata_key)
    |> ignore(string(":"))
    |> ignore(optional_whitespace)
    |> utf8_string([not: ?\n], min: 0)
    |> reduce({:to_metadata_tuple, []})

  note_comment_only =
    ignore(ascii_string([?;], min: 1))
    |> ignore(optional_whitespace)
    |> utf8_string([not: ?\n], min: 0)
    |> reduce({:to_comment, []})

  defparsec(
    :note_parser,
    choice([note_tag, note_metadata, note_comment_only])
  )

  # Posting parser
  posting_line =
    ignore(optional_whitespace)
    |> concat(account_name)
    |> optional(
      ignore(ascii_string([?\s], min: 2))
      |> concat(amount_value |> unwrap_and_tag(:amount))
    )
    |> reduce({:to_posting_simple, []})

  defparsec(:posting_parser, posting_line)

  # Helper functions for reducers

  @doc false
  def run_parser(parser_fun, input, success_fun, error) do
    case parser_fun.(input) do
      {:ok, [result], "", _, _, _} -> success_fun.(result)
      {:ok, _, _rest, _, _, _} -> {:error, error}
      {:error, _reason, _rest, _context, _line, _column} -> {:error, error}
    end
  end

  @spec to_date([integer()]) :: Date.t() | {:error, :invalid_date}
  defp to_date([year, month, day]) do
    case Date.new(year, month, day) do
      {:ok, date} -> date
      {:error, _} -> {:error, :invalid_date}
    end
  end

  @spec trim_string([String.t()]) :: String.t()
  defp trim_string([str]) do
    String.trim(str)
  end

  @spec chars_to_string([integer()]) :: String.t()
  defp chars_to_string(chars) do
    chars
    |> List.to_string()
  end

  @spec flatten_integer_parts([String.t()]) :: integer()
  defp flatten_integer_parts([first | rest]) do
    [first | rest]
    |> Enum.join()
    |> String.to_integer()
  end

  defp tag_currency_position(rest, acc, context, _line, _offset, position) do
    {rest, acc ++ [{:currency_position, position}], context}
  end

  defp tag_virtual_unbalanced(rest, [account], context, _line, _offset) do
    {rest, [{:account, account}, {:virtual, true}, {:must_balance, false}], context}
  end

  defp tag_virtual_balanced(rest, [account], context, _line, _offset) do
    {rest, [{:account, account}, {:virtual, true}, {:must_balance, true}], context}
  end

  defp tag_cost(rest, [amount_map], context, _line, _offset, type) do
    cost = %{type: type, amount: amount_map}
    {rest, [{:cost, cost}], context}
  end

  @spec to_amount(keyword()) :: amount()
  defp to_amount(parts) do
    has_negative = Enum.member?(parts, :negative)
    sign = if has_negative, do: -1, else: 1

    currency =
      parts
      |> Enum.reverse()
      |> Enum.find_value(fn
        {:currency, curr} -> curr
        _ -> nil
      end)

    integer_part = Keyword.get(parts, :integer_part, 0)

    decimal_value =
      case Keyword.get(parts, :decimal_string) do
        nil ->
          0.0

        decimal_string ->
          num_digits = String.length(decimal_string)
          decimal_int = String.to_integer(decimal_string)
          divisor = :math.pow(10, num_digits)
          decimal_int / divisor
      end

    value = sign * (integer_part + decimal_value)
    currency_position = Keyword.get(parts, :currency_position)

    %{value: value, currency: currency, currency_position: currency_position}
  end

  @spec join_account_parts([String.t() | integer()]) :: String.t()
  defp join_account_parts(parts) do
    parts
    |> Enum.map_join("", fn
      part when is_integer(part) -> <<part::utf8>>
      part -> to_string(part)
    end)
    |> String.trim()
  end

  @spec join_metadata_key([integer() | String.t()]) :: String.t()
  defp join_metadata_key([first_char | rest]) when is_integer(first_char) do
    <<first_char::utf8>> <> to_string(rest)
  end

  @spec build_account_declaration([{atom(), any()}, ...]) :: %{name: any(), type: any()}
  defp build_account_declaration(parts) do
    name = Keyword.get(parts, :account_name)
    type = Keyword.get(parts, :account_type)
    %{name: name, type: type}
  end

  @spec to_posting(keyword()) :: posting()
  defp to_posting(parts) do
    account = Keyword.get(parts, :account)
    amount = Keyword.get(parts, :amount)
    virtual = Keyword.get(parts, :virtual, false)
    must_balance = Keyword.get(parts, :must_balance, false)
    cost = Keyword.get(parts, :cost)

    %{
      account: account,
      amount: amount,
      metadata: %{},
      tags: [],
      comments: [],
      virtual: virtual,
      must_balance: must_balance,
      cost: cost,
      actual_date: nil,
      effective_date: nil
    }
  end

  @spec to_posting_simple(keyword()) :: map()
  defp to_posting_simple(parts) do
    account = Keyword.get(parts, :account)
    amount = Keyword.get(parts, :amount)
    virtual = Keyword.get(parts, :virtual, false)
    must_balance = Keyword.get(parts, :must_balance, false)

    %{
      account: account,
      amount: amount,
      virtual: virtual,
      must_balance: must_balance
    }
  end

  @spec to_metadata([String.t()]) :: {:metadata_kv, String.t(), String.t()}
  defp to_metadata([key, value]) do
    {:metadata_kv, String.trim(key), String.trim(value)}
  end

  @spec to_metadata_tuple([String.t()]) ::
          {:comment, String.t()} | {:metadata, String.t(), String.t()}
  defp to_metadata_tuple([key, value]) do
    trimmed_value = String.trim(value)

    if trimmed_value != "" and String.first(trimmed_value) =~ ~r/[a-z]/ do
      {:comment, "#{key}: #{value}"}
    else
      {:metadata, String.trim(key), String.trim(value)}
    end
  end

  @spec to_tag([String.t()]) :: {:tag, String.t()}
  defp to_tag([tag]) do
    {:tag, tag}
  end

  @spec to_comment([String.t()]) :: {:comment, String.t()}
  defp to_comment([comment]) do
    {:comment, comment}
  end

  @spec attach_notes_to_posting(list()) :: posting()
  defp attach_notes_to_posting(items) do
    {notes, [posting]} =
      Enum.split_while(items, fn
        %{account: _} -> false
        _ -> true
      end)

    {metadata, tags, comments, actual_date, effective_date} =
      Enum.reduce(notes, {%{}, [], [], nil, nil}, fn
        {:metadata_kv, key, value}, {meta, tags, comments, actual, effective} ->
          updated_meta = update_metadata(meta, key, value)
          {updated_meta, tags, comments, actual, effective}

        {:tag, tag}, {meta, tags, comments, actual, effective} ->
          {meta, [tag | tags], comments, actual, effective}

        {:note_comment, comment}, {meta, tags, comments, actual, effective} ->
          # Check if comment contains date syntax: [DATE], [=DATE], [DATE=DATE]
          case parse_posting_dates(comment) do
            {:ok, new_actual, new_effective} ->
              actual = new_actual || actual
              effective = new_effective || effective
              {meta, tags, [comment | comments], actual, effective}

            :none ->
              {meta, tags, [comment | comments], actual, effective}
          end

        _, acc ->
          acc
      end)

    tags = Enum.reverse(tags)
    comments = Enum.reverse(comments)

    %{
      posting
      | metadata: metadata,
        tags: tags,
        comments: comments,
        actual_date: actual_date,
        effective_date: effective_date
    }
  end

  defp update_metadata(meta, key, value) do
    if key == "Attachment" do
      Map.update(meta, key, [value], fn
        existing when is_list(existing) -> existing ++ [value]
        existing -> [existing, value]
      end)
    else
      Map.put(meta, key, value)
    end
  end

  # Parse posting date syntax from comment: [DATE], [=DATE], [DATE=DATE]
  defp parse_posting_dates(comment) do
    date_regex = ~r/\[(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})?(?:=(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2}))?\]/

    case Regex.run(date_regex, comment) do
      [_, actual_str, effective_str] when actual_str != "" and effective_str != "" ->
        actual_date = parse_date_string(actual_str)
        effective_date = parse_date_string(effective_str)
        {:ok, actual_date, effective_date}

      [_, actual_str] when actual_str != "" ->
        actual_date = parse_date_string(actual_str)
        {:ok, actual_date, nil}

      [_, "", effective_str] when effective_str != "" ->
        effective_date = parse_date_string(effective_str)
        {:ok, nil, effective_date}

      _ ->
        :none
    end
  end

  defp parse_date_string(str) do
    # Parse YYYY/MM/DD or YYYY-MM-DD
    parts =
      str
      |> String.replace("-", "/")
      |> String.split("/")
      |> Enum.map(&String.to_integer/1)

    case parts do
      [year, month, day] ->
        case Date.new(year, month, day) do
          {:ok, date} -> date
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec build_transaction(list()) :: transaction()
  defp build_transaction(parts) do
    {transaction, pending_metadata} =
      Enum.reduce(
        parts,
        {%{
           kind: :regular,
           date: nil,
           aux_date: nil,
           state: :uncleared,
           code: "",
           payee: nil,
           comment: nil,
           metadata: %{},
           predicate: nil,
           period: nil,
           postings: []
         }, []},
        fn
          {:date, date}, {acc, pending} -> {%{acc | date: date}, pending}
          {:aux_date, aux_date}, {acc, pending} -> {%{acc | aux_date: aux_date}, pending}
          {:state, state}, {acc, pending} -> {%{acc | state: state}, pending}
          {:code, code}, {acc, pending} -> {%{acc | code: code}, pending}
          {:payee, payee}, {acc, pending} -> {%{acc | payee: payee}, pending}
          {:comment, comment}, {acc, pending} -> {%{acc | comment: comment}, pending}
          {:metadata_kv, key, value}, {acc, pending} ->
            {
              %{acc | metadata: update_metadata(acc.metadata, key, value)},
              [{key, value} | pending]
            }

          {:predicate, predicate}, {acc, pending} -> {%{acc | predicate: predicate}, pending}
          {:period, period}, {acc, pending} -> {%{acc | period: period}, pending}
          posting, {acc, pending} when is_map(posting) ->
            {Map.update!(acc, :postings, &[posting | &1]), pending}

          _, acc ->
            acc
        end
      )

    pending_metadata = Enum.reverse(pending_metadata)

    postings =
      transaction.postings
      |> Enum.reverse()
      |> apply_pending_metadata(pending_metadata)

    kind =
      cond do
        transaction.predicate != nil -> :automated
        transaction.period != nil -> :periodic
        true -> :regular
      end

    %{transaction | kind: kind, postings: postings}
  end

  defp apply_pending_metadata(postings, []), do: postings

  defp apply_pending_metadata([first | rest], pending_metadata) do
    updated_first =
      Enum.reduce(pending_metadata, first, fn {key, value}, posting ->
        %{posting | metadata: update_metadata(posting.metadata, key, value)}
      end)

    [updated_first | rest]
  end

  defp apply_pending_metadata([], _pending_metadata), do: []
end
