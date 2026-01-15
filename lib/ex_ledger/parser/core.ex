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
          comments: [String.t()]
        }

  @type transaction :: %{
          kind: :regular | :automated | :periodic,
          date: Date.t() | nil,
          aux_date: Date.t() | nil,
          state: :cleared | :pending | :uncleared,
          code: String.t(),
          payee: String.t() | nil,
          comment: String.t() | nil,
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

  # Account name
  account_name =
    utf8_string([not: ?\n, not: ?\s], min: 1)
    |> repeat(ascii_char([?\s]) |> utf8_string([not: ?\n, not: ?\s], min: 1))
    |> reduce({:join_account_parts, []})
    |> unwrap_and_tag(:account)

  # Indentation
  indentation =
    choice([
      ascii_string([?\t], min: 1),
      ascii_string([?\s], min: 1)
    ])

  # Inline comment
  inline_comment =
    ignore(optional_whitespace)
    |> ignore(ascii_string([?;], min: 1))
    |> ignore(optional_whitespace)
    |> utf8_string([not: ?\n], min: 0)
    |> optional()

  posting_with_optional_amount =
    ignore(indentation)
    |> concat(account_name)
    |> optional(
      ignore(ascii_string([?\s, ?\t], min: 2))
      |> concat(amount_value |> unwrap_and_tag(:amount))
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
      ascii_char([?A..?Z])
      |> utf8_string([?a..?z, ?A..?Z, ?0..?9, ?_], min: 0)
      |> reduce({:join_metadata_key, []})
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

  # Transaction parsers
  defparsec(
    :transaction_parser,
    transaction_header
    |> times(posting, min: 2)
    |> reduce({:build_transaction, []})
  )

  defparsec(
    :automated_transaction_parser,
    automated_header
    |> times(posting, min: 1)
    |> reduce({:build_transaction, []})
  )

  defparsec(
    :periodic_transaction_parser,
    periodic_header
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

  metadata_key =
    ascii_char([?A..?Z])
    |> utf8_string([?a..?z, ?A..?Z, ?0..?9, ?_], min: 0)
    |> reduce({:join_metadata_key, []})

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
  defp to_posting([{:account, account}]) do
    %{account: account, amount: nil, metadata: %{}, tags: [], comments: []}
  end

  defp to_posting([{:account, account}, {:amount, amount}]) do
    %{account: account, amount: amount, metadata: %{}, tags: [], comments: []}
  end

  @spec to_posting_simple(keyword()) :: map()
  defp to_posting_simple(parts) do
    account = Keyword.get(parts, :account)
    amount = Keyword.get(parts, :amount)
    %{account: account, amount: amount}
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

    {metadata, tags, comments} =
      Enum.reduce(notes, {%{}, [], []}, fn
        {:metadata_kv, key, value}, {meta, tags, comments} ->
          {Map.put(meta, key, value), tags, comments}

        {:tag, tag}, {meta, tags, comments} ->
          {meta, [tag | tags], comments}

        {:note_comment, comment}, {meta, tags, comments} ->
          {meta, tags, [comment | comments]}

        _, acc ->
          acc
      end)

    tags = Enum.reverse(tags)
    comments = Enum.reverse(comments)

    %{posting | metadata: metadata, tags: tags, comments: comments}
  end

  @spec build_transaction(list()) :: transaction()
  defp build_transaction(parts) do
    transaction =
      parts
      |> Enum.reduce(
        %{
          kind: :regular,
          date: nil,
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: nil,
          comment: nil,
          predicate: nil,
          period: nil,
          postings: []
        },
        fn
          {:date, date}, acc -> %{acc | date: date}
          {:aux_date, aux_date}, acc -> %{acc | aux_date: aux_date}
          {:state, state}, acc -> %{acc | state: state}
          {:code, code}, acc -> %{acc | code: code}
          {:payee, payee}, acc -> %{acc | payee: payee}
          {:comment, comment}, acc -> %{acc | comment: comment}
          {:predicate, predicate}, acc -> %{acc | predicate: predicate}
          {:period, period}, acc -> %{acc | period: period}
          posting, acc when is_map(posting) -> Map.update!(acc, :postings, &[posting | &1])
          _, acc -> acc
        end
      )
      |> Map.update!(:postings, &Enum.reverse/1)

    kind =
      cond do
        transaction.predicate != nil -> :automated
        transaction.period != nil -> :periodic
        true -> :regular
      end

    %{transaction | kind: kind}
  end
end
