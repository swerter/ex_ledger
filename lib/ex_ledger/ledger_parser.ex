defmodule ExLedger.LedgerParser do
  @moduledoc """
  Parser for ledger-cli format files using NimbleParsec.

  Parses transactions in the format:

      YYYY/MM/DD[=YYYY/MM/DD] [*|!] [(CODE)] PAYEE  [; COMMENT]
          [; NOTES/METADATA/TAGS]
          ACCOUNT  AMOUNT
          ACCOUNT  [AMOUNT]

  Automated and periodic transactions are also supported:

      = EXPR
          ACCOUNT  AMOUNT

      ~ PERIOD
          ACCOUNT  AMOUNT

  Where:
  - Notes can be comments, key-value metadata (Key: Value), or tags (:TagName:)
  - At least 2 spaces required between account name and amount
  - Account names can contain single spaces
  - At least 2 postings required per transaction
  """

  import NimbleParsec

  alias ExLedger.EntryFormatter
  alias ExLedger.ParseContext

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
  @type time_entry :: %{
          account: String.t(),
          start: NaiveDateTime.t(),
          stop: NaiveDateTime.t(),
          payee: String.t() | nil,
          cleared: boolean(),
          duration_seconds: non_neg_integer()
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
  # (allows 1 or 2 digits for month and day, and both / and - separators)
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

  # Negative sign indicator (allowed before or after currency)
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

  # Amount: optional negative sign, currency, digits with optional decimal
  # Decimal part can have any number of digits (e.g., .5, .50, .12345)
  # We capture decimal part as a string to preserve leading zeros
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

  # Bare number without currency (e.g., just "0")
  # This is valid ledger syntax and should default to no currency
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

  # Account name - everything before at least 2 spaces and amount (or end of line)
  # Account names can contain single spaces but not multiple consecutive spaces
  account_name =
    utf8_string([not: ?\n, not: ?\s], min: 1)
    |> repeat(ascii_char([?\s]) |> utf8_string([not: ?\n, not: ?\s], min: 1))
    |> reduce({:join_account_parts, []})
    |> unwrap_and_tag(:account)

  # Indentation: at least 1 space OR at least 1 tab
  indentation =
    choice([
      ascii_string([?\t], min: 1),
      ascii_string([?\s], min: 1)
    ])

  # Inline comment - comment at end of posting line
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

  # Note line - starts with one or more semicolons, can be comment/metadata/tag
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
      # Metadata: Key: Value (key must start with capital letter)
      ascii_char([?A..?Z])
      |> utf8_string([?a..?z, ?A..?Z, ?0..?9, ?_], min: 0)
      |> reduce({:join_metadata_key, []})
      |> ignore(string(":"))
      |> ignore(ascii_string([?\s], min: 0))
      |> utf8_string([not: ?\n], min: 0)
      |> reduce({:to_metadata, []}),
      # Comment: everything else
      utf8_string([not: ?\n], min: 0)
      |> unwrap_and_tag(:note_comment)
    ])
    |> ignore(optional(string("\n")))

  # Posting (with optional preceding notes)
  posting =
    times(note_line, min: 0)
    |> concat(posting_with_optional_amount)
    |> reduce({:attach_notes_to_posting, []})

  # Complete transaction
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

  # Note parser for individual notes
  note_tag =
    ignore(ascii_string([?;], min: 1))
    |> ignore(optional_whitespace)
    |> ignore(string(":"))
    |> utf8_string([not: ?:], min: 1)
    |> ignore(string(":"))
    |> reduce({:to_tag, []})

  # Metadata key - must start with capital letter, followed by alphanumeric (no spaces)
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
    # Don't default to "$" - return nil when no currency is specified
    # This allows proper detection of bare-number amounts
    currency =
      parts
      |> Enum.reverse()
      |> Enum.find_value(fn
        {:currency, curr} -> curr
        _ -> nil
      end)

    integer_part = Keyword.get(parts, :integer_part, 0)

    # Handle decimal part: convert to fractional value based on number of digits
    # We use the string representation to preserve leading zeros (e.g., "01", "50", "5")
    decimal_value =
      case Keyword.get(parts, :decimal_string) do
        nil ->
          0.0

        decimal_string ->
          # The number of digits determines the divisor
          num_digits = String.length(decimal_string)
          # Parse the string as an integer
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
      # Convert space char codes to strings
      part when is_integer(part) -> <<part::utf8>>
      part -> to_string(part)
    end)
    |> String.trim()
  end

  @spec join_metadata_key([integer() | String.t()]) :: String.t()
  defp join_metadata_key([first_char | rest]) when is_integer(first_char) do
    <<first_char::utf8>> <> to_string(rest)
  end

  defp join_metadata_key([first_char]) when is_integer(first_char) do
    <<first_char::utf8>>
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

    # If value starts with lowercase, it's likely a comment, not metadata
    # Metadata values should be proper nouns or capitalized (e.g., "Coffee", "Downtown Boston")
    # Comments often start with lowercase (e.g., "this is a comment")
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

  # Public API

  @doc """
  Parses a single transaction from a string.

  Returns `{:ok, transaction}` or `{:error, reason}`.
  """
  @spec parse_transaction(String.t()) :: {:ok, transaction()} | {:error, parse_error()}
  def parse_transaction(input) do
    # Quick pre-checks for better error messages
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

  @spec check_basic_structure(String.t()) :: :ok | {:error, parse_error()}
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
      String.starts_with?(trimmed, "=") -> &automated_transaction_parser/1
      String.starts_with?(trimmed, "~") -> &periodic_transaction_parser/1
      true -> &transaction_parser/1
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
      # Line doesn't start with at least 1 space or tab
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

        # If the amount match includes leading whitespace (from the \s* in the regex),
        # we need to exclude it and count it as part of the spacing instead.
        # This ensures we correctly validate the spacing between account and amount.
        actual_start =
          case Regex.run(~r/^\s+/, amount_str) do
            [leading_ws] ->
              # Amount started with whitespace, adjust start position to after the whitespace
              start + String.length(leading_ws)

            nil ->
              # No leading whitespace in the amount match
              start
          end

        prefix = String.slice(trimmed, 0, actual_start)

        # Check if there's a currency code (1-5 uppercase letters) with optional space and +/- sign
        # before the amount. If so, we need to look before the currency code for the spacing check.
        # Examples: "CHF ", "USD -", "EUR  +", etc.
        # However, we need to be careful not to match account name parts (like "AHV" in "Kreditor:AHV")
        # Only match if it's clearly separated (has whitespace after it)
        adjusted_prefix =
          case Regex.run(~r/([A-Z]{1,5})\s+[-+]?\s*$/, prefix) do
            [full_match, _currency] ->
              # Found currency code followed by space, check spacing before it
              String.slice(prefix, 0, String.length(prefix) - String.length(full_match))

            nil ->
              # No currency code, use prefix as-is
              prefix
          end

        # Check if the adjusted prefix ends with at least 2 spaces
        Regex.match?(~r/\s$/, adjusted_prefix) and not Regex.match?(~r/\s{2,}$/, adjusted_prefix)
    end
  end

  @doc """
  Parses a complete ledger file with multiple transactions.
  """
  @spec parse_ledger(String.t()) ::
          {:ok, [transaction()]} | {:error, {parse_error(), non_neg_integer()}}
  def parse_ledger(""), do: {:ok, []}

  def parse_ledger(input) do
    parse_ledger(input, nil)
  end

  @doc """
  Checks whether the ledger file at the given path parses successfully.
  """
  @spec check_file(String.t()) :: boolean()
  def check_file(path) when is_binary(path) do
    base_dir = Path.dirname(path)
    filename = Path.basename(path)

    with {:ok, contents} <- File.read(path),
         {:ok, _transactions, _accounts} <-
           parse_ledger_with_includes(contents, base_dir, MapSet.new(), filename) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Checks a ledger file and returns `{:ok, :valid}` or `{:error, reason}`.
  """
  @spec check_file_with_error(String.t()) :: {:ok, :valid} | {:error, ledger_error()}
  def check_file_with_error(path) when is_binary(path) do
    base_dir = Path.dirname(path)
    filename = Path.basename(path)

    with {:ok, contents} <- File.read(path),
         {:ok, _transactions, _accounts} <-
           parse_ledger_with_includes(contents, base_dir, MapSet.new(), filename) do
      {:ok, :valid}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _} -> {:error, reason}
      error -> {:error, error}
    end
  end

  @doc """
  Checks whether the given ledger string parses successfully.

  Use `base_dir` to resolve include directives in the content.
  """
  @spec check_string(String.t(), String.t()) :: boolean()
  def check_string(content, base_dir \\ ".") when is_binary(content) and is_binary(base_dir) do
    case parse_ledger_with_includes(content, base_dir, MapSet.new(), nil) do
      {:ok, _transactions, _accounts} -> true
      _ -> false
    end
  end

  @spec parse_ledger(String.t(), String.t() | nil) ::
          {:ok, [transaction()]} | {:error, {parse_error(), non_neg_integer(), String.t() | nil}}
  def parse_ledger("", _source_file), do: {:ok, []}

  def parse_ledger(input, source_file) do
    input
    |> split_transactions_with_line_numbers()
    |> Enum.reduce_while({:ok, []}, fn {transaction_string, line}, {:ok, acc} ->
      case parse_transaction(transaction_string) do
        {:ok, transaction} ->
          {:cont, {:ok, [add_source_info(transaction, source_file, line) | acc]}}

        {:error, reason} ->
          {:halt, {:error, {reason, line, source_file}}}
      end
    end)
    |> case do
      {:ok, transactions} -> {:ok, Enum.reverse(transactions)}
      error -> error
    end
  end

  defp add_source_info(transaction, source_file, line) do
    transaction
    |> Map.put(:source_line, line)
    |> maybe_add_source_file(source_file)
  end

  defp maybe_add_source_file(transaction, nil), do: transaction

  defp maybe_add_source_file(transaction, source_file),
    do: Map.put(transaction, :source_file, source_file)

  @doc """
  Extracts account declarations from a ledger file.

  Returns a map where keys are account names and values are account types.
  Also supports aliases which are added to the map pointing to the main account name.

  ## Examples

      iex> content = "account Assets:Checking  ; type:asset\\n\\n2009/10/29 Panera\\n    Expenses:Food  $4.50\\n    Assets:Checking\\n"
      iex> ExLedger.LedgerParser.extract_account_declarations(content)
      %{"Assets:Checking" => :asset}

  """
  @spec extract_account_declarations(String.t()) :: %{String.t() => atom() | String.t()}
  def extract_account_declarations(input) when is_binary(input) do
    input
    |> String.split("\n")
    |> parse_account_blocks([])
    |> build_account_map()
  end

  @spec parse_account_blocks([String.t()], [account_declaration()]) :: [account_declaration()]
  defp parse_account_blocks([], acc), do: Enum.reverse(acc)

  defp parse_account_blocks([line | rest], acc) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "alias ") ->
        parse_account_blocks(rest, maybe_prepend_account(acc, standalone_alias_entry(trimmed)))

      old_account_format_line?(trimmed, line) ->
        parse_account_blocks(rest, maybe_prepend_account(acc, old_account_entry(line)))

      String.starts_with?(trimmed, "account ") ->
        {account_lines, remaining} = collect_account_block([line | rest])
        account = parse_account_block(account_lines)
        parse_account_blocks(remaining, [account | acc])

      true ->
        parse_account_blocks(rest, acc)
    end
  end

  defp old_account_format_line?(trimmed, line) do
    String.starts_with?(trimmed, "account ") and String.contains?(line, ";")
  end

  defp standalone_alias_entry(trimmed) do
    case parse_standalone_alias(trimmed) do
      {:ok, alias_name, account_name} ->
        %{
          name: alias_name,
          type: :alias,
          aliases: [],
          assertions: [],
          target: account_name
        }

      {:error, _} ->
        nil
    end
  end

  defp old_account_entry(line) do
    case parse_account_declaration(line) do
      {:ok, account} -> Map.merge(account, %{aliases: [], assertions: []})
      {:error, _} -> nil
    end
  end

  defp maybe_prepend_account(acc, nil), do: acc
  defp maybe_prepend_account(acc, entry), do: [entry | acc]

  @spec parse_standalone_alias(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :invalid_alias}
  defp parse_standalone_alias(line) do
    # Parse: alias SHORT = FULL:ACCOUNT:NAME
    case String.split(line, "=", parts: 2) do
      [left, right] ->
        alias_name = left |> String.replace_prefix("alias ", "") |> String.trim()
        account_name = String.trim(right)

        if alias_name != "" and account_name != "" do
          {:ok, alias_name, account_name}
        else
          {:error, :invalid_alias}
        end

      _ ->
        {:error, :invalid_alias}
    end
  end

  @spec collect_account_block([String.t()]) :: {[String.t()], [String.t()]}
  defp collect_account_block([first_line | rest]) do
    {block_lines, remaining} =
      Enum.split_while(rest, fn line ->
        # Include lines that are indented (start with whitespace) or empty
        trimmed = String.trim(line)
        trimmed == "" or (String.starts_with?(line, " ") or String.starts_with?(line, "\t"))
      end)

    {[first_line | block_lines], remaining}
  end

  @spec parse_account_block([String.t()]) :: account_declaration()
  defp parse_account_block([first_line | rest]) do
    # Parse the account name from first line
    account_name =
      first_line
      |> String.trim_leading("account")
      |> String.trim()

    # Parse indented lines for aliases and assertions
    {aliases, assertions} = Enum.reduce(rest, {[], []}, &parse_account_block_line/2)

    %{
      name: account_name,
      type: :asset,
      aliases: Enum.reverse(aliases),
      assertions: Enum.reverse(assertions)
    }
  end

  defp parse_account_block_line(line, {aliases, assertions}) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {aliases, assertions}

      String.starts_with?(trimmed, "alias ") ->
        alias_name = String.trim_leading(trimmed, "alias") |> String.trim()
        {[alias_name | aliases], assertions}

      String.starts_with?(trimmed, "assert ") ->
        assertion = String.trim_leading(trimmed, "assert") |> String.trim()
        {aliases, [assertion | assertions]}

      true ->
        {aliases, assertions}
    end
  end

  @spec build_account_map([account_declaration()]) :: %{String.t() => atom() | String.t()}
  defp build_account_map(account_declarations) do
    Enum.reduce(account_declarations, %{}, &add_account_to_map/2)
  end

  defp add_account_to_map(%{type: :alias} = account, acc), do: add_standalone_alias(account, acc)
  defp add_account_to_map(account, acc), do: add_account_with_aliases(account, acc)

  defp add_standalone_alias(account, acc) do
    # For standalone alias, map the alias name to the target account name
    Map.put(acc, account.name, account.target)
  end

  defp add_account_with_aliases(account, acc) do
    # Add the main account name -> type mapping
    acc = Map.put(acc, account.name, account.type)

    # Add each alias -> account name mapping
    Enum.reduce(account.aliases, acc, fn alias_name, acc_inner ->
      Map.put(acc_inner, alias_name, account.name)
    end)
  end

  @doc """
  Parses a ledger file with support for include directives and account declarations.

  The `base_dir` parameter specifies the directory to resolve relative include paths from.
  This is typically the directory containing the main ledger file.

  Include directives have the format:
      include path/to/file.ledger

  Account declarations have the format:
      account NAME  ; type:TYPE

  Supports:
  - Relative paths (e.g., "opening_balances.ledger", "ledgers/2024.ledger")
  - Comments after the filename (e.g., "include file.ledger ; comment")
  - Nested includes (files can include other files)
  - Circular include detection
  - Include paths must stay within the base directory
  - Account declarations (e.g., "account Assets:Checking  ; type:asset")

  Returns `{:ok, transactions, accounts}` with all transactions from the main file and all included files,
  and a map of account declarations, or `{:error, reason}` if parsing fails.

  ## Examples

      iex> content = "include opening.ledger\\n\\n2009/10/29 Panera\\n    Expenses:Food  $4.50\\n    Assets:Checking\\n"
      iex> LedgerParser.parse_ledger_with_includes(content, "/path/to/ledger/dir")
      {:ok, [%{date: ~D[2009-01-01], ...}, %{date: ~D[2009-10-29], ...}], %{}}

  """
  @spec parse_ledger_with_includes(String.t(), String.t()) ::
          {:ok, [transaction()], %{String.t() => atom()}} | {:error, ledger_error()}
  @spec parse_ledger_with_includes(String.t(), String.t(), MapSet.t(String.t())) ::
          {:ok, [transaction()], %{String.t() => atom()}} | {:error, ledger_error()}
  @spec parse_ledger_with_includes(String.t(), String.t(), MapSet.t(String.t()), String.t() | nil) ::
          {:ok, [transaction()], %{String.t() => atom()}} | {:error, ledger_error()}
  def parse_ledger_with_includes(input, base_dir, seen_files \\ MapSet.new(), source_file \\ nil)

  def parse_ledger_with_includes("", _base_dir, _seen_files, _source_file), do: {:ok, [], %{}}

  def parse_ledger_with_includes(input, base_dir, seen_files, source_file)
      when is_binary(source_file) or is_nil(source_file) do
    parse_ledger_with_includes_with_import(input, base_dir, seen_files, source_file, nil)
  end

  @spec expand_includes(String.t(), String.t()) :: {:ok, String.t()} | {:error, ledger_error()}
  @spec expand_includes(String.t(), String.t(), MapSet.t(String.t())) ::
          {:ok, String.t()} | {:error, ledger_error()}
  @spec expand_includes(String.t(), String.t(), MapSet.t(String.t()), String.t() | nil) ::
          {:ok, String.t()} | {:error, ledger_error()}
  def expand_includes(input, base_dir, seen_files \\ MapSet.new(), source_file \\ nil)

  def expand_includes("", _base_dir, _seen_files, _source_file), do: {:ok, ""}

  def expand_includes(input, base_dir, seen_files, source_file)
      when is_binary(source_file) or is_nil(source_file) do
    expand_includes_with_import(input, base_dir, seen_files, source_file, nil)
  end

  defp parse_ledger_with_includes_with_import(
         input,
         base_dir,
         seen_files,
         source_file,
         import_chain
       ) do
    # First extract account declarations
    accounts = extract_account_declarations(input)

    context = %ParseContext{
      base_dir: base_dir,
      seen_files: seen_files,
      source_file: source_file,
      import_chain: import_chain,
      accounts: accounts,
      transactions: []
    }

    # Process the file line by line, expanding includes in place while preserving order
    input
    |> String.split("\n")
    |> Enum.with_index(1)
    |> process_lines_and_includes(context)
  end

  @spec process_lines_and_includes([{String.t(), non_neg_integer()}], ParseContext.t()) ::
          {:ok, [transaction()], %{String.t() => atom()}} | {:error, ledger_error()}
  defp process_lines_and_includes([], context) do
    {:ok, context.transactions, context.accounts}
  end

  defp process_lines_and_includes(lines, context) do
    {before_include, include_and_after} = split_at_include(lines)

    if before_include == [] do
      process_include_lines(include_and_after, context)
    else
      process_content_chunk(before_include, include_and_after, context)
    end
  end

  defp expand_includes_with_import(input, base_dir, seen_files, source_file, import_chain) do
    input
    |> String.split("\n")
    |> Enum.with_index(1)
    |> expand_lines_and_includes(base_dir, seen_files, source_file, import_chain, [])
  end

  defp expand_lines_and_includes([], _base_dir, _seen_files, _source_file, _import_chain, acc) do
    {:ok, acc |> Enum.reverse() |> Enum.join("\n")}
  end

  defp expand_lines_and_includes(
         [{line, line_num} | rest],
         base_dir,
         seen_files,
         source_file,
         import_chain,
         acc
       ) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "include ") do
      filename = extract_include_filename(trimmed)

      with {:ok, absolute_path} <- resolve_include_path(base_dir, filename),
           :ok <- check_circular_include(seen_files, absolute_path, filename),
           :ok <- check_file_exists(absolute_path, filename),
           {:ok, included_content} <- read_included_file(absolute_path, filename) do
        included_dir = Path.dirname(absolute_path)
        updated_seen = MapSet.put(seen_files, absolute_path)
        new_import_chain = build_import_chain(source_file, line_num, import_chain)

        with {:ok, expanded} <-
               expand_includes_with_import(
                 included_content,
                 included_dir,
                 updated_seen,
                 filename,
                 new_import_chain
               ) do
          new_acc = if expanded == "", do: acc, else: [expanded | acc]

          expand_lines_and_includes(
            rest,
            base_dir,
            seen_files,
            source_file,
            import_chain,
            new_acc
          )
        end
      end
    else
      expand_lines_and_includes(rest, base_dir, seen_files, source_file, import_chain, [
        line | acc
      ])
    end
  end

  defp process_content_chunk(before_include, include_and_after, context) do
    content = Enum.map_join(before_include, "\n", fn {line, _} -> line end)

    if skip_content_chunk?(content) do
      process_lines_and_includes(include_and_after, context)
    else
      case parse_ledger(content, context.source_file) do
        {:ok, transactions} ->
          updated_context = append_transactions(context, transactions)
          process_lines_and_includes(include_and_after, updated_context)

        {:error, {reason, line, error_source_file}} ->
          format_parse_error(reason, line, error_source_file, context.import_chain)
      end
    end
  end

  defp process_include_lines([], context) do
    {:ok, context.transactions, context.accounts}
  end

  defp process_include_lines([{include_line, line_num} | rest] = include_and_after, context) do
    trimmed = String.trim(include_line)

    if String.starts_with?(trimmed, "include ") do
      process_include_directive(trimmed, line_num, rest, context)
    else
      process_lines_and_includes(include_and_after, context)
    end
  end

  defp only_comments_and_whitespace?(content) do
    content
    |> String.split("\n")
    |> Enum.all?(fn line ->
      trimmed = String.trim(line)

      trimmed == "" or String.starts_with?(trimmed, ";") or
        String.starts_with?(trimmed, "account ") or
        String.starts_with?(trimmed, "alias ") or
        String.starts_with?(trimmed, "assert ")
    end)
  end

  defp skip_content_chunk?(content) do
    String.trim(content) == "" or only_comments_and_whitespace?(content)
  end

  defp append_transactions(context, transactions) do
    %{context | transactions: context.transactions ++ transactions}
  end

  defp split_at_include(lines) do
    Enum.split_while(lines, fn {line, _line_num} ->
      trimmed = String.trim(line)
      # Keep taking lines until we hit an include directive
      not String.starts_with?(trimmed, "include ")
    end)
  end

  defp format_parse_error(reason, line, error_source_file, import_chain) do
    {:error,
     %{
       reason: reason,
       line: line,
       file: error_source_file,
       import_chain: import_chain
     }}
  end

  defp process_include_directive(trimmed_line, line_num, rest, context) do
    filename = extract_include_filename(trimmed_line)

    with {:ok, absolute_path} <- resolve_include_path(context.base_dir, filename),
         :ok <- check_circular_include(context.seen_files, absolute_path, filename),
         :ok <- check_file_exists(absolute_path, filename),
         {:ok, included_content} <- read_included_file(absolute_path, filename) do
      process_included_content(included_content, absolute_path, filename, line_num, rest, context)
    end
  end

  defp extract_include_filename(trimmed_line) do
    trimmed_line
    |> String.replace_prefix("include ", "")
    |> String.split(";")
    |> List.first()
    |> String.trim()
  end

  defp resolve_include_path(base_dir, filename) do
    base_dir = Path.expand(base_dir)

    if Path.type(filename) == :absolute do
      {:error, {:include_outside_base, filename}}
    else
      absolute_path =
        base_dir
        |> Path.join(filename)
        |> Path.expand()

      # Resolve symlinks to enforce boundary check
      # This prevents symlinks inside base_dir from pointing outside
      real_path = resolve_symlinks(absolute_path)
      real_base = resolve_symlinks(base_dir)

      if path_within_base?(real_path, real_base) do
        # Return original path, not resolved
        {:ok, absolute_path}
      else
        {:error, {:include_outside_base, filename}}
      end
    end
  end

  # Resolve symlinks in a path using Erlang's :file module
  # Falls back to the original path if resolution fails (e.g., file doesn't exist)
  defp resolve_symlinks(path) do
    charlist_path = String.to_charlist(path)

    case :file.read_link_all(charlist_path) do
      {:ok, resolved} -> List.to_string(resolved)
      # Fall back to original if can't resolve
      {:error, _} -> path
    end
  end

  defp path_within_base?(absolute_path, base_dir) do
    absolute_segments = Path.split(absolute_path)
    base_segments = Path.split(base_dir)

    base_segments == Enum.take(absolute_segments, length(base_segments))
  end

  defp check_circular_include(seen_files, absolute_path, filename) do
    if MapSet.member?(seen_files, absolute_path) do
      {:error, {:circular_include, filename}}
    else
      :ok
    end
  end

  defp check_file_exists(absolute_path, filename) do
    if File.exists?(absolute_path) do
      :ok
    else
      {:error, {:include_not_found, filename}}
    end
  end

  defp read_included_file(absolute_path, filename) do
    case File.read(absolute_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:file_read_error, filename, reason}}
    end
  end

  defp process_included_content(
         included_content,
         absolute_path,
         filename,
         line_num,
         rest,
         context
       ) do
    included_dir = Path.dirname(absolute_path)
    updated_seen = MapSet.put(context.seen_files, absolute_path)
    new_import_chain = build_import_chain(context.source_file, line_num, context.import_chain)

    with {:ok, included_transactions, included_accounts} <-
           parse_ledger_with_includes_with_import(
             included_content,
             included_dir,
             updated_seen,
             filename,
             new_import_chain
           ) do
      merged_accounts = Map.merge(context.accounts, included_accounts)

      updated_context =
        context
        |> append_transactions(included_transactions)
        |> Map.put(:accounts, merged_accounts)

      process_lines_and_includes(rest, updated_context)
    end
  end

  defp build_import_chain(nil, _line_num, import_chain), do: import_chain

  defp build_import_chain(source_file, line_num, import_chain) do
    [{source_file, line_num} | import_chain || []]
  end

  defp split_transactions_with_line_numbers(input) do
    input
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], [], nil, false}, &process_line_for_transaction/2)
    |> finalize_transaction_chunks()
  end

  defp process_line_for_transaction({line, index}, acc) do
    {chunks, current_lines, start_line, in_account_block} = acc
    trimmed = String.trim(line)

    case process_special_line(
           trimmed,
           line,
           index,
           chunks,
           current_lines,
           start_line,
           in_account_block
         ) do
      {:handled, result} ->
        result

      :continue ->
        process_standard_line(trimmed, line, index, chunks, current_lines, start_line)
    end
  end

  defp process_special_line(
         trimmed,
         line,
         index,
         chunks,
         current_lines,
         start_line,
         in_account_block
       ) do
    case process_timeclock_line(trimmed, index, chunks, current_lines, start_line) do
      {:handled, result} ->
        {:handled, result}

      :continue ->
        process_account_block_line(
          trimmed,
          line,
          index,
          chunks,
          current_lines,
          start_line,
          in_account_block
        )
    end
  end

  defp process_timeclock_line(trimmed, index, chunks, current_lines, start_line) do
    cond do
      timeclock_line?(trimmed) and current_lines == [] ->
        {:handled, {chunks, [], nil, false}}

      timeclock_line?(trimmed) ->
        chunk = Enum.reverse(current_lines) |> Enum.join("\n")
        {:handled, {[{chunk, start_line || index} | chunks], [], nil, false}}

      true ->
        :continue
    end
  end

  defp process_account_block_line(
         trimmed,
         line,
         index,
         chunks,
         current_lines,
         start_line,
         in_account_block
       ) do
    cond do
      old_account_declaration?(trimmed, line, current_lines) ->
        {:handled, {chunks, [], nil, false}}

      new_account_declaration?(trimmed, current_lines) ->
        {:handled, {chunks, [], nil, true}}

      account_block_continuation?(in_account_block, trimmed, line) ->
        {:handled, {chunks, [], nil, true}}

      in_account_block ->
        {:handled, handle_account_block_exit(line, index, chunks, current_lines, start_line)}

      true ->
        :continue
    end
  end

  defp process_standard_line(trimmed, line, index, chunks, current_lines, start_line) do
    cond do
      trimmed == "" ->
        handle_empty_line(chunks, current_lines, start_line, index)

      skippable_line?(trimmed, current_lines) ->
        {chunks, current_lines, start_line, false}

      true ->
        handle_regular_line(line, index, chunks, current_lines, start_line)
    end
  end

  defp old_account_declaration?(trimmed, line, current_lines) do
    String.starts_with?(trimmed, "account ") and String.contains?(line, ";") and
      current_lines == []
  end

  defp new_account_declaration?(trimmed, current_lines) do
    String.starts_with?(trimmed, "account ") and current_lines == []
  end

  defp account_block_continuation?(in_account_block, trimmed, line) do
    in_account_block and
      (trimmed == "" or String.starts_with?(line, " ") or String.starts_with?(line, "\t"))
  end

  defp handle_account_block_exit(line, index, chunks, current_lines, start_line) do
    start_line = start_line || index
    {chunks, [line | current_lines], start_line, false}
  end

  defp handle_empty_line(chunks, current_lines, start_line, index) do
    if current_lines == [] do
      {chunks, [], nil, false}
    else
      chunk = Enum.reverse(current_lines) |> Enum.join("\n")
      {[{chunk, start_line || index} | chunks], [], nil, false}
    end
  end

  defp starts_with_date?(line) do
    Regex.match?(~r/^\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2}/, line)
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

  defp timeclock_line?(line) do
    String.starts_with?(line, "i ") or String.starts_with?(line, "o ") or
      String.starts_with?(line, "O ")
  end

  defp starts_new_entry?(line) do
    starts_with_date?(line) or starts_with_directive?(String.trim_leading(line))
  end

  defp skippable_line?(trimmed, current_lines) do
    current_lines == [] and
      (String.starts_with?(trimmed, ";") or
         String.starts_with?(trimmed, "include ") or
         String.starts_with?(trimmed, "alias ") or
         String.starts_with?(trimmed, "tag ") or
         String.starts_with?(trimmed, "payee ") or
         String.starts_with?(trimmed, "commodity "))
  end

  defp handle_regular_line(line, index, chunks, current_lines, start_line) do
    # Check if this line starts a new transaction (begins with a date)
    # and we already have lines accumulated (meaning we're in the middle of parsing a transaction)
    if starts_new_entry?(line) and current_lines != [] do
      # Finish the current transaction and start a new one
      chunk = Enum.reverse(current_lines) |> Enum.join("\n")
      {[{chunk, start_line} | chunks], [line], index, false}
    else
      # Continue accumulating lines for the current transaction
      start_line = start_line || index
      {chunks, [line | current_lines], start_line, false}
    end
  end

  defp finalize_transaction_chunks({chunks, [], _start_line, _in_account_block}) do
    Enum.reverse(chunks)
  end

  defp finalize_transaction_chunks({chunks, current_lines, start_line, _in_account_block})
       when current_lines != [] do
    chunk = Enum.reverse(current_lines) |> Enum.join("\n")
    start = start_line || 1
    Enum.reverse([{chunk, start} | chunks])
  end

  @doc """
  Parses an account declaration.

  ## Examples

      iex> ExLedger.LedgerParser.parse_account_declaration("account 6 Sonstiger Aufwand:6700 Übriger Betriebsaufwand  ;; type:expense")
      {:ok, %{name: "6 Sonstiger Aufwand:6700 Übriger Betriebsaufwand", type: :expense}}

  """
  @spec parse_account_declaration(String.t()) ::
          {:ok, account_declaration()}
          | {:error, :invalid_account_declaration | :invalid_account_type}
  def parse_account_declaration(input) when is_binary(input) do
    case account_declaration_parser(input) do
      {:ok, [result], "", _, _, _} ->
        {:ok, result}

      {:ok, _, _rest, _, _, _} ->
        {:error, :invalid_account_declaration}

      {:error, _reason, _rest, _context, _line, _column} ->
        {:error, :invalid_account_declaration}
    end
  end

  @doc """
  Parses a date string in YYYY/MM/DD format using NimbleParsec.
  """
  @spec parse_date(String.t()) :: {:ok, Date.t()} | {:error, :invalid_date_format}
  def parse_date(date_string) when is_binary(date_string) do
    run_parser(
      &date_parser/1,
      date_string,
      fn {:date, date} -> {:ok, date} end,
      :invalid_date_format
    )
  end

  @doc """
  Parses a posting line using NimbleParsec.
  """
  @spec parse_posting(String.t()) :: {:ok, map()} | {:error, :invalid_posting}
  def parse_posting(line) do
    run_parser(&posting_parser/1, line, fn posting -> {:ok, posting} end, :invalid_posting)
  end

  @doc """
  Parses an amount string like $4.50 or -$20.00 using NimbleParsec.
  """
  @spec parse_amount(String.t()) :: {:ok, amount()} | {:error, :invalid_amount}
  def parse_amount(amount_string) when is_binary(amount_string) do
    run_parser(&amount_parser/1, amount_string, &{:ok, &1}, :invalid_amount)
  end

  @doc """
  Parses a note/comment line and determines its type using NimbleParsec.
  """
  @spec parse_note(String.t()) ::
          {:ok, {:tag, String.t()} | {:metadata, String.t(), String.t()} | {:comment, String.t()}}
          | {:error, :invalid_note}
  def parse_note(note_string) when is_binary(note_string) do
    run_parser(&note_parser/1, note_string, &{:ok, &1}, :invalid_note)
  end

  defp run_parser(parser_fun, input, success_fun, error) do
    case parser_fun.(input) do
      {:ok, [result], "", _, _, _} -> success_fun.(result)
      {:ok, _, _rest, _, _, _} -> {:error, error}
      {:error, _reason, _rest, _context, _line, _column} -> {:error, error}
    end
  end

  @doc """
  Balances postings by calculating the missing amount.
  """
  @spec balance_postings(transaction()) :: transaction()
  @spec balance_postings([posting()]) :: [posting()]
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
    |> Enum.filter(fn p -> !is_nil(p.amount) end)
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

  @spec fill_missing_amount(posting(), float(), String.t() | nil, :leading | :trailing | nil) ::
          posting()
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

  @doc """
  Validates that a transaction is balanced (all postings sum to zero).
  """
  @spec validate_transaction(transaction()) ::
          :ok | {:error, :multiple_nil_amounts | :multi_currency_missing_amount | :unbalanced}
  def validate_transaction(%{postings: postings}) do
    nil_count = Enum.count(postings, fn p -> is_nil(p.amount) end)

    cond do
      nil_count > 1 ->
        {:error, :multiple_nil_amounts}

      nil_count == 1 ->
        # Check if this is a multi-currency transaction with a missing amount
        validate_single_missing_amount(postings)

      nil_count == 0 ->
        validate_balanced_postings(postings)

      true ->
        :ok
    end
  end

  defp validate_single_missing_amount(postings) do
    currencies =
      postings
      |> Enum.filter(fn p -> !is_nil(p.amount) end)
      |> Enum.map(fn p -> p.amount.currency end)
      |> Enum.uniq()

    if length(currencies) > 1 do
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
    # Multi-currency transactions: allow if there are multiple currencies
    # (we cannot validate exchange rates without knowing the conversion rate)
    # Only reject if it's a single currency that doesn't balance
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

  @doc """
  Gets all postings for a specific account with running balance.
  """
  @spec get_account_postings([transaction()], String.t()) :: [map()]
  def get_account_postings(transactions, account_name) do
    transactions
    |> regular_transactions()
    |> Enum.flat_map(fn transaction ->
      transaction.postings
      |> Enum.filter(fn posting -> posting.account == account_name end)
      |> Enum.map(fn posting ->
        %{
          date: transaction.date,
          description: transaction.payee,
          account: posting.account,
          amount: posting.amount.value
        }
      end)
    end)
    |> Enum.reduce({[], 0.0}, fn posting, {acc, balance} ->
      new_balance = balance + posting.amount
      posting_with_balance = Map.put(posting, :balance, new_balance)
      {[posting_with_balance | acc], new_balance}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec list_accounts([transaction()], %{String.t() => atom() | String.t()}) :: [String.t()]
  def list_accounts(transactions, account_map \\ %{}) do
    transaction_accounts =
      transactions
      |> all_postings()
      |> Enum.map(& &1.account)

    declared_accounts =
      account_map
      |> Enum.filter(fn {_name, value} -> is_atom(value) end)
      |> Enum.map(fn {name, _type} -> name end)

    uniq_sort(transaction_accounts ++ declared_accounts)
  end

  @spec list_payees([transaction()]) :: [String.t()]
  def list_payees(transactions) do
    transactions
    |> Enum.map(& &1.payee)
    |> Enum.reject(&is_nil/1)
    |> uniq_sort()
  end

  @spec list_commodities([transaction()]) :: [String.t()]
  def list_commodities(transactions) do
    transactions
    |> all_postings()
    |> Enum.map(&posting_currency/1)
    |> Enum.reject(&is_nil/1)
    |> uniq_sort()
  end

  @spec list_tags([transaction()]) :: [String.t()]
  def list_tags(transactions) do
    transactions
    |> all_postings()
    |> Enum.flat_map(& &1.tags)
    |> uniq_sort()
  end

  @spec extract_payee_declarations(String.t()) :: MapSet.t(String.t())
  def extract_payee_declarations(input) when is_binary(input) do
    input
    |> String.split("\n")
    |> Enum.reduce(MapSet.new(), &extract_payee_declaration_line/2)
  end

  defp extract_payee_declaration_line(line, acc) do
    case payee_from_line(String.trim(line)) do
      nil -> acc
      payee -> MapSet.put(acc, payee)
    end
  end

  defp payee_from_line(trimmed) do
    if String.starts_with?(trimmed, "payee ") do
      trimmed
      |> String.trim_leading("payee")
      |> String.trim()
      |> blank_to_nil()
    end
  end

  @spec extract_commodity_declarations(String.t()) :: MapSet.t(String.t())
  def extract_commodity_declarations(input) when is_binary(input) do
    input
    |> String.split("\n")
    |> Enum.reduce(MapSet.new(), &extract_commodity_declaration_line/2)
  end

  defp extract_commodity_declaration_line(line, acc) do
    case commodity_from_line(String.trim(line)) do
      nil -> acc
      commodity -> MapSet.put(acc, commodity)
    end
  end

  defp commodity_from_line(trimmed) do
    if String.starts_with?(trimmed, "commodity ") do
      trimmed
      |> String.trim_leading("commodity")
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> extract_commodity_symbol()
      |> blank_to_nil()
    end
  end

  @spec extract_tag_declarations(String.t()) :: MapSet.t(String.t())
  def extract_tag_declarations(input) when is_binary(input) do
    input
    |> String.split("\n")
    |> Enum.reduce(MapSet.new(), &extract_tag_declaration_line/2)
  end

  defp extract_tag_declaration_line(line, acc) do
    case tag_from_line(String.trim(line)) do
      nil -> acc
      tag -> MapSet.put(acc, tag)
    end
  end

  defp tag_from_line(trimmed) do
    if String.starts_with?(trimmed, "tag ") do
      trimmed
      |> String.trim_leading("tag")
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> blank_to_nil()
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @spec check_accounts([transaction()], %{String.t() => atom() | String.t()}) ::
          :ok | {:error, String.t()}
  def check_accounts(transactions, accounts) do
    declared_set = declared_account_set(accounts)

    transactions
    |> list_accounts(%{})
    |> Enum.find(fn account -> not MapSet.member?(declared_set, account) end)
    |> case do
      nil -> :ok
      account -> {:error, account}
    end
  end

  @spec check_payees([transaction()], MapSet.t(String.t())) :: :ok | {:error, String.t()}
  def check_payees(transactions, declared_payees) do
    transactions
    |> list_payees()
    |> Enum.find(fn payee -> not MapSet.member?(declared_payees, payee) end)
    |> case do
      nil -> :ok
      payee -> {:error, payee}
    end
  end

  @spec check_commodities([transaction()], MapSet.t(String.t())) :: :ok | {:error, String.t()}
  def check_commodities(transactions, declared_commodities) do
    transactions
    |> list_commodities()
    |> Enum.find(fn commodity -> not MapSet.member?(declared_commodities, commodity) end)
    |> case do
      nil -> :ok
      commodity -> {:error, commodity}
    end
  end

  @spec check_tags([transaction()], String.t(), MapSet.t(String.t())) ::
          :ok | {:error, String.t()}
  def check_tags(transactions, contents, declared_tags) do
    used_tags = extract_used_tags(contents, transactions)
    allowed_tags = MapSet.union(declared_tags, builtin_tags())

    used_tags
    |> Enum.find(fn tag -> not MapSet.member?(allowed_tags, tag) end)
    |> case do
      nil -> :ok
      tag -> {:error, tag}
    end
  end

  defp declared_account_set(accounts) do
    accounts
    |> Enum.filter(fn {_name, value} -> is_atom(value) end)
    |> Enum.map(fn {name, _type} -> name end)
    |> MapSet.new()
  end

  defp extract_used_tags(contents, transactions) do
    tags_from_notes = list_tags(transactions)

    tags_from_comments =
      contents
      |> String.split("\n")
      |> Enum.flat_map(&tags_from_line/1)

    MapSet.new(tags_from_notes ++ tags_from_comments)
  end

  defp tags_from_line(line) do
    case String.split(line, ";", parts: 2) do
      [_prefix] ->
        []

      [_prefix, comment] ->
        comment
        |> String.trim()
        |> tags_from_comment()
    end
  end

  defp tags_from_comment(comment) do
    colon_tags =
      Regex.scan(~r/\b([A-Za-z0-9_-]+):/, comment, capture: :all_but_first)
      |> List.flatten()

    wrapped_tags =
      Regex.scan(~r/:([A-Za-z0-9_-]+):/, comment, capture: :all_but_first)
      |> List.flatten()

    (colon_tags ++ wrapped_tags)
    |> Enum.reject(&(&1 == "tags"))
  end

  defp builtin_tags do
    MapSet.new([
      "date",
      "date2",
      "type",
      "t",
      "assert",
      "retain",
      "start",
      "generated-transaction",
      "modified-transaction",
      "generated-posting",
      "cost-posting",
      "conversion-posting",
      "_generated-transaction",
      "_modified-transaction",
      "_generated-posting",
      "_cost-posting",
      "_conversion-posting"
    ])
  end

  defp extract_commodity_symbol(nil), do: ""

  defp extract_commodity_symbol(token) do
    case Regex.run(~r/^([^0-9\s.,]+)/, token) do
      [_, symbol] -> symbol
      _ -> token
    end
  end

  defp uniq_sort(items) do
    items
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec stats([transaction()]) :: map()
  def stats(transactions) do
    transactions = Enum.filter(transactions, &regular_transaction?/1)

    postings =
      Enum.flat_map(transactions, fn transaction ->
        Enum.map(transaction.postings, fn posting ->
          %{date: transaction.date, account: posting.account}
        end)
      end)

    dates = Enum.map(transactions, & &1.date)
    {start_date, end_date} = min_max_dates(dates)
    today = Date.utc_today()

    %{
      time_range: {start_date, end_date},
      unique_accounts: list_accounts(transactions, %{}) |> length(),
      unique_payees: list_payees(transactions) |> length(),
      postings_total: length(postings),
      days_since_last_posting: days_since(end_date, today),
      posts_last_7_days: count_posts_since(postings, today, 7),
      posts_last_30_days: count_posts_since(postings, today, 30),
      posts_this_month: count_posts_this_month(postings, today)
    }
  end

  @spec format_stats(map()) :: String.t()
  def format_stats(stats) do
    {start_date, end_date} = stats.time_range
    time_range = format_time_range(start_date, end_date)
    days_since = format_days_since(stats.days_since_last_posting)

    [
      "Time range of all postings: #{time_range}",
      "Unique accounts: #{stats.unique_accounts}",
      "Unique payees: #{stats.unique_payees}",
      "Postings total: #{stats.postings_total}",
      "Days since last posting: #{days_since}",
      "Posts in the last 7 days: #{stats.posts_last_7_days}",
      "Posts in the last 30 days: #{stats.posts_last_30_days}",
      "Posts this month: #{stats.posts_this_month}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @spec select([transaction()], String.t()) :: {:ok, [String.t()], [map()]} | {:error, atom()}
  def select(transactions, query) when is_binary(query) do
    with {:ok, fields, filters} <- parse_select_query(query) do
      postings =
        Enum.flat_map(transactions, fn transaction ->
          Enum.map(transaction.postings, fn posting ->
            %{
              date: transaction.date,
              payee: transaction.payee,
              account: posting.account,
              amount: posting.amount,
              tags: posting.tags
            }
          end)
        end)

      rows =
        postings
        |> Enum.filter(&matches_filters?(&1, filters))
        |> Enum.map(&select_row(&1, fields))

      {:ok, fields, rows}
    end
  end

  @spec format_select([String.t()], [map()]) :: String.t()
  def format_select(fields, rows) do
    rows
    |> Enum.map_join("\n", &format_select_row(&1, fields))
    |> Kernel.<>("\n")
  end

  @spec build_xact([transaction()], Date.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def build_xact(transactions, date, payee_pattern) do
    with {:ok, regex} <- compile_regex(payee_pattern) do
      transaction =
        transactions
        |> regular_transactions()
        |> Enum.reverse()
        |> Enum.find(fn transaction ->
          transaction.payee != nil and Regex.match?(regex, transaction.payee)
        end)

      case transaction do
        nil -> {:error, :xact_not_found}
        _ -> {:ok, EntryFormatter.format_entry(transaction, date)}
      end
    end
  end

  defp regular_transaction?(transaction) do
    Map.get(transaction, :kind, :regular) == :regular and not is_nil(transaction.date)
  end

  defp regular_transactions(transactions) when is_list(transactions) do
    Enum.filter(transactions, &regular_transaction?/1)
  end

  defp all_postings(transactions) when is_list(transactions) do
    Enum.flat_map(transactions, & &1.postings)
  end

  defp regular_postings(transactions) when is_list(transactions) do
    transactions
    |> regular_transactions()
    |> all_postings()
  end

  @spec parse_timeclock_entries(String.t()) :: [time_entry()]
  def parse_timeclock_entries(input) when is_binary(input) do
    {entries, open} =
      input
      |> String.split("\n")
      |> Enum.reduce({[], []}, fn line, {entries, open} ->
        line
        |> String.trim()
        |> process_timeclock_line(entries, open)
      end)

    warn_unclosed_timeclock_entries(open)

    entries
  end

  defp process_timeclock_line(trimmed, entries, open) do
    cond do
      String.starts_with?(trimmed, "i ") ->
        handle_timeclock_checkin(trimmed, entries, open)

      String.starts_with?(trimmed, "o ") or String.starts_with?(trimmed, "O ") ->
        handle_timeclock_checkout(trimmed, entries, open)

      true ->
        {entries, open}
    end
  end

  defp handle_timeclock_checkin(trimmed, entries, open) do
    case parse_timeclock_checkin(trimmed) do
      {:ok, entry} -> {entries, [entry | open]}
      _ -> {entries, open}
    end
  end

  defp handle_timeclock_checkout(trimmed, entries, open) do
    {new_entries, remaining} = close_timeclock_entries(trimmed, open)
    {entries ++ new_entries, remaining}
  end

  defp warn_unclosed_timeclock_entries(open) do
    if Enum.empty?(open) do
      :ok
    else
      IO.puts(:stderr, "Warning: #{Enum.count(open)} unclosed timeclock check-in(s)")

      Enum.each(open, fn entry ->
        IO.puts(
          :stderr,
          "  - #{entry.account} checked in at #{NaiveDateTime.to_string(entry.start)}"
        )
      end)
    end
  end

  @spec timeclock_report([time_entry()]) :: %{String.t() => float()}
  def timeclock_report(entries) do
    entries
    |> Enum.group_by(& &1.account)
    |> Enum.map(fn {account, account_entries} ->
      total_seconds =
        Enum.reduce(account_entries, 0, fn entry, acc -> acc + entry.duration_seconds end)

      hours = total_seconds / 3600
      {account, hours}
    end)
    |> Map.new()
  end

  @spec format_timeclock_report(%{String.t() => float()}) :: String.t()
  def format_timeclock_report(report) do
    report
    |> Enum.sort_by(fn {account, _hours} -> account end)
    |> Enum.map_join("\n", fn {account, hours} ->
      formatted_hours = :erlang.float_to_binary(hours, decimals: 2)
      String.pad_leading(formatted_hours, 8) <> "  " <> account
    end)
    |> Kernel.<>("\n")
  end

  @spec budget_report([transaction()], Date.t()) :: [map()]
  def budget_report(transactions, date \\ Date.utc_today()) do
    periodic_transactions = Enum.filter(transactions, &(&1.kind == :periodic))
    regular_txns = regular_transactions(transactions)

    budget_totals = build_budget_totals(periodic_transactions)
    actual_totals = build_actual_totals(regular_txns, date)

    budget_accounts = Map.keys(budget_totals)
    actual_accounts = Map.keys(actual_totals)

    (budget_accounts ++ actual_accounts)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn account ->
      account_budget = Map.get(budget_totals, account, %{})
      account_actual = Map.get(actual_totals, account, %{})

      currencies =
        (Map.keys(account_budget) ++ Map.keys(account_actual)) |> Enum.uniq() |> Enum.sort()

      Enum.map(currencies, fn currency ->
        budget_value = Map.get(account_budget, currency, 0.0)
        actual_value = Map.get(account_actual, currency, 0.0)

        %{
          account: account,
          currency: currency,
          actual: actual_value,
          budget: budget_value,
          remaining: budget_value - actual_value
        }
      end)
    end)
  end

  @spec format_budget_report([map()]) :: String.t()
  def format_budget_report(rows) do
    header =
      String.pad_leading("Actual", 14) <>
        String.pad_leading("Budget", 14) <>
        String.pad_leading("Remaining", 14) <> "  Account"

    body =
      Enum.map_join(rows, "\n", fn row ->
        actual = format_amount_for_currency(row.actual, row.currency)
        budget = format_amount_for_currency(row.budget, row.currency)
        remaining = format_amount_for_currency(row.remaining, row.currency)

        String.pad_leading(actual, 14) <>
          String.pad_leading(budget, 14) <>
          String.pad_leading(remaining, 14) <> "  " <> row.account
      end)

    header <> "\n" <> body <> "\n"
  end

  @spec forecast_balance([transaction()], pos_integer()) :: %{String.t() => amount()}
  def forecast_balance(transactions, months \\ 1) do
    current_balances = balance(transactions)
    budget_totals = build_budget_totals(Enum.filter(transactions, &(&1.kind == :periodic)))

    budget_adjustments =
      Enum.reduce(budget_totals, %{}, fn {account, currency_map}, acc ->
        Enum.reduce(currency_map, acc, fn {currency, value}, acc_inner ->
          Map.update(acc_inner, {account, currency}, value * months, &(&1 + value * months))
        end)
      end)

    current_entries =
      current_balances
      |> Enum.map(fn {account, %{value: value, currency: currency}} ->
        {{account, currency}, value}
      end)
      |> Map.new()

    current_entries
    |> Map.merge(budget_adjustments, fn _key, value, adjustment -> value + adjustment end)
    |> Enum.map(fn {{account, currency}, value} ->
      {account, %{value: value, currency: currency}}
    end)
    |> Map.new()
  end

  defp build_budget_totals(periodic_transactions) do
    periodic_transactions
    |> Enum.reduce(%{}, fn transaction, acc ->
      multiplier = period_multiplier(transaction.period)

      case multiplier do
        nil -> acc
        _ -> add_budget_posting_totals(transaction.postings, acc, multiplier)
      end
    end)
  end

  defp add_budget_posting_totals(postings, acc, multiplier) do
    Enum.reduce(postings, acc, fn posting, acc_inner ->
      add_budget_posting_total(posting, acc_inner, multiplier)
    end)
  end

  defp add_budget_posting_total(%{amount: nil}, acc, _multiplier), do: acc

  defp add_budget_posting_total(
         %{amount: %{value: value, currency: currency}, account: account},
         acc,
         multiplier
       ) do
    amount = value * multiplier

    Map.update(acc, account, %{currency => amount}, fn totals ->
      Map.update(totals, currency, amount, &(&1 + amount))
    end)
  end

  defp build_actual_totals(transactions, date) do
    Enum.reduce(transactions, %{}, fn transaction, acc ->
      if same_month?(transaction.date, date) do
        add_posting_totals(transaction.postings, acc)
      else
        acc
      end
    end)
  end

  defp add_posting_totals(postings, acc) do
    Enum.reduce(postings, acc, fn posting, acc_inner ->
      add_posting_total(posting, acc_inner)
    end)
  end

  defp add_posting_total(%{amount: nil}, acc), do: acc

  defp add_posting_total(%{amount: %{value: value, currency: currency}, account: account}, acc) do
    Map.update(acc, account, %{currency => value}, fn totals ->
      Map.update(totals, currency, value, &(&1 + value))
    end)
  end

  defp same_month?(nil, _date), do: false

  defp same_month?(date, other_date) do
    date.year == other_date.year and date.month == other_date.month
  end

  defp period_multiplier(nil), do: nil

  defp period_multiplier(period) do
    normalized = String.downcase(period)

    cond do
      String.contains?(normalized, "daily") -> 365.0 / 12.0
      String.contains?(normalized, "weekly") -> weekly_multiplier(normalized)
      String.contains?(normalized, "monthly") -> monthly_multiplier(normalized)
      String.contains?(normalized, "quarter") -> 1.0 / 3.0
      String.contains?(normalized, "year") -> 1.0 / 12.0
      true -> nil
    end
  end

  defp weekly_multiplier(normalized) do
    if String.contains?(normalized, "bi") do
      26.0 / 12.0
    else
      52.0 / 12.0
    end
  end

  defp monthly_multiplier(normalized) do
    if String.contains?(normalized, "bi") do
      0.5
    else
      1.0
    end
  end

  defp parse_timeclock_checkin(line) do
    case Regex.run(~r/^i\s+(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})\s+(\d{2}:\d{2}:\d{2})\s+(.+)$/, line) do
      [_, date_string, time_string, rest] ->
        with {:ok, date} <- parse_timeclock_date(date_string),
             {:ok, time} <- parse_timeclock_time(time_string) do
          {account, payee} = split_account_payee(rest)

          {:ok,
           %{
             account: account,
             start: NaiveDateTime.new!(date, time),
             payee: payee
           }}
        else
          _ -> {:error, :invalid_checkin}
        end

      _ ->
        {:error, :invalid_checkin}
    end
  end

  defp close_timeclock_entries(line, open_entries) do
    case Regex.run(~r/^(o|O)\s+(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})\s+(\d{2}:\d{2}:\d{2})$/, line) do
      [_, marker, date_string, time_string] ->
        with {:ok, date} <- parse_timeclock_date(date_string),
             {:ok, time} <- parse_timeclock_time(time_string) do
          stop = NaiveDateTime.new!(date, time)
          cleared = marker == "O"

          entries =
            Enum.map(open_entries, fn entry ->
              duration = max(NaiveDateTime.diff(stop, entry.start, :second), 0)

              %{
                account: entry.account,
                start: entry.start,
                stop: stop,
                payee: entry.payee,
                cleared: cleared,
                duration_seconds: duration
              }
            end)

          {entries, []}
        else
          _ -> {[], open_entries}
        end

      _ ->
        {[], open_entries}
    end
  end

  defp parse_timeclock_date(date_string) do
    date_string
    |> parse_date_string()
  end

  defp parse_timeclock_time(time_string) do
    case Time.from_iso8601(time_string) do
      {:ok, time} -> {:ok, time}
      _ -> {:error, :invalid_time}
    end
  end

  defp parse_date_string(date_string) do
    case String.split(date_string, ~r/[\/\-]/) do
      [year, month, day] ->
        with {year, ""} <- Integer.parse(year),
             {month, ""} <- Integer.parse(month),
             {day, ""} <- Integer.parse(day),
             {:ok, date} <- Date.new(year, month, day) do
          {:ok, date}
        else
          _ -> {:error, :invalid_date}
        end

      _ ->
        {:error, :invalid_date}
    end
  end

  defp split_account_payee(rest) do
    case String.split(rest, ~r/\s{2,}/, parts: 2) do
      [account] -> {String.trim(account), nil}
      [account, payee] -> {String.trim(account), String.trim(payee)}
    end
  end

  defp min_max_dates([]), do: {nil, nil}

  defp min_max_dates(dates) do
    {Enum.min(dates), Enum.max(dates)}
  end

  defp days_since(nil, _today), do: "N/A"
  defp days_since(end_date, today), do: Date.diff(today, end_date)

  defp count_posts_since(postings, today, days) do
    cutoff = Date.add(today, -days)
    Enum.count(postings, fn posting -> Date.compare(posting.date, cutoff) != :lt end)
  end

  defp count_posts_this_month(postings, today) do
    Enum.count(postings, fn posting ->
      posting.date.year == today.year and posting.date.month == today.month
    end)
  end

  defp format_time_range(nil, nil), do: "N/A"

  defp format_time_range(start_date, end_date) do
    start_string = Calendar.strftime(start_date, "%Y-%m-%d")
    end_string = Calendar.strftime(end_date, "%Y-%m-%d")
    "#{start_string} to #{end_string}"
  end

  defp format_days_since(days) when is_integer(days), do: Integer.to_string(days)
  defp format_days_since(value), do: value

  defp select_row(posting, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      Map.put(acc, field, select_value(posting, field))
    end)
  end

  defp select_value(posting, "date"), do: posting.date
  defp select_value(posting, "payee"), do: posting.payee
  defp select_value(posting, "account"), do: posting.account

  defp select_value(posting, "amount") do
    posting_formatted_amount(posting)
  end

  defp select_value(posting, "commodity") do
    posting_currency(posting)
  end

  defp select_value(posting, "quantity") do
    posting_amount_value(posting)
  end

  defp select_value(_posting, _field), do: nil

  defp format_select_row(row, fields) do
    Enum.map_join(fields, "\t", fn field ->
      value = Map.get(row, field)
      format_select_value(value)
    end)
  end

  defp format_select_value(%Date{} = value), do: Calendar.strftime(value, "%Y-%m-%d")
  defp format_select_value(nil), do: ""
  defp format_select_value(value), do: to_string(value)

  defp matches_filters?(posting, filters) do
    Enum.all?(filters, fn {field, regex} ->
      value = select_filter_value(posting, field)
      value != nil and Regex.match?(regex, value)
    end)
  end

  defp select_filter_value(posting, "account"), do: posting.account
  defp select_filter_value(posting, "payee"), do: posting.payee

  defp select_filter_value(posting, "tag") do
    posting.tags
    |> Enum.join(",")
  end

  defp select_filter_value(posting, "commodity") do
    posting_currency(posting)
  end

  defp select_filter_value(_posting, _field), do: nil

  defp posting_formatted_amount(%{amount: %{value: value, currency: currency}}) do
    format_amount_for_currency(value, currency)
  end

  defp posting_formatted_amount(_posting), do: nil

  defp posting_currency(%{amount: %{currency: currency}}), do: currency
  defp posting_currency(_posting), do: nil

  defp posting_amount_value(%{amount: %{value: value}}), do: value
  defp posting_amount_value(_posting), do: nil

  defp parse_select_query(query) do
    query = String.trim(query)

    with [fields_part, where_part] <- split_select_parts(query),
         fields when fields != [] <- parse_select_fields(fields_part),
         {:ok, filters} <- parse_select_filters(where_part) do
      {:ok, fields, filters}
    else
      _ -> {:error, :invalid_select_query}
    end
  end

  defp split_select_parts(query) do
    case Regex.run(~r/^(.+?)\s+from\s+posts(?:\s+where\s+(.+))?$/i, query) do
      [_, fields] -> [fields, nil]
      [_, fields, where] -> [fields, where]
      _ -> :error
    end
  end

  defp parse_select_fields(fields_part) when is_binary(fields_part) do
    fields_part
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_select_filters(nil), do: {:ok, []}

  defp parse_select_filters(where_part) do
    conditions =
      where_part
      |> String.split(~r/\s+and\s+/i)
      |> Enum.map(&String.trim/1)

    Enum.reduce_while(conditions, {:ok, []}, fn condition, {:ok, acc} ->
      case parse_filter(condition) do
        {:ok, filter} -> {:cont, {:ok, [filter | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, filters} -> {:ok, Enum.reverse(filters)}
      error -> error
    end
  end

  defp parse_filter(condition) do
    case Regex.run(~r/^(account|payee|tag|commodity)=~\/(.+)\/$/i, condition) do
      [_, field, regex_source] ->
        field = String.downcase(field)

        case compile_regex(regex_source) do
          {:ok, regex} -> {:ok, {field, regex}}
          {:error, _} -> {:error, :invalid_select_filter}
        end

      _ ->
        {:error, :invalid_select_filter}
    end
  end

  defp compile_regex(source) do
    if String.length(source) > 256 do
      {:error, :invalid_regex}
    else
      case Regex.compile(source) do
        {:ok, regex} -> {:ok, regex}
        {:error, _} -> {:error, :invalid_regex}
      end
    end
  end

  @doc """
  Formats account postings as a register report.
  """
  @spec format_account_register([map()], String.t()) :: String.t()
  def format_account_register(postings, _account_name) do
    result =
      postings
      |> Enum.map_join("\n", fn posting ->
        date_str = ExLedger.format_date(posting.date)
        desc = String.pad_trailing(posting.description || "", 15)
        account = String.pad_trailing(posting.account, 16)
        amount_str = format_register_amount(posting.amount)
        balance_str = format_register_amount(posting.balance)

        "#{date_str} #{desc}#{account}#{amount_str} #{balance_str}"
      end)

    result <> "\n"
  end

  defp format_register_amount(nil), do: String.pad_leading("0.00", 9)

  defp format_register_amount(%{value: value, currency: currency}) do
    value
    |> format_amount_for_currency(currency)
    |> String.pad_leading(9)
  end

  defp format_register_amount(value) when is_integer(value) or is_float(value) do
    ExLedger.format_amount(value)
  end

  @doc """
  Builds a register view of postings with running balances.
  """
  @spec register([transaction()], Regex.t() | nil) :: [map()]
  def register(transactions, account_regex \\ nil) do
    postings = register_postings(transactions)

    filtered =
      if account_regex do
        Enum.filter(postings, fn posting -> Regex.match?(account_regex, posting.account) end)
      else
        postings
      end

    {entries, _balances} =
      Enum.map_reduce(filtered, %{}, fn posting, balances ->
        amount = posting.amount || %{value: 0.0, currency: nil}
        currency = Map.get(amount, :currency)
        key = {posting.account, currency}
        new_balance = Map.get(balances, key, 0.0) + amount.value
        entry = Map.put(posting, :balance, %{value: new_balance, currency: currency})

        {entry, Map.put(balances, key, new_balance)}
      end)

    entries
  end

  @doc """
  Formats transactions into ledger-compatible output.
  """
  @spec format_transactions([transaction()]) :: String.t()
  def format_transactions(transactions) do
    transactions
    |> regular_transactions()
    |> Enum.map_join("\n\n", fn transaction ->
      String.trim_trailing(EntryFormatter.format_entry(transaction))
    end)
    |> Kernel.<>("\n")
  end

  defp register_postings(transactions) do
    transactions
    |> regular_transactions()
    |> Enum.flat_map(fn transaction ->
      Enum.map(transaction.postings, fn posting ->
        %{
          date: transaction.date,
          description: transaction.payee,
          account: posting.account,
          amount: posting.amount
        }
      end)
    end)
  end

  @doc """
  Resolves an account name or alias to the canonical account name.

  If the name is an alias, returns the main account name it points to.
  If the name is already a main account name, returns it unchanged.
  If the name is not found in the account map, returns it unchanged.

  ## Examples

      iex> accounts = %{"Assets:Checking" => :asset, "checking" => "Assets:Checking"}
      iex> ExLedger.LedgerParser.resolve_account_name("checking", accounts)
      "Assets:Checking"

      iex> accounts = %{"Assets:Checking" => :asset, "checking" => "Assets:Checking"}
      iex> ExLedger.LedgerParser.resolve_account_name("Assets:Checking", accounts)
      "Assets:Checking"
  """
  @spec resolve_account_name(String.t(), %{String.t() => atom() | String.t()}) :: String.t()
  def resolve_account_name(account_name, account_map) do
    case Map.get(account_map, account_name) do
      # If the value is a string, it's an alias pointing to another account
      target when is_binary(target) -> target
      # If the value is an atom (account type) or nil, return the original name
      _ -> account_name
    end
  end

  @doc """
  Resolves all account names in transactions from aliases to canonical names.

  ## Examples

      iex> transactions = [%{postings: [%{account: "checking", amount: %{value: -10.0, currency: "$"}}]}]
      iex> accounts = %{"Assets:Checking" => :asset, "checking" => "Assets:Checking"}
      iex> ExLedger.LedgerParser.resolve_transaction_aliases(transactions, accounts)
      [%{postings: [%{account: "Assets:Checking", amount: %{value: -10.0, currency: "$"}}]}]
  """
  @spec resolve_transaction_aliases([transaction()], %{String.t() => atom() | String.t()}) :: [
          transaction()
        ]
  def resolve_transaction_aliases(transactions, account_map) do
    Enum.map(transactions, fn transaction ->
      postings =
        Enum.map(transaction.postings, fn posting ->
          resolved_account = resolve_account_name(posting.account, account_map)
          %{posting | account: resolved_account}
        end)

      %{transaction | postings: postings}
    end)
  end

  @doc """
  Calculates the balance for each account by summing all postings.

  Returns a map where keys are account names and values are amount maps with value and currency.

  ## Examples

      iex> transactions = [
      ...>   %{postings: [
      ...>     %{account: "Assets:Checking", amount: %{value: -4.50, currency: "$"}},
      ...>     %{account: "Expenses:Coffee", amount: %{value: 4.50, currency: "$"}}
      ...>   ]},
      ...>   %{postings: [
      ...>     %{account: "Assets:Checking", amount: %{value: -20.00, currency: "$"}},
      ...>     %{account: "Expenses:Coffee", amount: %{value: 20.00, currency: "$"}}
      ...>   ]}
      ...> ]
      iex> ExLedger.LedgerParser.balance(transactions)
      %{"Assets:Checking" => %{value: -24.50, currency: "$"}, "Expenses:Coffee" => %{value: 24.50, currency: "$"}}
  """
  @spec balance([transaction()] | transaction()) :: %{String.t() => amount()}
  def balance(transaction) when is_map(transaction) do
    balance([transaction])
  end

  def balance(transactions) when is_list(transactions) do
    transactions
    |> regular_postings()
    |> Enum.group_by(fn posting -> posting.account end)
    |> Enum.map(fn {account, postings} ->
      total = postings |> Enum.map(& &1.amount.value) |> Enum.sum()
      currency = hd(postings).amount.currency
      {account, %{value: total, currency: currency}}
    end)
    |> Map.new()
  end

  @doc """
  Formats account balances as a balance report.

  Returns a string with each account and its balance, followed by a separator line
  and the total (which should be 0 for balanced transactions).

  The optional `show_empty` parameter controls whether to show accounts with zero balances.
  Defaults to false (hide zero balances).

  ## Examples

      iex> balances = %{"Assets:Checking" => %{value: -23.00, currency: "$"}, "Expenses:Pacific Bell" => %{value: 23.00, currency: "$"}}
      iex> ExLedger.LedgerParser.format_balance(balances)
      \"             $-23.00  Assets:Checking\\n              $23.00  Expenses:Pacific Bell\\n--------------------\\n                   0\\n\"
  """
  @spec format_balance(%{String.t() => amount()}, boolean()) :: String.t()
  def format_balance(balances, show_empty \\ false) do
    account_summaries = build_account_summaries(balances)
    children_map = build_children_map(Map.keys(account_summaries))
    direct_accounts = Map.keys(balances) |> MapSet.new()

    lines =
      children_map
      |> Map.get(nil, [])
      |> Enum.sort()
      |> Enum.flat_map(fn account ->
        render_account(account, account_summaries, children_map, direct_accounts, 0, show_empty)
      end)

    totals_section = format_totals_section(balances)

    body =
      case lines do
        [] -> ""
        _ -> Enum.join(lines, "\n") <> "\n"
      end

    body <> totals_section
  end

  defp format_totals_section(balances) do
    currency_totals =
      balances
      |> Enum.reduce(%{}, fn {_account, %{value: value, currency: currency}}, acc ->
        Map.update(acc, currency, value, &(&1 + value))
      end)

    separator = String.duplicate("-", 20) <> "\n"

    if map_size(currency_totals) == 1 do
      # Single currency - show formatted total (even when balanced)
      [{currency, total}] = Map.to_list(currency_totals)
      normalized_total = if abs(total) < 0.005, do: 0.0, else: total
      amount_str = format_amount_for_currency(normalized_total, currency)
      separator <> String.pad_leading(amount_str, 20) <> "\n"
    else
      # Multiple currencies - show each currency total
      total_lines =
        currency_totals
        |> Enum.sort_by(fn {currency, _value} -> currency end)
        |> Enum.map_join("\n", fn {currency, value} ->
          amount_str = format_amount_for_currency(value, currency)
          String.pad_leading(amount_str, 20)
        end)

      separator <> total_lines <> "\n"
    end
  end

  defp build_account_summaries(balances) do
    Enum.reduce(balances, %{}, fn {account, %{value: value, currency: currency}}, acc ->
      segments = String.split(account, ":")

      Enum.reduce(1..length(segments), acc, fn idx, acc_inner ->
        prefix = Enum.take(segments, idx) |> Enum.join(":")
        update_account_summary(acc_inner, prefix, currency, value)
      end)
    end)
  end

  defp update_account_summary(accounts, account_name, currency, value) do
    Map.update(accounts, account_name, %{amounts: %{currency => value}}, fn summary ->
      updated_amounts = Map.update(summary.amounts, currency, value, &(&1 + value))
      %{summary | amounts: updated_amounts}
    end)
  end

  defp build_children_map(account_names) do
    Enum.reduce(account_names, %{}, fn account, acc ->
      parent = parent_account(account)
      Map.update(acc, parent, [account], fn children -> [account | children] end)
    end)
  end

  defp parent_account(account) do
    case String.split(account, ":") do
      [_single] ->
        nil

      segments ->
        segments
        |> Enum.slice(0, length(segments) - 1)
        |> Enum.join(":")
    end
  end

  defp render_account(
         account,
         summaries,
         children_map,
         direct_accounts,
         visible_depth,
         show_empty
       ) do
    children =
      Map.get(children_map, account, [])
      |> Enum.sort()

    direct? = MapSet.member?(direct_accounts, account)
    should_show = direct? or length(children) > 1

    # Check if account has non-zero balance
    %{amounts: amounts} = Map.get(summaries, account, %{amounts: %{}})
    has_non_zero_balance = Enum.any?(amounts, fn {_currency, value} -> abs(value) >= 0.01 end)

    # Show account if: (has_non_zero_balance OR show_empty) AND should_show
    should_render = (has_non_zero_balance or show_empty) and should_show

    lines =
      if should_render do
        render_account_lines(account, summaries, visible_depth, show_empty)
      else
        []
      end

    next_visible_depth = if should_show, do: visible_depth + 1, else: visible_depth

    child_lines =
      Enum.flat_map(children, fn child ->
        render_account(
          child,
          summaries,
          children_map,
          direct_accounts,
          next_visible_depth,
          show_empty
        )
      end)

    lines ++ child_lines
  end

  defp render_account_lines(account, summaries, visible_depth, show_empty) do
    %{amounts: amounts} = Map.get(summaries, account, %{amounts: %{}})

    # Filter out zero-value currencies unless show_empty is true
    filtered_amounts =
      if show_empty do
        amounts
      else
        Enum.filter(amounts, fn {_currency, value} -> abs(value) >= 0.01 end) |> Map.new()
      end

    currencies = Enum.sort(Map.keys(filtered_amounts))
    last_index = max(length(currencies) - 1, 0)

    Enum.with_index(currencies)
    |> Enum.map(fn {currency, idx} ->
      value = Map.get(filtered_amounts, currency, 0)
      amount_str = format_amount_for_currency(value, currency)
      padded_amount = String.pad_leading(amount_str, 20)

      if idx == last_index do
        padded_amount <> account_suffix(account, visible_depth)
      else
        padded_amount
      end
    end)
  end

  defp account_suffix(account, visible_depth) do
    indent = String.duplicate("  ", visible_depth)
    name = display_account_name(account, visible_depth)
    "  " <> indent <> name
  end

  defp display_account_name(account, visible_depth) do
    if visible_depth == 0 do
      account
    else
      account
      |> String.split(":")
      |> List.last()
    end
  end

  @doc false
  def format_amount_for_currency(value, currency) do
    sign = if value < 0, do: "-", else: ""
    abs_value = abs(value)
    formatted = :erlang.float_to_binary(abs_value, decimals: 2)

    case currency do
      nil -> sign <> formatted
      "" -> sign <> formatted
      "$" -> "$" <> sign <> formatted
      _ -> "#{currency} #{sign}#{formatted}"
    end
  end

  @doc """
  Calculate balances grouped by time periods.

  Returns a map where keys are account names and values are maps of period labels to balances.

  ## Parameters
  - transactions: List of transactions
  - group_by: Grouping type ("daily", "weekly", "monthly", "quarterly", "yearly", or "none")
  - start_date: Optional start date (defaults to first transaction date)
  - end_date: Optional end date (defaults to last transaction date)
  - account_filter: Optional function to filter accounts (e.g., fn account -> String.starts_with?(account, "Assets") end)

  ## Examples

      iex> transactions = [%{date: ~D[2024-01-15], postings: [%{account: "Assets:Cash", amount: %{value: 100, currency: "$"}}]}]
      iex> ExLedger.LedgerParser.balance_by_period(transactions, "monthly")
      %{"periods" => [%{label: "2024-01", start_date: ~D[2024-01-01], end_date: ~D[2024-01-31]}],
        "balances" => %{"2024-01" => %{"Assets:Cash" => %{value: 100, currency: "$"}}}}
  """
  @spec balance_by_period(list(), String.t(), Date.t() | nil, Date.t() | nil, function() | nil) ::
          %{String.t() => any()}
  def balance_by_period(
        transactions,
        group_by \\ "none",
        start_date \\ nil,
        end_date \\ nil,
        account_filter \\ nil
      )

  def balance_by_period([], _group_by, _start_date, _end_date, _account_filter) do
    %{"periods" => [], "balances" => %{}}
  end

  def balance_by_period(_transactions, "none", _start_date, _end_date, _account_filter) do
    %{"periods" => [], "balances" => %{}}
  end

  def balance_by_period(transactions, group_by, start_date, end_date, account_filter) do
    # Filter and sort transactions once - only regular transactions have dates
    sorted_txns =
      transactions
      |> regular_transactions()
      |> Enum.sort_by(& &1.date, Date)

    # If no regular transactions, return empty result
    if Enum.empty?(sorted_txns),
      do: empty_period_balances(),
      else: do_balance_by_period(sorted_txns, group_by, start_date, end_date, account_filter)
  end

  defp empty_period_balances do
    %{"periods" => [], "balances" => %{}}
  end

  defp do_balance_by_period(sorted_txns, group_by, start_date, end_date, account_filter) do
    dates = Enum.map(sorted_txns, fn txn -> txn.date end)

    min_date = start_date || Enum.min(dates, Date)
    max_date = end_date || Enum.max(dates, Date)

    periods = calculate_periods(min_date, max_date, group_by)

    {_, balances_by_period} =
      Enum.reduce(periods, {sorted_txns, %{}}, fn period, {remaining_txns, acc} ->
        {period_txns, rest} =
          Enum.split_while(remaining_txns, fn txn ->
            Date.compare(txn.date, period.end_date) != :gt
          end)

        period_balances = build_period_balances(group_by, period_txns, acc)
        filtered_balances = maybe_filter_balances(period_balances, account_filter)

        updated_acc =
          acc
          |> Map.put(period.label, filtered_balances)
          |> Map.put(:__previous_balances__, period_balances)

        {rest, updated_acc}
      end)

    final_balances = Map.delete(balances_by_period, :__previous_balances__)

    %{"periods" => periods, "balances" => final_balances}
  end

  defp build_period_balances("yearly", period_txns, _acc), do: balance(period_txns)

  defp build_period_balances(_group_by, period_txns, acc) do
    case get_previous_balances(acc) do
      nil ->
        balance(period_txns)

      prev_balances ->
        new_amounts = balance(period_txns)
        merge_balances(prev_balances, new_amounts)
    end
  end

  defp maybe_filter_balances(period_balances, nil), do: period_balances

  defp maybe_filter_balances(period_balances, account_filter) do
    period_balances
    |> Enum.filter(fn {account, _balance} -> account_filter.(account) end)
    |> Map.new()
  end

  # Helper to get previous balances from accumulator
  defp get_previous_balances(acc) do
    Map.get(acc, :__previous_balances__)
  end

  # Merge two balance maps by adding values for matching accounts
  defp merge_balances(bal1, bal2) do
    Map.merge(bal1, bal2, fn _account, %{value: v1, currency: c}, %{value: v2, currency: _} ->
      %{value: v1 + v2, currency: c}
    end)
  end

  defp calculate_periods(start_date, end_date, group_by) do
    case group_by do
      "daily" -> generate_daily_periods(start_date, end_date)
      "weekly" -> generate_weekly_periods(start_date, end_date)
      "monthly" -> generate_monthly_periods(start_date, end_date)
      "quarterly" -> generate_quarterly_periods(start_date, end_date)
      "yearly" -> generate_yearly_periods(start_date, end_date)
      _ -> []
    end
  end

  defp generate_daily_periods(start_date, end_date) do
    generate_periods_by_interval(start_date, end_date, 1, fn date ->
      Date.to_iso8601(date)
    end)
  end

  defp generate_weekly_periods(start_date, end_date) do
    # Find the start of the week for start_date (Monday = 1)
    week_start = Date.add(start_date, -Date.day_of_week(start_date) + 1)

    generate_periods_by_interval(week_start, end_date, 7, fn date ->
      "Week #{Date.to_iso8601(date)}"
    end)
  end

  defp generate_monthly_periods(start_date, end_date) do
    first_day = Date.beginning_of_month(start_date)
    generate_periods_monthly(first_day, end_date, [])
  end

  defp generate_periods_monthly(current, end_date, acc) do
    if Date.compare(current, end_date) == :gt do
      Enum.reverse(acc)
    else
      period_end = Date.end_of_month(current)
      label = "#{current.year}-#{String.pad_leading(Integer.to_string(current.month), 2, "0")}"
      period = %{label: label, start_date: current, end_date: period_end}
      next_month = Date.add(current, Date.days_in_month(current))
      generate_periods_monthly(next_month, end_date, [period | acc])
    end
  end

  defp generate_quarterly_periods(start_date, end_date) do
    first_day = Date.new!(start_date.year, div(start_date.month - 1, 3) * 3 + 1, 1)
    generate_periods_quarterly(first_day, end_date, [])
  end

  defp generate_periods_quarterly(current, end_date, acc) do
    if Date.compare(current, end_date) == :gt do
      Enum.reverse(acc)
    else
      quarter = div(current.month - 1, 3) + 1
      period_end_month = current.month + 2

      period_end =
        Date.new!(
          current.year,
          period_end_month,
          Date.days_in_month(Date.new!(current.year, period_end_month, 1))
        )

      label = "#{current.year} Q#{quarter}"
      period = %{label: label, start_date: current, end_date: period_end}
      next_quarter = Date.add(period_end, 1)
      generate_periods_quarterly(next_quarter, end_date, [period | acc])
    end
  end

  defp generate_yearly_periods(start_date, end_date) do
    generate_periods_yearly(start_date.year, end_date.year, [])
  end

  defp generate_periods_yearly(current_year, end_year, acc) when current_year > end_year do
    Enum.reverse(acc)
  end

  defp generate_periods_yearly(current_year, end_year, acc) do
    period = %{
      label: Integer.to_string(current_year),
      start_date: Date.new!(current_year, 1, 1),
      end_date: Date.new!(current_year, 12, 31)
    }

    generate_periods_yearly(current_year + 1, end_year, [period | acc])
  end

  defp generate_periods_by_interval(current, end_date, days, label_fn, acc \\ [])

  defp generate_periods_by_interval(current, end_date, days, label_fn, acc) do
    if Date.compare(current, end_date) == :gt do
      Enum.reverse(acc)
    else
      period_end = Date.add(current, days - 1)
      period = %{label: label_fn.(current), start_date: current, end_date: period_end}
      next_period = Date.add(current, days)
      generate_periods_by_interval(next_period, end_date, days, label_fn, [period | acc])
    end
  end
end
