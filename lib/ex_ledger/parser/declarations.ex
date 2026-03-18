defmodule ExLedger.Parser.Declarations do
  @moduledoc """
  Extract and validate transaction element declarations (payees, commodities, tags).
  """

  alias ExLedger.Parser.{Accounts, Helpers}

  @doc """
  Lists all unique accounts from transactions.
  """
  @spec list_accounts([map()], %{String.t() => atom() | String.t()}) :: [String.t()]
  def list_accounts(transactions, account_map \\ %{}) do
    transaction_accounts =
      transactions
      |> Helpers.all_postings()
      |> Enum.map(fn posting -> Accounts.resolve_account_name(posting.account, account_map) end)

    declared_accounts =
      account_map
      |> Enum.filter(fn {_name, value} -> is_atom(value) end)
      |> Enum.map(fn {name, _type} -> name end)

    Helpers.uniq_sort(transaction_accounts ++ declared_accounts)
  end

  @doc """
  Lists all unique payees from transactions.
  """
  @spec list_payees([map()]) :: [String.t()]
  def list_payees(transactions) do
    transactions
    |> Enum.map(& &1.payee)
    |> Enum.reject(&is_nil/1)
    |> Helpers.uniq_sort()
  end

  @doc """
  Lists all unique commodities (currencies) from transactions.
  """
  @spec list_commodities([map()]) :: [String.t()]
  def list_commodities(transactions) do
    transactions
    |> Helpers.all_postings()
    |> Enum.map(&Helpers.posting_currency/1)
    |> Enum.reject(&is_nil/1)
    |> Helpers.uniq_sort()
  end

  @doc """
  Lists all unique tags from transaction postings.
  """
  @spec list_tags([map()]) :: [String.t()]
  def list_tags(transactions) do
    transactions
    |> Helpers.all_postings()
    |> Enum.flat_map(& &1.tags)
    |> Helpers.uniq_sort()
  end

  @doc """
  Returns the first transaction by date.
  """
  @spec first_transaction([map()]) :: map() | nil
  def first_transaction(transactions) do
    transactions
    |> Helpers.regular_transactions()
    |> Enum.sort_by(& &1.date, Date)
    |> List.first()
  end

  @doc """
  Returns the last transaction by date.
  """
  @spec last_transaction([map()]) :: map() | nil
  def last_transaction(transactions) do
    transactions
    |> Helpers.regular_transactions()
    |> Enum.sort_by(& &1.date, Date)
    |> List.last()
  end

  @doc """
  Extracts payee declarations from input.
  """
  @spec extract_payee_declarations(String.t()) :: MapSet.t(String.t())
  def extract_payee_declarations(input) when is_binary(input) do
    extract_declarations(input, "payee ", &extract_simple_value/1)
  end

  @doc """
  Extracts commodity declarations from input (symbols only).
  """
  @spec extract_commodity_declarations(String.t()) :: MapSet.t(String.t())
  def extract_commodity_declarations(input) when is_binary(input) do
    extract_declarations(input, "commodity ", &extract_commodity_value/1)
  end

  @doc """
  Extracts full commodity definitions from input.

  Parses commodity declarations with their subdirectives:
  - format: Display format string
  - note: Description
  - alias: Alternative symbol
  - default: Whether this is the default commodity
  - nomarket: Whether to exclude from market value calculations

  ## Example

      commodity CHF
          format CHF 1'000.00
          note Swiss Franc

  Returns a map of symbol => commodity_definition.
  """
  @spec extract_full_commodity_declarations(String.t()) :: %{String.t() => map()}
  def extract_full_commodity_declarations(input) when is_binary(input) do
    input
    |> String.split("\n")
    |> parse_commodity_blocks(%{}, nil)
  end

  @doc """
  Extracts tag declarations from input.
  """
  @spec extract_tag_declarations(String.t()) :: MapSet.t(String.t())
  def extract_tag_declarations(input) when is_binary(input) do
    extract_declarations(input, "tag ", &extract_first_word/1)
  end

  @doc """
  Checks that all accounts in transactions are declared.
  """
  @spec check_accounts([map()], %{String.t() => atom() | String.t()}) ::
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

  @doc """
  Checks that all payees in transactions are declared.
  """
  @spec check_payees([map()], MapSet.t(String.t())) :: :ok | {:error, String.t()}
  def check_payees(transactions, declared_payees) do
    transactions
    |> list_payees()
    |> Enum.find(fn payee -> not MapSet.member?(declared_payees, payee) end)
    |> case do
      nil -> :ok
      payee -> {:error, payee}
    end
  end

  @doc """
  Checks that all commodities in transactions are declared.
  """
  @spec check_commodities([map()], MapSet.t(String.t())) :: :ok | {:error, String.t()}
  def check_commodities(transactions, declared_commodities) do
    transactions
    |> list_commodities()
    |> Enum.find(fn commodity -> not MapSet.member?(declared_commodities, commodity) end)
    |> case do
      nil -> :ok
      commodity -> {:error, commodity}
    end
  end

  @doc """
  Checks that all tags in transactions and comments are declared.
  """
  @spec check_tags([map()], String.t(), MapSet.t(String.t())) ::
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

  # Private functions

  defp extract_declarations(input, prefix, extractor) do
    input
    |> String.split("\n")
    |> Enum.reduce(MapSet.new(), fn line, acc ->
      process_declaration_line(line, prefix, extractor, acc)
    end)
  end

  defp process_declaration_line(line, prefix, extractor, acc) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, prefix) do
      add_extracted_value(trimmed, prefix, extractor, acc)
    else
      acc
    end
  end

  defp add_extracted_value(trimmed, prefix, extractor, acc) do
    value =
      trimmed
      |> String.trim_leading(prefix)
      |> String.trim()
      |> extractor.()

    if value, do: MapSet.put(acc, value), else: acc
  end

  defp extract_simple_value(""), do: nil
  defp extract_simple_value(value), do: value

  defp extract_first_word(value) do
    value |> String.split(~r/\s+/, parts: 2) |> List.first() |> extract_simple_value()
  end

  defp extract_commodity_value(value) do
    value |> extract_first_word() |> extract_commodity_symbol()
  end

  defp extract_commodity_symbol(nil), do: nil

  defp extract_commodity_symbol(token) do
    case Regex.run(~r/^([^0-9\s.,]+)/, token) do
      [_, symbol] -> symbol
      _ -> token
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

  # Commodity block parsing

  defp parse_commodity_blocks([], acc, nil), do: acc

  defp parse_commodity_blocks([], acc, current) do
    finalize_commodity(acc, current)
  end

  defp parse_commodity_blocks([line | rest], acc, current) do
    trimmed = String.trim(line)
    indented? = String.starts_with?(line, " ") or String.starts_with?(line, "\t")

    cond do
      # Start of a new commodity block
      String.starts_with?(trimmed, "commodity ") ->
        symbol = extract_commodity_symbol_from_line(trimmed)
        new_acc = if current, do: finalize_commodity(acc, current), else: acc
        new_current = new_commodity_definition(symbol)
        parse_commodity_blocks(rest, new_acc, new_current)

      # Subdirective within a commodity block
      indented? and current != nil ->
        updated = parse_commodity_subdirective(current, trimmed)
        parse_commodity_blocks(rest, acc, updated)

      # Other line - finalize current if any
      true ->
        new_acc = if current, do: finalize_commodity(acc, current), else: acc
        parse_commodity_blocks(rest, new_acc, nil)
    end
  end

  defp new_commodity_definition(symbol) do
    %{
      symbol: symbol,
      format: nil,
      note: nil,
      alias: nil,
      default: false,
      nomarket: false
    }
  end

  defp finalize_commodity(acc, commodity) do
    Map.put(acc, commodity.symbol, commodity)
  end

  defp extract_commodity_symbol_from_line(line) do
    line
    |> String.trim_leading("commodity ")
    |> String.trim()
    |> extract_commodity_value()
  end

  defp parse_commodity_subdirective(commodity, line) do
    cond do
      String.starts_with?(line, "format ") ->
        format = String.trim_leading(line, "format ") |> String.trim()
        %{commodity | format: format}

      String.starts_with?(line, "note ") ->
        note = String.trim_leading(line, "note ") |> String.trim()
        %{commodity | note: note}

      String.starts_with?(line, "alias ") ->
        alias_sym = String.trim_leading(line, "alias ") |> String.trim()
        %{commodity | alias: alias_sym}

      line == "default" ->
        %{commodity | default: true}

      line == "nomarket" ->
        %{commodity | nomarket: true}

      # Unknown subdirective - ignore
      true ->
        commodity
    end
  end
end
