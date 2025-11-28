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
          code: String.t() | nil,
          payee: String.t(),
          comment: String.t() | nil,
          postings: [posting()]
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
          | {:unexpected_input, String.t()}

  # Basic building blocks
  whitespace = ascii_string([?\s, ?\t], min: 1)
  optional_whitespace = ascii_string([?\s, ?\t], min: 0)

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

  defparsec :date_parser, date

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

  # Currency symbol
  currency = ascii_char([?$]) |> replace("$")

  # Amount: optional negative sign, currency, digits with optional decimal
  amount_value =
    optional(ascii_char([?-]) |> replace(:negative))
    |> concat(currency |> unwrap_and_tag(:currency))
    |> concat(integer(min: 1) |> unwrap_and_tag(:dollars))
    |> optional(
      ignore(string("."))
      |> integer(2)
      |> unwrap_and_tag(:cents)
    )
    |> reduce({:to_amount, []})

  defparsec :amount_parser, amount_value

  # Account name - everything before at least 2 spaces and amount (or end of line)
  # Account names can contain single spaces but not multiple consecutive spaces
  account_name =
    utf8_string([not: ?\n, not: ?\s], min: 1)
    |> repeat(
      ascii_char([?\s]) |> utf8_string([not: ?\n, not: ?\s], min: 1)
    )
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
  defparsec :transaction_parser,
    transaction_header
    |> times(posting, min: 2)
    |> reduce({:build_transaction, []})

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

  defparsec :note_parser,
    choice([note_tag, note_metadata, note_comment_only])

  # Posting parser
  posting_line =
    ignore(optional_whitespace)
    |> concat(account_name)
    |> optional(
      ignore(ascii_string([?\s], min: 2))
      |> concat(amount_value |> unwrap_and_tag(:amount))
    )
    |> reduce({:to_posting_simple, []})

  defparsec :posting_parser, posting_line

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
      part when is_integer(part) -> <<part::utf8>>  # Convert space char codes to strings
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

  @spec to_posting(keyword()) :: posting()
  defp to_posting([{:account, account}]) do
    %{account: account, amount: nil, metadata: %{}, tags: [], comments: []}
  end

  defp to_posting([{:account, account}, {:amount, amount}]) do
    %{account: account, amount: amount, metadata: %{}, tags: [], comments: []}
  end

  @spec to_posting_simple(keyword()) :: {:ok, map()}
  defp to_posting_simple(parts) do
    account = Keyword.get(parts, :account)
    amount = Keyword.get(parts, :amount)
    {:ok, %{account: account, amount: amount}}
  end

  @spec to_metadata([String.t()]) :: {:metadata_kv, String.t(), String.t()}
  defp to_metadata([key, value]) do
    {:metadata_kv, String.trim(key), String.trim(value)}
  end

  @spec to_metadata_tuple([String.t()]) :: {:comment, String.t()} | {:metadata, String.t(), String.t()}
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
    {notes, [posting]} = Enum.split_while(items, fn
      %{account: _} -> false
      _ -> true
    end)

    metadata =
      notes
      |> Enum.filter(&match?({:metadata_kv, _, _}, &1))
      |> Enum.map(fn {:metadata_kv, k, v} -> {k, v} end)
      |> Map.new()

    tags =
      notes
      |> Enum.filter(&match?({:tag, _}, &1))
      |> Enum.map(fn {:tag, t} -> t end)

    comments =
      notes
      |> Enum.filter(&match?({:note_comment, _}, &1))
      |> Enum.map(fn {:note_comment, c} -> c end)

    %{posting | metadata: metadata, tags: tags, comments: comments}
  end

  @spec build_transaction(list()) :: transaction()
  defp build_transaction(parts) do
    # Extract tagged tuples and maps from the parts list
    date = parts |> Enum.find_value(fn
      {:date, d} -> d
      _ -> nil
    end)

    code = parts |> Enum.find_value(fn
      {:code, c} -> c
      _ -> nil
    end)

    payee = parts |> Enum.find_value(fn
      {:payee, p} -> p
      _ -> nil
    end)

    comment = parts |> Enum.find_value(fn
      {:comment, c} -> c
      _ -> nil
    end)

    postings = parts |> Enum.filter(&is_map/1)

    %{
      date: date,
      code: code,
      payee: payee,
      comment: comment,
      postings: postings
    }
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
  @spec parse_ledger(String.t()) :: {:ok, [transaction()]} | {:error, parse_error()}
  def parse_ledger(""), do: {:ok, []}
  def parse_ledger(input) do
    input
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_transaction/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, transaction}, {:ok, acc} -> {:cont, {:ok, [transaction | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, transactions} -> {:ok, Enum.reverse(transactions)}
      error -> error
    end
  end

  @doc """
  Parses a date string in YYYY/MM/DD format using NimbleParsec.
  """
  @spec parse_date(String.t()) :: {:ok, Date.t()} | {:error, :invalid_date_format}
  def parse_date(date_string) when is_binary(date_string) do
    case date_parser(date_string) do
      {:ok, [date: date], "", _, _, _} ->
        {:ok, date}

      {:ok, _, _rest, _, _, _} ->
        {:error, :invalid_date_format}

      {:error, _reason, _rest, _context, _line, _column} ->
        {:error, :invalid_date_format}
    end
  end

  @doc """
  Parses a posting line using NimbleParsec.
  """
  @spec parse_posting(String.t()) :: {:ok, map()} | {:error, :invalid_posting}
  def parse_posting(line) do
    case posting_parser(line) do
      {:ok, [result], "", _, _, _} ->
        result

      {:ok, _, _rest, _, _, _} ->
        {:error, :invalid_posting}

      {:error, _reason, _rest, _context, _line, _column} ->
        {:error, :invalid_posting}
    end
  end

  @doc """
  Parses an amount string like $4.50 or -$20.00 using NimbleParsec.
  """
  @spec parse_amount(String.t()) :: {:ok, amount()} | {:error, :invalid_amount}
  def parse_amount(amount_string) when is_binary(amount_string) do
    case amount_parser(amount_string) do
      {:ok, [amount], "", _, _, _} ->
        {:ok, amount}

      {:ok, _, _rest, _, _, _} ->
        {:error, :invalid_amount}

      {:error, _reason, _rest, _context, _line, _column} ->
        {:error, :invalid_amount}
    end
  end

  @doc """
  Parses a note/comment line and determines its type using NimbleParsec.
  """
  @spec parse_note(String.t()) ::
          {:ok, {:tag, String.t()} | {:metadata, String.t(), String.t()} | {:comment, String.t()}}
          | {:error, :invalid_note}
  def parse_note(note_string) when is_binary(note_string) do
    case note_parser(note_string) do
      {:ok, [result], "", _, _, _} ->
        {:ok, result}

      {:ok, _, _rest, _, _, _} ->
        {:error, :invalid_note}

      {:error, _reason, _rest, _context, _line, _column} ->
        {:error, :invalid_note}
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
        total =
          postings
          |> Enum.map(fn p -> p.amount.value end)
          |> Enum.sum()

        if abs(total) < 0.01 do
          :ok
        else
          {:error, :unbalanced}
        end

      true ->
        :ok
    end
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
end
