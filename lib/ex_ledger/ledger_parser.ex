defmodule ExLedger.LedgerParser do
  @moduledoc """
  Parser for ledger-cli format files using NimbleParsec.

  Parses transactions in the format:

      YYYY/MM/DD [(CODE)] PAYEE  [; COMMENT]
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
          code: String.t(),
          payee: String.t(),
          comment: String.t() | nil,
          postings: [posting()]
        }
  @type account_declaration :: %{
          name: String.t(),
          type: :expense | :revenue | :asset | :liability | :equity
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
          | :invalid_account_type
          | {:unexpected_input, String.t()}

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

  # Date: YYYY/MM/DD
  year = integer(4)
  month = integer(2)
  day = integer(2)

  date =
    year
    |> ignore(string("/"))
    |> concat(month)
    |> ignore(string("/"))
    |> concat(day)
    |> reduce({:to_date, []})
    |> unwrap_and_tag(:date)

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

  # Transaction header line
  transaction_header =
    date
    |> ignore(whitespace)
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
  amount_value =
    optional(sign)
    |> concat(currency)
    |> ignore(optional_whitespace)
    |> optional(sign)
    |> ignore(optional_whitespace)
    |> concat(integer(min: 1) |> unwrap_and_tag(:dollars))
    |> optional(
      ignore(string("."))
      |> integer(2)
      |> unwrap_and_tag(:cents)
    )
    |> reduce({:to_amount, []})

  defparsec(:amount_parser, amount_value)

  # Account name - everything before at least 2 spaces and amount (or end of line)
  # Account names can contain single spaces but not multiple consecutive spaces
  account_name =
    utf8_string([not: ?\n, not: ?\s], min: 1)
    |> repeat(ascii_char([?\s]) |> utf8_string([not: ?\n, not: ?\s], min: 1))
    |> reduce({:join_account_parts, []})
    |> unwrap_and_tag(:account)

  # Indentation: at least 2 spaces OR at least 1 tab
  indentation =
    choice([
      ascii_string([?\t], min: 1),
      ascii_string([?\s], min: 2)
    ])

  # Posting line with amount
  posting_with_amount =
    ignore(indentation)
    |> concat(account_name)
    |> ignore(ascii_string([?\s, ?\t], min: 2))
    |> concat(amount_value |> unwrap_and_tag(:amount))
    |> ignore(optional_whitespace)
    |> ignore(optional(string("\n")))
    |> reduce({:to_posting, []})

  # Posting line without amount (auto-balanced)
  posting_without_amount =
    ignore(indentation)
    |> concat(account_name)
    |> ignore(optional_whitespace)
    |> ignore(optional(string("\n")))
    |> reduce({:to_posting, []})

  # Note line - starts with semicolon, can be comment/metadata/tag
  note_line =
    ignore(indentation)
    |> ignore(string(";"))
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
    ignore(string(";"))
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
    ignore(string(";"))
    |> ignore(optional_whitespace)
    |> concat(metadata_key)
    |> ignore(string(":"))
    |> ignore(optional_whitespace)
    |> utf8_string([not: ?\n], min: 0)
    |> reduce({:to_metadata_tuple, []})

  note_comment_only =
    ignore(string(";"))
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

  @spec to_amount(keyword()) :: amount()
  defp to_amount(parts) do
    has_negative = Enum.member?(parts, :negative)
    sign = if has_negative, do: -1, else: 1
    currency = Keyword.get(parts, :currency, "$")
    dollars = Keyword.get(parts, :dollars, 0)
    cents = Keyword.get(parts, :cents, 0)

    value = sign * (dollars + cents / 100.0)

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

  @spec build_account_declaration(keyword()) :: account_declaration()
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
      %{date: nil, code: "", payee: nil, comment: nil, postings: []},
      fn
        {:date, date}, acc -> %{acc | date: date}
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
      # Check for date at start
      not Regex.match?(~r/^\d{4}\/\d{2}\/\d{2}/, first_line) ->
        {:error, :missing_date}

      # Check for payee (something after date and optional code)
      not Regex.match?(~r/^\d{4}\/\d{2}\/\d{2}\s+(?:\([^)]+\)\s+)?(.+)/, first_line) ->
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
      # Line doesn't start with enough whitespace
      not Regex.match?(~r/^(\s{2,}|\t)/, line)
    end)
  end

  @spec has_insufficient_spacing?([String.t()]) :: boolean()
  defp has_insufficient_spacing?(lines) do
    lines
    |> Enum.drop(1)
    |> Enum.filter(fn line -> Regex.match?(~r/^\s+[^\s;].*\$/, line) end)
    |> Enum.any?(fn line ->
      # Amount exists but doesn't have 2+ spaces before it
      Regex.match?(~r/\S\s\$/, line)
    end)
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

  ## Examples

      iex> content = "account Assets:Checking  ; type:asset\\n\\n2009/10/29 Panera\\n    Expenses:Food  $4.50\\n    Assets:Checking\\n"
      iex> ExLedger.LedgerParser.extract_account_declarations(content)
      %{"Assets:Checking" => :asset}

  """
  @spec extract_account_declarations(String.t()) :: %{String.t() => atom()}
  def extract_account_declarations(input) when is_binary(input) do
    input
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(String.trim(&1), "account "))
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_account_declaration(line) do
        {:ok, %{name: name, type: type}} -> Map.put(acc, name, type)
        {:error, _} -> acc
      end
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
  @spec parse_ledger_with_includes(String.t(), String.t(), MapSet.t(String.t())) ::
          {:ok, [transaction()], %{String.t() => atom()}}
          | {:error, {:include_not_found, String.t()}}
          | {:error, {:circular_include, String.t()}}
          | {:error, {parse_error(), non_neg_integer(), String.t() | nil}}
  def parse_ledger_with_includes(input, base_dir, seen_files \\ MapSet.new())

  def parse_ledger_with_includes("", _base_dir, _seen_files), do: {:ok, [], %{}}

  def parse_ledger_with_includes(input, base_dir, seen_files) do
    parse_ledger_with_includes(input, base_dir, seen_files, nil)
  end

  defp parse_ledger_with_includes(input, base_dir, seen_files, source_file) do
    # First extract account declarations
    accounts = extract_account_declarations(input)

    input
    |> String.split("\n")
    |> process_lines_with_includes(base_dir, seen_files, [], accounts, source_file)
    |> case do
      {:ok, all_content, all_accounts} ->
        # Parse the combined content as a ledger
        combined = Enum.join(all_content, "\n")

        case parse_ledger(combined, source_file) do
          {:ok, transactions} -> {:ok, transactions, all_accounts}
          error -> error
        end

      error ->
        error
    end
  end

  @spec process_lines_with_includes(
          [String.t()],
          String.t(),
          MapSet.t(String.t()),
          [String.t()],
          %{String.t() => atom()},
          String.t() | nil
        ) ::
          {:ok, [String.t()], %{String.t() => atom()}}
          | {:error, {:include_not_found, String.t()}}
          | {:error, {:circular_include, String.t()}}
  defp process_lines_with_includes([], _base_dir, _seen_files, acc, accounts, _source_file) do
    {:ok, Enum.reverse(acc), accounts}
  end

  defp process_lines_with_includes([line | rest], base_dir, seen_files, acc, accounts, source_file) do
    trimmed = String.trim(line)

    cond do
      # Check if this is an account declaration - skip it, already processed
      String.starts_with?(trimmed, "account ") ->
        process_lines_with_includes(rest, base_dir, seen_files, acc, accounts, source_file)

      # Check if this is an include directive
      String.starts_with?(trimmed, "include ") ->
        # Extract filename, removing any trailing comments
        filename =
          trimmed
          |> String.replace_prefix("include ", "")
          |> String.split(";")
          |> List.first()
          |> String.trim()

        # Resolve the full path
        include_path = Path.join(base_dir, filename)
        absolute_path = Path.expand(include_path)

        cond do
          # Check for circular includes
          MapSet.member?(seen_files, absolute_path) ->
            {:error, {:circular_include, filename}}

          # Check if file exists
          not File.exists?(absolute_path) ->
            {:error, {:include_not_found, filename}}

          true ->
            # Read and process the included file
            case File.read(absolute_path) do
              {:ok, included_content} ->
                # Get the directory of the included file for nested includes
                included_dir = Path.dirname(absolute_path)
                updated_seen = MapSet.put(seen_files, absolute_path)

                # Recursively process the included file with the filename as source
                case parse_ledger_with_includes(included_content, included_dir, updated_seen, filename) do
                  {:ok, included_transactions, included_accounts} ->
                    # Merge account declarations
                    merged_accounts = Map.merge(accounts, included_accounts)

                    # Convert transactions back to ledger format and add to accumulator
                    included_lines =
                      included_transactions
                      |> Enum.map(&transaction_to_lines/1)
                      |> Enum.intersperse("")

                    # Reverse included_lines so they appear in correct order after final reverse
                    process_lines_with_includes(
                      rest,
                      base_dir,
                      seen_files,
                      Enum.reverse(included_lines) ++ acc,
                      merged_accounts,
                      source_file
                    )

                  error ->
                    error
                end

              {:error, reason} ->
                {:error, {:file_read_error, filename, reason}}
            end
        end

      # Not an include directive or account declaration, just accumulate the line
      true ->
        process_lines_with_includes(rest, base_dir, seen_files, [line | acc], accounts, source_file)
    end
  end

  @spec transaction_to_lines(transaction()) :: String.t()
  defp transaction_to_lines(transaction) do
    # Format the header line
    code_part = if transaction.code != "", do: "(#{transaction.code}) ", else: ""
    comment_part = if transaction.comment, do: "  ; #{transaction.comment}", else: ""

    header =
      "#{format_transaction_date(transaction.date)} #{code_part}#{transaction.payee}#{comment_part}"

    # Format the postings
    posting_lines =
      Enum.map(transaction.postings, fn posting ->
        # Format metadata, tags, and comments
        notes =
          []
          |> add_metadata_lines(posting.metadata)
          |> add_tag_lines(posting.tags)
          |> add_comment_lines(posting.comments)

        # Format the account and amount
        amount_str =
          if posting.amount do
            currency = posting.amount.currency
            value = posting.amount.value
            sign = if value < 0, do: "-", else: ""
            abs_value = abs(value)
            formatted = :erlang.float_to_binary(abs_value, decimals: 2)
            "  #{currency}#{sign}#{formatted}"
          else
            ""
          end

        account_line = "    #{posting.account}#{String.pad_leading(amount_str, 20)}"

        Enum.join(notes ++ [account_line], "\n")
      end)

    Enum.join([header | posting_lines], "\n")
  end

  defp add_metadata_lines(lines, metadata) when map_size(metadata) == 0, do: lines

  defp add_metadata_lines(lines, metadata) do
    metadata_lines =
      metadata
      |> Enum.map(fn {key, value} -> "    ; #{key}: #{value}" end)

    lines ++ metadata_lines
  end

  defp add_tag_lines(lines, []), do: lines

  defp add_tag_lines(lines, tags) do
    tag_lines = Enum.map(tags, fn tag -> "    ; :#{tag}:" end)
    lines ++ tag_lines
  end

  defp add_comment_lines(lines, []), do: lines

  defp add_comment_lines(lines, comments) do
    comment_lines = Enum.map(comments, fn comment -> "    ; #{comment}" end)
    lines ++ comment_lines
  end

  defp format_transaction_date(date) do
    "#{date.year}/#{String.pad_leading(to_string(date.month), 2, "0")}/#{String.pad_leading(to_string(date.day), 2, "0")}"
  end

  defp split_transactions_with_line_numbers(input) do
    input
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], [], nil}, fn {line, index}, {chunks, current_lines, start_line} ->
      trimmed = String.trim(line)

      cond do
        # Empty line - end current transaction chunk if any
        trimmed == "" ->
          if current_lines == [] do
            {chunks, [], nil}
          else
            chunk = Enum.reverse(current_lines) |> Enum.join("\n")
            {[{chunk, start_line || index} | chunks], [], nil}
          end

        # Comment line (starts with ;) - skip it
        String.starts_with?(trimmed, ";") ->
          {chunks, current_lines, start_line}

        # Regular line - add to current chunk
        true ->
          start_line = start_line || index
          {chunks, [line | current_lines], start_line}
      end
    end)
    |> finalize_transaction_chunks()
  end

  defp finalize_transaction_chunks({chunks, [], _start_line}) do
    Enum.reverse(chunks)
  end

  defp finalize_transaction_chunks({chunks, current_lines, start_line}) do
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
  @spec validate_transaction(transaction()) :: :ok | {:error, :multiple_nil_amounts | :unbalanced}
  def validate_transaction(%{postings: postings}) do
    nil_count = Enum.count(postings, fn p -> is_nil(p.amount) end)

    cond do
      nil_count > 1 ->
        {:error, :multiple_nil_amounts}

      nil_count == 0 ->
        currency_totals = sum_postings_by_currency(postings)

        if Enum.all?(currency_totals, fn {_currency, total} -> abs(total) < 0.01 end) do
          :ok
        else
          if map_size(currency_totals) > 1 do
            :ok
          else
            {:error, :unbalanced}
          end
        end

      true ->
        :ok
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

  ## Examples

      iex> balances = %{"Assets:Checking" => %{value: -23.00, currency: "$"}, "Expenses:Pacific Bell" => %{value: 23.00, currency: "$"}}
      iex> ExLedger.LedgerParser.format_balance(balances)
      \"             $-23.00  Assets:Checking\\n              $23.00  Expenses:Pacific Bell\\n--------------------\\n                   0\\n\"
  """
  @spec format_balance(%{String.t() => amount()}) :: String.t()
  def format_balance(balances) do
    # Group totals by currency
    currency_totals =
      balances
      |> Map.values()
      |> Enum.group_by(& &1.currency, & &1.value)
      |> Enum.map(fn {currency, values} -> {currency, Enum.sum(values)} end)
      |> Enum.sort_by(fn {currency, _} -> currency end)

    # Sort accounts by account name
    sorted_accounts =
      balances
      |> Enum.sort_by(fn {account, _amount} -> account end)

    # Calculate max width for proper right-alignment
    max_width =
      sorted_accounts
      |> Enum.map(fn {_account, amount} ->
        amount_str = format_amount_with_currency(amount.value, amount.currency)
        String.length(amount_str)
      end)
      |> Enum.max(fn -> 0 end)

    result =
      sorted_accounts
      |> Enum.map_join("\n", fn {account, amount} ->
        amount_str = format_amount_with_currency(amount.value, amount.currency)
        "#{String.pad_leading(amount_str, max_width)}  #{account}"
      end)

    totals_str =
      currency_totals
      |> Enum.map_join("\n", fn {currency, total} ->
        format_total(total, currency, max_width)
      end)

    result <> "\n" <> String.duplicate("-", 20) <> "\n" <> totals_str <> "\n"
  end

  @spec format_amount_with_currency(float(), String.t()) :: String.t()
  defp format_amount_with_currency(value, currency) do
    sign = if value < 0, do: "-", else: ""
    abs_value = abs(value)
    formatted = :erlang.float_to_binary(abs_value, decimals: 2)
    "#{currency} #{sign}#{formatted}"
  end

  @spec format_total(float(), String.t(), non_neg_integer()) :: String.t()
  defp format_total(total, currency, width) do
    if abs(total) < 0.01 do
      String.pad_leading("0", 20)
    else
      amount_str = format_amount_with_currency(total, currency)
      String.pad_leading(amount_str, width)
    end
  end
end
