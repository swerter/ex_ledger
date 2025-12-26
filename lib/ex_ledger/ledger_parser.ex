defmodule ExLedger.LedgerParser do
  @moduledoc """
  Parser for ledger-cli format files using NimbleParsec.

  Parses transactions in the format:

      YYYY/MM/DD[=YYYY/MM/DD] [*|!] [(CODE)] PAYEE  [; COMMENT]
          [; NOTES/METADATA/TAGS]
          ACCOUNT  AMOUNT
          ACCOUNT  [AMOUNT]

  Where:
  - Notes can be comments, key-value metadata (Key: Value), or tags (:TagName:)
  - At least 2 spaces required between account name and amount
  - Account names can contain single spaces
  - At least 2 postings required per transaction
  """

  import NimbleParsec

  alias ExLedger.ParseContext

  @type amount :: %{value: float(), currency: String.t()}
  @type posting :: %{
          account: String.t(),
          amount: amount() | nil,
          metadata: %{String.t() => String.t()},
          tags: [String.t()],
          comments: [String.t()]
        }
  @type transaction :: %{
          date: Date.t(),
          aux_date: Date.t() | nil,
          state: :cleared | :pending | :uncleared,
          code: String.t(),
          payee: String.t(),
          comment: String.t() | nil,
          postings: [posting()]
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

  amount_leading_currency =
    optional(sign)
    |> concat(currency)
    |> ignore(optional_whitespace)
    |> optional(sign)
    |> ignore(optional_whitespace)
    |> concat(integer_with_commas)
    |> optional(
      ignore(string("."))
      |> concat(decimal_string |> unwrap_and_tag(:decimal_string))
    )
    |> reduce({:to_amount, []})

  amount_trailing_currency =
    optional(sign)
    |> concat(integer_with_commas)
    |> optional(
      ignore(string("."))
      |> concat(decimal_string |> unwrap_and_tag(:decimal_string))
    )
    |> ignore(optional_whitespace)
    |> concat(currency)
    |> reduce({:to_amount, []})

  amount_value =
    choice([
      amount_leading_currency,
      amount_trailing_currency
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

  # Posting line with amount
  posting_with_amount =
    ignore(indentation)
    |> concat(account_name)
    |> ignore(ascii_string([?\s, ?\t], min: 2))
    |> concat(amount_value |> unwrap_and_tag(:amount))
    |> ignore(inline_comment)
    |> ignore(optional_whitespace)
    |> ignore(optional(string("\n")))
    |> reduce({:to_posting, []})

  # Posting line without amount (auto-balanced)
  posting_without_amount =
    ignore(indentation)
    |> concat(account_name)
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
    |> choice([posting_with_amount, posting_without_amount])
    |> reduce({:attach_notes_to_posting, []})

  # Complete transaction
  defparsec(
    :transaction_parser,
    transaction_header
    |> times(posting, min: 2)
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

  @spec to_amount(keyword()) :: amount()
  defp to_amount(parts) do
    has_negative = Enum.member?(parts, :negative)
    sign = if has_negative, do: -1, else: 1
    currency =
      parts
      |> Enum.reverse()
      |> Enum.find_value("$", fn
        {:currency, curr} -> curr
        _ -> nil
      end)
    integer_part = Keyword.get(parts, :integer_part, 0)

    # Handle decimal part: convert to fractional value based on number of digits
    # We use the string representation to preserve leading zeros (e.g., "01", "50", "5")
    decimal_value = case Keyword.get(parts, :decimal_string) do
      nil -> 0.0
      decimal_string ->
        # The number of digits determines the divisor
        num_digits = String.length(decimal_string)
        # Parse the string as an integer
        decimal_int = String.to_integer(decimal_string)
        divisor = :math.pow(10, num_digits)
        decimal_int / divisor
    end

    value = sign * (integer_part + decimal_value)

    %{value: value, currency: currency}
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
    parts
    |> Enum.reduce(
      %{date: nil, aux_date: nil, state: :uncleared, code: "", payee: nil, comment: nil, postings: []},
      fn
        {:date, date}, acc -> %{acc | date: date}
        {:aux_date, aux_date}, acc -> %{acc | aux_date: aux_date}
        {:state, state}, acc -> %{acc | state: state}
        {:code, code}, acc -> %{acc | code: code}
        {:payee, payee}, acc -> %{acc | payee: payee}
        {:comment, comment}, acc -> %{acc | comment: comment}
        posting, acc when is_map(posting) -> Map.update!(acc, :postings, &[posting | &1])
        _, acc -> acc
      end
    )
    |> Map.update!(:postings, &Enum.reverse/1)
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
      case transaction_parser(input) do
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

    cond do
      # Check for date at start (supports both / and - separators)
      not Regex.match?(~r/^\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2}/, first_line) ->
        {:error, :missing_date}

      # Check for payee (something after date, optional aux date, state, and code)
      not Regex.match?(
        ~r/^\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2}(?:=\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})?\s+(?:[*!]\s+)?(?:\([^)]+\)\s+)?(.+)/,
        first_line
      ) ->
        {:error, :missing_payee}

      # Check indentation BEFORE checking postings count (invalid indentation might look like no postings)
      has_invalid_indentation?(lines) ->
        {:error, :invalid_indentation}

      # Check minimum postings (at least 2 indented lines that aren't just comments)
      count_postings(lines) < 2 ->
        {:error, :insufficient_postings}

      # Check spacing before amounts
      has_insufficient_spacing?(lines) ->
        {:error, :insufficient_spacing}

      true ->
        :ok
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
        [{start, _len}] = List.last(matches)
        prefix = String.slice(trimmed, 0, start)

        # Check if there's a currency code (1-5 uppercase letters) with optional space and +/- sign
        # before the amount. If so, we need to look before the currency code for the spacing check.
        # Examples: "CHF ", "USD -", "EUR  +", etc.
        adjusted_prefix =
          case Regex.run(~r/([A-Z]{1,5})\s*[-+]?\s*$/, prefix) do
            [full_match, _currency] ->
              # Found currency code, check spacing before it (remove the currency and sign)
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

  @spec parse_ledger(String.t(), String.t() | nil) ::
          {:ok, [transaction()]} | {:error, {parse_error(), non_neg_integer(), String.t() | nil}}
  def parse_ledger("", _source_file), do: {:ok, []}

  def parse_ledger(input, source_file) do
    input
    |> split_transactions_with_line_numbers()
    |> Enum.reduce_while({:ok, []}, fn {transaction_string, line}, {:ok, acc} ->
      case parse_transaction(transaction_string) do
        {:ok, transaction} -> {:cont, {:ok, [transaction | acc]}}
        {:error, reason} -> {:halt, {:error, {reason, line, source_file}}}
      end
    end)
    |> case do
      {:ok, transactions} -> {:ok, Enum.reverse(transactions)}
      error -> error
    end
  end

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
        handle_standalone_alias(trimmed, rest, acc)

      old_account_format?(trimmed, line) ->
        handle_old_account_format(line, rest, acc)

      String.starts_with?(trimmed, "account ") ->
        handle_new_account_format([line | rest], acc)

      true ->
        parse_account_blocks(rest, acc)
    end
  end

  defp old_account_format?(trimmed, line) do
    String.starts_with?(trimmed, "account ") and String.contains?(line, ";")
  end

  defp handle_standalone_alias(trimmed, rest, acc) do
    case parse_standalone_alias(trimmed) do
      {:ok, alias_name, account_name} ->
        alias_entry = %{
          name: alias_name,
          type: :alias,
          aliases: [],
          assertions: [],
          target: account_name
        }

        parse_account_blocks(rest, [alias_entry | acc])

      {:error, _} ->
        parse_account_blocks(rest, acc)
    end
  end

  defp handle_old_account_format(line, rest, acc) do
    case parse_account_declaration(line) do
      {:ok, account} ->
        account = Map.merge(account, %{aliases: [], assertions: []})
        parse_account_blocks(rest, [account | acc])

      {:error, _} ->
        parse_account_blocks(rest, acc)
    end
  end

  defp handle_new_account_format(lines, acc) do
    {account_lines, remaining} = collect_account_block(lines)
    account = parse_account_block(account_lines)
    parse_account_blocks(remaining, [account | acc])
  end

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
    {aliases, assertions} =
      rest
      |> Enum.filter(fn line -> String.trim(line) != "" end)
      |> Enum.reduce({[], []}, fn line, {aliases_acc, assertions_acc} ->
        trimmed = String.trim(line)

        cond do
          String.starts_with?(trimmed, "alias ") ->
            alias_name = String.trim_leading(trimmed, "alias") |> String.trim()
            {[alias_name | aliases_acc], assertions_acc}

          String.starts_with?(trimmed, "assert ") ->
            assertion = String.trim_leading(trimmed, "assert") |> String.trim()
            {aliases_acc, [assertion | assertions_acc]}

          true ->
            {aliases_acc, assertions_acc}
        end
      end)

    %{
      name: account_name,
      type: :asset,
      aliases: Enum.reverse(aliases),
      assertions: Enum.reverse(assertions)
    }
  end

  @spec build_account_map([account_declaration()]) :: %{String.t() => atom() | String.t()}
  defp build_account_map(account_declarations) do
    Enum.reduce(account_declarations, %{}, &add_account_to_map/2)
  end

  defp add_account_to_map(account, acc) do
    if account.type == :alias do
      add_standalone_alias(account, acc)
    else
      add_account_with_aliases(account, acc)
    end
  end

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

  defp process_content_chunk(before_include, include_and_after, context) do
    content = Enum.map_join(before_include, "\n", fn {line, _} -> line end)

    if String.trim(content) == "" or only_comments_and_whitespace?(content) do
      process_lines_and_includes(include_and_after, context)
    else
      case parse_ledger(content, context.source_file) do
        {:ok, transactions} ->
          updated_context = %{context | transactions: context.transactions ++ transactions}
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
        String.starts_with?(trimmed, "account ")
    end)
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
    absolute_path = resolve_include_path(context.base_dir, filename)

    with :ok <- check_circular_include(context.seen_files, absolute_path, filename),
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
    base_dir
    |> Path.join(filename)
    |> Path.expand()
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

    result =
      parse_ledger_with_includes_with_import(
        included_content,
        included_dir,
        updated_seen,
        filename,
        new_import_chain
      )

    case result do
      {:ok, included_transactions, included_accounts} ->
        merged_accounts = Map.merge(context.accounts, included_accounts)

        updated_context = %{
          context
          | transactions: context.transactions ++ included_transactions,
            accounts: merged_accounts
        }

        process_lines_and_includes(rest, updated_context)

      error ->
        error
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

    cond do
      old_account_declaration?(trimmed, line, current_lines) ->
        {chunks, [], nil, false}

      new_account_declaration?(trimmed, current_lines) ->
        {chunks, [], nil, true}

      account_block_continuation?(in_account_block, trimmed, line) ->
        {chunks, [], nil, true}

      in_account_block ->
        handle_account_block_exit(line, index, chunks, current_lines, start_line)

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

  defp skippable_line?(trimmed, current_lines) do
    current_lines == [] and
      (String.starts_with?(trimmed, ";") or
         String.starts_with?(trimmed, "include ") or
         String.starts_with?(trimmed, "alias "))
  end

  defp handle_regular_line(line, index, chunks, current_lines, start_line) do
    # Check if this line starts a new transaction (begins with a date)
    # and we already have lines accumulated (meaning we're in the middle of parsing a transaction)
    if starts_with_date?(line) and current_lines != [] do
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

    if nil_count == 1 do
      # Check if this is a multi-currency transaction
      currencies =
        postings
        |> Enum.filter(fn p -> !is_nil(p.amount) end)
        |> Enum.map(fn p -> p.amount.currency end)
        |> Enum.uniq()

      if length(currencies) > 1 do
        # Cannot auto-balance multi-currency transactions
        # Return postings as-is and let validation catch it
        postings
      else
        total =
          postings
          |> Enum.filter(fn p -> !is_nil(p.amount) end)
          |> Enum.map(fn p -> p.amount.value end)
          |> Enum.sum()

        currency =
          postings
          |> Enum.find(fn p -> !is_nil(p.amount) end)
          |> then(fn p -> p.amount.currency end)

        Enum.map(postings, &fill_missing_amount(&1, total, currency))
      end
    else
      postings
    end
  end

  @spec fill_missing_amount(posting(), float(), String.t()) :: posting()
  defp fill_missing_amount(posting, total, currency) do
    if is_nil(posting.amount) do
      %{posting | amount: %{value: -total, currency: currency}}
    else
      posting
    end
  end

  @doc """
  Validates that a transaction is balanced (all postings sum to zero).
  """
  @spec validate_transaction(transaction()) :: :ok | {:error, :multiple_nil_amounts | :multi_currency_missing_amount | :unbalanced}
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

  @doc """
  Formats account postings as a register report.
  """
  @spec format_account_register([map()], String.t()) :: String.t()
  def format_account_register(postings, _account_name) do
    result =
      postings
      |> Enum.map_join("\n", fn posting ->
        date_str = ExLedger.format_date(posting.date)
        desc = String.pad_trailing(posting.description, 15)
        account = String.pad_trailing(posting.account, 16)
        amount_str = ExLedger.format_amount(posting.amount)
        balance_str = ExLedger.format_amount(posting.balance)

        "#{date_str} #{desc}#{account}#{amount_str} #{balance_str}"
      end)

    result <> "\n"
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
    |> Enum.flat_map(fn transaction -> transaction.postings end)
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

  defp render_account(account, summaries, children_map, direct_accounts, visible_depth, show_empty) do
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
        render_account(child, summaries, children_map, direct_accounts, next_visible_depth, show_empty)
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

  defp format_amount_for_currency(value, currency) do
    sign = if value < 0, do: "-", else: ""
    abs_value = abs(value)
    formatted = :erlang.float_to_binary(abs_value, decimals: 2)

    case currency do
      "$" -> "$" <> sign <> formatted
      _ -> "#{currency} #{sign}#{formatted}"
    end
  end
end
