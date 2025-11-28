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
      # Standalone alias directive: alias SHORT = FULL:ACCOUNT:NAME
      String.starts_with?(trimmed, "alias ") ->
        case parse_standalone_alias(trimmed) do
          {:ok, alias_name, account_name} ->
            # Create a pseudo-account entry for the alias
            alias_entry = %{name: alias_name, type: :alias, aliases: [], assertions: [], target: account_name}
            parse_account_blocks(rest, [alias_entry | acc])

          {:error, _} ->
            parse_account_blocks(rest, acc)
        end

      # Old format: account NAME  ; type:TYPE
      String.starts_with?(trimmed, "account ") and String.contains?(line, ";") ->
        case parse_account_declaration(line) do
          {:ok, account} ->
            # Add default empty lists for aliases and assertions
            account = Map.merge(account, %{aliases: [], assertions: []})
            parse_account_blocks(rest, [account | acc])

          {:error, _} ->
            parse_account_blocks(rest, acc)
        end

      # New format: account NAME (followed by indented lines)
      String.starts_with?(trimmed, "account ") ->
        {account_lines, remaining} = collect_account_block([line | rest])
        account = parse_account_block(account_lines)
        parse_account_blocks(remaining, [account | acc])

      true ->
        parse_account_blocks(rest, acc)
    end
  end

  @spec parse_standalone_alias(String.t()) :: {:ok, String.t(), String.t()} | {:error, :invalid_alias}
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
    Enum.reduce(account_declarations, %{}, fn account, acc ->
      # Handle standalone alias entries (type: :alias)
      if account.type == :alias do
        # For standalone alias, map the alias name to the target account name
        Map.put(acc, account.name, account.target)
      else
        # Add the main account name -> type mapping
        acc = Map.put(acc, account.name, account.type)

        # Add each alias -> account name mapping
        Enum.reduce(account.aliases, acc, fn alias_name, acc_inner ->
          Map.put(acc_inner, alias_name, account.name)
        end)
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
  def parse_ledger_with_includes(input, base_dir, seen_files \\ MapSet.new(), source_file \\ nil)

  def parse_ledger_with_includes("", _base_dir, _seen_files, _source_file), do: {:ok, [], %{}}

  def parse_ledger_with_includes(input, base_dir, seen_files, source_file) when is_binary(source_file) or is_nil(source_file) do
    parse_ledger_with_includes_with_import(input, base_dir, seen_files, source_file, nil)
  end

  defp parse_ledger_with_includes_with_import(input, base_dir, seen_files, source_file, import_chain) do
    # First extract account declarations
    accounts = extract_account_declarations(input)

    # Process the file line by line, expanding includes in place while preserving order
    input
    |> String.split("\n")
    |> Enum.with_index(1)
    |> process_lines_and_includes(base_dir, seen_files, [], accounts, source_file, import_chain)
  end

  @spec process_lines_and_includes(
          [{String.t(), non_neg_integer()}],
          String.t(),
          MapSet.t(String.t()),
          [transaction()],
          %{String.t() => atom()},
          String.t() | nil,
          [{String.t(), non_neg_integer()}] | nil
        ) ::
          {:ok, [transaction()], %{String.t() => atom()}}
          | {:error, {:include_not_found, String.t()}}
          | {:error, {:circular_include, String.t()}}
          | {:error, {parse_error(), non_neg_integer(), String.t() | nil, [{String.t(), non_neg_integer()}] | nil}}
  defp process_lines_and_includes([], _base_dir, _seen_files, acc_transactions, accounts, _source_file, _import_chain) do
    {:ok, acc_transactions, accounts}
  end

  defp process_lines_and_includes(lines, base_dir, seen_files, acc_transactions, accounts, source_file, import_chain) do
    # Find the next include directive or end of non-include content
    {before_include, include_and_after} = split_at_include(lines)

    # Parse transactions in the before_include section (if any non-empty content)
    if before_include != [] do
      content = Enum.map_join(before_include, "\n", fn {line, _} -> line end)

      # Skip parsing if content is empty or only whitespace/comments
      if String.trim(content) == "" or only_comments_and_whitespace?(content) do
        # No real content, just process includes
        process_lines_and_includes(
          include_and_after,
          base_dir,
          seen_files,
          acc_transactions,
          accounts,
          source_file,
          import_chain
        )
      else
        case parse_ledger(content, source_file) do
        {:ok, transactions} ->
          # Continue with remaining lines (include and after)
          case include_and_after do
            [] ->
              # No more includes, we're done
              {:ok, acc_transactions ++ transactions, accounts}

            [{include_line, line_num} | rest] ->
              # Process the include directive
              trimmed = String.trim(include_line)

              if String.starts_with?(trimmed, "include ") do
                process_include_directive(
                  trimmed,
                  line_num,
                  rest,
                  base_dir,
                  seen_files,
                  acc_transactions ++ transactions,
                  accounts,
                  source_file,
                  import_chain
                )
              else
                # Not an include, continue processing
                process_lines_and_includes(
                  include_and_after,
                  base_dir,
                  seen_files,
                  acc_transactions ++ transactions,
                  accounts,
                  source_file,
                  import_chain
                )
              end
          end

        {:error, {reason, line, error_source_file}} ->
          # Error parsing - add import chain if present
          if import_chain do
            {:error, {reason, line, error_source_file, import_chain}}
          else
            {:error, {reason, line, error_source_file}}
          end
        end
      end
    else
      # No content before include, process the include directive
      case include_and_after do
        [] ->
          {:ok, acc_transactions, accounts}

        [{include_line, line_num} | rest] ->
          trimmed = String.trim(include_line)

          if String.starts_with?(trimmed, "include ") do
            process_include_directive(
              trimmed,
              line_num,
              rest,
              base_dir,
              seen_files,
              acc_transactions,
              accounts,
              source_file,
              import_chain
            )
          else
            # Skip this line and continue
            process_lines_and_includes(
              rest,
              base_dir,
              seen_files,
              acc_transactions,
              accounts,
              source_file,
              import_chain
            )
          end
      end
    end
  end

  defp only_comments_and_whitespace?(content) do
    content
    |> String.split("\n")
    |> Enum.all?(fn line ->
      trimmed = String.trim(line)
      trimmed == "" or String.starts_with?(trimmed, ";") or String.starts_with?(trimmed, "account ")
    end)
  end

  defp split_at_include(lines) do
    Enum.split_while(lines, fn {line, _line_num} ->
      trimmed = String.trim(line)
      # Keep taking lines until we hit an include directive
      not String.starts_with?(trimmed, "include ")
    end)
  end

  defp process_include_directive(
         trimmed_line,
         line_num,
         rest,
         base_dir,
         seen_files,
         acc_transactions,
         accounts,
         source_file,
         import_chain
       ) do
    filename = extract_include_filename(trimmed_line)
    absolute_path = resolve_include_path(base_dir, filename)

    with :ok <- check_circular_include(seen_files, absolute_path, filename),
         :ok <- check_file_exists(absolute_path, filename),
         {:ok, included_content} <- read_included_file(absolute_path, filename) do
      process_included_content(
        included_content,
        absolute_path,
        filename,
        line_num,
        rest,
        base_dir,
        seen_files,
        acc_transactions,
        accounts,
        source_file,
        import_chain
      )
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
         base_dir,
         seen_files,
         acc_transactions,
         accounts,
         source_file,
         import_chain
       ) do
    included_dir = Path.dirname(absolute_path)
    updated_seen = MapSet.put(seen_files, absolute_path)
    new_import_chain = build_import_chain(source_file, line_num, import_chain)

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
        merged_accounts = Map.merge(accounts, included_accounts)

        process_lines_and_includes(
          rest,
          base_dir,
          seen_files,
          acc_transactions ++ included_transactions,
          merged_accounts,
          source_file,
          import_chain
        )

      error ->
        error
    end
  end

  defp build_import_chain(nil, _line_num, import_chain), do: import_chain

  defp build_import_chain(source_file, line_num, import_chain) do
    [{source_file, line_num} | (import_chain || [])]
  end

  defp split_transactions_with_line_numbers(input) do
    input
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], [], nil, false}, fn {line, index}, {chunks, current_lines, start_line, in_account_block} ->
      trimmed = String.trim(line)

      cond do
        # Account declaration (old single-line format with semicolon) - skip it
        String.starts_with?(trimmed, "account ") and String.contains?(line, ";") and current_lines == [] ->
          {chunks, [], nil, false}

        # Start of account declaration (new multi-line format) - enter account block mode
        String.starts_with?(trimmed, "account ") and current_lines == [] ->
          {chunks, [], nil, true}

        # In account block and line is indented or empty - skip it
        in_account_block and (trimmed == "" or String.starts_with?(line, " ") or String.starts_with?(line, "\t")) ->
          {chunks, [], nil, true}

        # In account block and line is not indented - exit account block mode
        in_account_block ->
          # This line is not part of the account block, process it normally
          start_line = start_line || index
          {chunks, [line | current_lines], start_line, false}

        # Empty line - end current transaction chunk if any
        trimmed == "" ->
          if current_lines == [] do
            {chunks, [], nil, false}
          else
            chunk = Enum.reverse(current_lines) |> Enum.join("\n")
            {[{chunk, start_line || index} | chunks], [], nil, false}
          end

        # Comment line (starts with ;) - skip it
        String.starts_with?(trimmed, ";") ->
          {chunks, current_lines, start_line, false}

        # Include directive - skip it
        String.starts_with?(trimmed, "include ") ->
          {chunks, current_lines, start_line, false}

        # Alias directive - skip it
        String.starts_with?(trimmed, "alias ") ->
          {chunks, current_lines, start_line, false}

        # Regular line - add to current chunk
        true ->
          start_line = start_line || index
          {chunks, [line | current_lines], start_line, false}
      end
    end)
    |> finalize_transaction_chunks()
  end

  defp finalize_transaction_chunks({chunks, [], _start_line, _in_account_block}) do
    Enum.reverse(chunks)
  end

  defp finalize_transaction_chunks({chunks, current_lines, start_line, _in_account_block}) when current_lines != [] do
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

  ## Examples

      iex> balances = %{"Assets:Checking" => %{value: -23.00, currency: "$"}, "Expenses:Pacific Bell" => %{value: 23.00, currency: "$"}}
      iex> ExLedger.LedgerParser.format_balance(balances)
      \"             $-23.00  Assets:Checking\\n              $23.00  Expenses:Pacific Bell\\n--------------------\\n                   0\\n\"
  """
  @spec format_balance(%{String.t() => amount()}) :: String.t()
  def format_balance(balances) do
    account_summaries = build_account_summaries(balances)
    children_map = build_children_map(Map.keys(account_summaries))
    direct_accounts = Map.keys(balances) |> MapSet.new()

    lines =
      children_map
      |> Map.get(nil, [])
      |> Enum.sort()
      |> Enum.flat_map(fn account ->
        render_account(account, account_summaries, children_map, direct_accounts, 0)
      end)

    totals_section = String.duplicate("-", 20) <> "\n" <> String.pad_leading("0", 20) <> "\n"

    body =
      case lines do
        [] -> ""
        _ -> Enum.join(lines, "\n") <> "\n"
      end

    body <> totals_section
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
      [_single] -> nil
      segments ->
        segments
        |> Enum.slice(0, length(segments) - 1)
        |> Enum.join(":")
    end
  end

  defp render_account(account, summaries, children_map, direct_accounts, visible_depth) do
    children =
      Map.get(children_map, account, [])
      |> Enum.sort()

    direct? = MapSet.member?(direct_accounts, account)
    should_show = direct? or length(children) > 1

    lines =
      if should_show do
        render_account_lines(account, summaries, visible_depth)
      else
        []
      end

    next_visible_depth = if should_show, do: visible_depth + 1, else: visible_depth

    child_lines =
      Enum.flat_map(children, fn child ->
        render_account(child, summaries, children_map, direct_accounts, next_visible_depth)
      end)

    lines ++ child_lines
  end

  defp render_account_lines(account, summaries, visible_depth) do
    %{amounts: amounts} = Map.get(summaries, account, %{amounts: %{}})
    currencies = Enum.sort(Map.keys(amounts))
    last_index = max(length(currencies) - 1, 0)

    Enum.with_index(currencies)
    |> Enum.map(fn {currency, idx} ->
      value = Map.get(amounts, currency, 0)
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
