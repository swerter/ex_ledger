defmodule ExLedger.LedgerParser do
  @moduledoc """
  Parser for ledger-cli format files.

  This module serves as the main entry point and facade for ledger parsing functionality.
  Core parsing is delegated to specialized submodules under ExLedger.Parser.
  """

  alias ExLedger.EntryFormatter
  alias ExLedger.ParseContext
  alias ExLedger.Parser.{Accounts, Core, Declarations, Helpers, Timeclock, Transaction}

  # Re-export types from Core
  @type amount :: Core.amount()
  @type posting :: Core.posting()
  @type transaction :: Core.transaction()
  @type account_declaration :: Core.account_declaration()
  @type parse_error :: Core.parse_error()
  @type parse_error_detail :: Core.parse_error_detail()
  @type ledger_error :: Core.ledger_error()
  @type time_entry :: Timeclock.time_entry()

  # Delegate to Parser.Transaction
  defdelegate parse_transaction(input), to: Transaction
  defdelegate parse_date(date_string), to: Transaction
  defdelegate parse_posting(line), to: Transaction
  defdelegate parse_amount(amount_string), to: Transaction
  defdelegate parse_note(note_string), to: Transaction
  defdelegate balance_postings(transaction_or_postings), to: Transaction
  defdelegate validate_transaction(transaction), to: Transaction

  # Delegate to Parser.Accounts
  defdelegate extract_account_declarations(input), to: Accounts
  defdelegate parse_account_declaration(input), to: Accounts
  defdelegate resolve_account_name(account_name, account_map), to: Accounts
  defdelegate resolve_transaction_aliases(transactions, account_map), to: Accounts

  # Delegate to Parser.Declarations
  defdelegate list_accounts(transactions, account_map \\ %{}), to: Declarations
  defdelegate list_payees(transactions), to: Declarations
  defdelegate list_commodities(transactions), to: Declarations
  defdelegate list_tags(transactions), to: Declarations
  defdelegate first_transaction(transactions), to: Declarations
  defdelegate last_transaction(transactions), to: Declarations
  defdelegate extract_payee_declarations(input), to: Declarations
  defdelegate extract_commodity_declarations(input), to: Declarations
  defdelegate extract_tag_declarations(input), to: Declarations
  defdelegate check_accounts(transactions, accounts), to: Declarations
  defdelegate check_payees(transactions, declared_payees), to: Declarations
  defdelegate check_commodities(transactions, declared_commodities), to: Declarations
  defdelegate check_tags(transactions, contents, declared_tags), to: Declarations

  # Delegate to Parser.Timeclock
  defdelegate parse_timeclock_entries(input), to: Timeclock
  defdelegate timeclock_report(entries), to: Timeclock
  defdelegate format_timeclock_report(report), to: Timeclock

  # Delegate to Parser.Helpers
  defdelegate format_amount_for_currency(value, currency, currency_position \\ :leading),
    to: Helpers

  # Internal helpers used throughout this module
  defp regular_transactions(transactions), do: Helpers.regular_transactions(transactions)
  defp regular_transaction?(transaction), do: Helpers.regular_transaction?(transaction)
  defp regular_postings(transactions), do: Helpers.regular_postings(transactions)
  defp posting_currency(posting), do: Helpers.posting_currency(posting)

  # ============================================================================
  # File parsing and include handling
  # ============================================================================

  @doc """
  Checks whether the ledger file at the given path parses successfully.
  """
  @spec check_file(String.t()) :: boolean()
  def check_file(path) when is_binary(path) do
    match?({:ok, _}, check_file_with_error(path))
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
           parse_ledger(contents, base_dir: base_dir, source_file: filename) do
      {:ok, :valid}
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _} -> {:error, reason}
      error -> {:error, error}
    end
  end

  @doc """
  Checks whether the given ledger string parses successfully.
  """
  @spec check_string(String.t(), String.t()) :: boolean()
  def check_string(content, base_dir \\ ".") when is_binary(content) and is_binary(base_dir) do
    case parse_ledger(content, base_dir: base_dir) do
      {:ok, _, _} -> true
      _ -> false
    end
  end

  @doc """
  Parses a ledger file with support for include directives and account declarations.
  """
  @spec parse_ledger(String.t(), keyword()) ::
          {:ok, [transaction()], %{String.t() => atom()}} | {:error, ledger_error()}
  def parse_ledger(input, opts \\ [])

  def parse_ledger("", _opts), do: {:ok, [], %{}}

  def parse_ledger(input, opts) when is_binary(input) do
    base_dir = Keyword.get(opts, :base_dir, ".")
    source_file = Keyword.get(opts, :source_file, nil)
    seen_files = Keyword.get(opts, :seen_files, MapSet.new())

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
      when is_binary(input) and is_binary(base_dir) do
    expand_includes_with_import(input, base_dir, seen_files, source_file, nil)
  end

  # ============================================================================
  # Include processing private functions
  # ============================================================================

  defp parse_ledger_with_includes_with_import(
         input,
         base_dir,
         seen_files,
         source_file,
         import_chain
       ) do
    accounts = Accounts.extract_account_declarations(input)

    context = %ParseContext{
      base_dir: base_dir,
      seen_files: seen_files,
      source_file: source_file,
      import_chain: import_chain,
      accounts: accounts,
      transactions: []
    }

    case expand_and_parse_with_includes(input, context, []) do
      {:ok, transactions, final_accounts, _ctx} ->
        {:ok, transactions, final_accounts}

      {:error, _} = error ->
        error
    end
  end

  defp expand_and_parse_with_includes(input, context, acc_transactions) do
    {lines, include_parts} = split_at_include(input)

    # Parse transactions from current file before processing include
    new_transactions =
      if lines != "" do
        case parse_ledger_chunk(lines, context.accounts, context.source_file) do
          {:ok, txns, _} ->
            txns

          {:error, error} ->
            # Add import chain to error
            throw({:parse_error, Map.put(error, :import_chain, context.import_chain)})
        end
      else
        []
      end

    acc_transactions = acc_transactions ++ new_transactions

    case include_parts do
      nil ->
        {:ok, acc_transactions, context.accounts, context}

      {include_line, line_number, rest} ->
        case process_include_directive_with_parse(include_line, line_number, context) do
          {:ok, included_transactions, updated_context} ->
            expand_and_parse_with_includes(
              rest,
              updated_context,
              acc_transactions ++ included_transactions
            )

          {:error, _} = error ->
            error
        end
    end
  catch
    {:parse_error, error} -> {:error, error}
  end

  defp expand_lines_and_includes(input, context, acc) do
    {lines, include_parts} = split_at_include(input)
    acc = if lines != "", do: [lines | acc], else: acc

    case include_parts do
      nil ->
        {:ok, acc |> Enum.reverse() |> Enum.join("\n"), context}

      {include_line, line_number, rest} ->
        case process_include_directive(include_line, line_number, context, acc) do
          {:ok, new_acc, new_context} ->
            expand_lines_and_includes(rest, new_context, new_acc)

          {:error, _} = error ->
            error
        end
    end
  end

  defp split_at_include(input) do
    lines = String.split(input, "\n")

    result =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce_while({[], nil}, fn {line, idx}, {acc, _} ->
        trimmed = String.trim(line)

        if String.starts_with?(trimmed, "include ") do
          rest = lines |> Enum.drop(idx) |> Enum.join("\n")
          {:halt, {Enum.reverse(acc), {trimmed, idx, rest}}}
        else
          {:cont, {[line | acc], nil}}
        end
      end)

    case result do
      {acc, nil} -> {Enum.reverse(acc) |> Enum.join("\n"), nil}
      {acc, include_info} -> {Enum.reverse(acc) |> Enum.join("\n"), include_info}
    end
  end

  defp process_include_directive_with_parse(include_line, line_number, context) do
    case extract_include_filename(include_line) do
      {:ok, filename} ->
        new_import_chain =
          build_import_chain(context.source_file, line_number, context.import_chain)

        # Reject absolute paths immediately
        with :ok <- check_relative_path(filename),
             include_path = resolve_include_path(filename, context.base_dir),
             :ok <- path_within_base?(include_path, context.base_dir, filename),
             :ok <- check_file_exists(include_path, filename),
             :ok <- check_circular_include(include_path, context.seen_files, filename),
             {:ok, content} <- File.read(include_path) do
          included_accounts = Accounts.extract_account_declarations(content)
          new_accounts = Map.merge(context.accounts, included_accounts)
          new_seen = MapSet.put(context.seen_files, include_path)
          include_dir = Path.dirname(include_path)
          include_file = Path.basename(include_path)

          new_context = %{
            context
            | base_dir: include_dir,
              seen_files: new_seen,
              source_file: include_file,
              import_chain: new_import_chain,
              accounts: new_accounts
          }

          case expand_and_parse_with_includes(content, new_context, []) do
            {:ok, transactions, _, _} ->
              # Return updated context with merged accounts and seen files
              updated_context = %{
                context
                | accounts: new_accounts,
                  seen_files: new_seen
              }

              {:ok, transactions, updated_context}

            {:error, _} = error ->
              error
          end
        else
          {:error, reason} when is_atom(reason) ->
            {:error, {:file_read_error, filename, reason}}

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp process_include_directive(include_line, line_number, context, acc) do
    case extract_include_filename(include_line) do
      {:ok, filename} ->
        new_import_chain =
          build_import_chain(context.source_file, line_number, context.import_chain)

        # Reject absolute paths immediately
        with :ok <- check_relative_path(filename),
             include_path = resolve_include_path(filename, context.base_dir),
             :ok <- path_within_base?(include_path, context.base_dir, filename),
             :ok <- check_file_exists(include_path, filename),
             :ok <- check_circular_include(include_path, context.seen_files, filename) do
          process_included_content(include_path, context, new_import_chain, acc)
        end

      {:error, _} = error ->
        error
    end
  end

  defp extract_include_filename(line) do
    filename =
      line
      |> String.trim_leading("include")
      |> String.trim()
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()

    if filename != "" do
      {:ok, filename}
    else
      {:error, {:include_not_found, ""}}
    end
  end

  defp resolve_include_path(filename, base_dir) do
    path = Path.join(base_dir, filename)
    resolve_symlinks(path)
  end

  defp resolve_symlinks(path) do
    case File.read_link(path) do
      {:ok, target} ->
        if Path.type(target) == :absolute do
          resolve_symlinks(target)
        else
          path |> Path.dirname() |> Path.join(target) |> Path.expand() |> resolve_symlinks()
        end

      {:error, _} ->
        Path.expand(path)
    end
  end

  defp check_relative_path(filename) do
    if Path.type(filename) == :absolute do
      {:error, {:include_outside_base, filename}}
    else
      :ok
    end
  end

  defp check_file_exists(path, filename) do
    if File.exists?(path) do
      :ok
    else
      {:error, {:include_not_found, filename}}
    end
  end

  defp check_circular_include(path, seen_files, filename) do
    if MapSet.member?(seen_files, path) do
      {:error, {:circular_include, filename}}
    else
      :ok
    end
  end

  defp path_within_base?(path, base_dir, filename) do
    expanded_base = Path.expand(base_dir)
    expanded_path = Path.expand(path)

    if String.starts_with?(expanded_path, expanded_base) do
      :ok
    else
      {:error, {:include_outside_base, filename}}
    end
  end

  defp build_import_chain(nil, _line, chain), do: chain
  defp build_import_chain(file, line, nil), do: [{file, line}]
  defp build_import_chain(file, line, chain), do: [{file, line} | chain]

  defp process_included_content(include_path, context, import_chain, acc) do
    case File.read(include_path) do
      {:ok, content} ->
        included_accounts = Accounts.extract_account_declarations(content)
        new_accounts = Map.merge(context.accounts, included_accounts)
        new_seen = MapSet.put(context.seen_files, include_path)
        include_dir = Path.dirname(include_path)
        include_file = Path.basename(include_path)

        new_context = %{
          context
          | base_dir: include_dir,
            seen_files: new_seen,
            source_file: include_file,
            import_chain: import_chain,
            accounts: new_accounts
        }

        case expand_lines_and_includes(content, new_context, []) do
          {:ok, expanded, _} ->
            {:ok, [expanded | acc], %{context | accounts: new_accounts, seen_files: new_seen}}

          error ->
            error
        end

      {:error, reason} ->
        {:error, {:file_read_error, Path.basename(include_path), reason}}
    end
  end

  defp expand_includes_with_import(input, base_dir, seen_files, source_file, import_chain) do
    context = %ParseContext{
      base_dir: base_dir,
      seen_files: seen_files,
      source_file: source_file,
      import_chain: import_chain,
      accounts: %{},
      transactions: []
    }

    case expand_lines_and_includes(input, context, []) do
      {:ok, content, _ctx} -> {:ok, content}
      error -> error
    end
  end

  defp parse_ledger_chunk(content, accounts, source_file) when is_list(content) do
    parse_ledger_chunk(Enum.join(content, "\n"), accounts, source_file)
  end

  defp parse_ledger_chunk(content, accounts, source_file) when is_binary(content) do
    chunks = split_transactions_with_line_numbers(content)

    results =
      Enum.reduce_while(chunks, {:ok, []}, fn {chunk, line_number}, {:ok, acc} ->
        parse_chunk_item(chunk, line_number, source_file, acc)
      end)

    case results do
      {:ok, transactions} ->
        {:ok, Enum.reverse(transactions), accounts}

      {:error, _} = error ->
        error
    end
  end

  defp parse_chunk_item(chunk, line_number, source_file, acc) do
    if skip_content_chunk?(chunk) do
      {:cont, {:ok, acc}}
    else
      parse_and_add_transaction(chunk, line_number, source_file, acc)
    end
  end

  defp parse_and_add_transaction(chunk, line_number, source_file, acc) do
    case Transaction.parse_transaction(chunk <> "\n") do
      {:ok, transaction} ->
        transaction =
          transaction
          |> maybe_add_source_file(source_file)
          |> Map.put(:source_line, line_number)

        {:cont, {:ok, [transaction | acc]}}

      {:error, reason} ->
        {:halt, {:error, %{reason: reason, line: line_number, file: source_file}}}
    end
  end

  defp skip_content_chunk?(chunk) do
    only_comments_and_whitespace?(chunk)
  end

  defp only_comments_and_whitespace?(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.all?(fn line ->
      trimmed = String.trim(line)
      trimmed == "" or String.starts_with?(trimmed, ";")
    end)
  end

  defp maybe_add_source_file(transaction, nil), do: transaction
  defp maybe_add_source_file(transaction, file), do: Map.put(transaction, :source_file, file)

  defp split_transactions_with_line_numbers(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], [], nil, false}, &process_line_for_transaction/2)
    |> finalize_transaction_chunks()
  end

  defp process_line_for_transaction(
         {line, index},
         {chunks, current_lines, start_line, in_account_block}
       ) do
    trimmed = String.trim(line)

    cond do
      new_account_declaration?(trimmed) ->
        {new_chunks, _, _, _} = handle_empty_line(chunks, current_lines, start_line, index)
        {new_chunks, [], nil, true}

      in_account_block ->
        handle_account_block_line(line, trimmed, index, chunks, current_lines, start_line)

      trimmed == "" ->
        handle_empty_line(chunks, current_lines, start_line, index)

      timeclock_line?(line) ->
        {chunks, current_lines, start_line, in_account_block}

      skippable_line?(trimmed, current_lines) ->
        {chunks, current_lines, start_line, in_account_block}

      true ->
        process_regular_line(line, index, chunks, current_lines, start_line, in_account_block)
    end
  end

  defp new_account_declaration?(trimmed) do
    String.starts_with?(trimmed, "account ") and not String.contains?(trimmed, ";")
  end

  defp handle_account_block_line(line, trimmed, index, chunks, current_lines, start_line) do
    cond do
      trimmed == "" ->
        # Exit account block on empty line
        {chunks, current_lines, start_line, false}

      not String.starts_with?(line, " ") and not String.starts_with?(line, "\t") ->
        # Exit account block on non-indented line
        handle_account_block_exit(line, trimmed, index, chunks, current_lines, start_line)

      true ->
        # Still within account block (indented line)
        {chunks, current_lines, start_line, true}
    end
  end

  defp handle_account_block_exit(line, trimmed, index, chunks, current_lines, start_line) do
    if skippable_line?(trimmed, current_lines) do
      {chunks, current_lines, start_line, false}
    else
      process_regular_line(line, index, chunks, current_lines, start_line, false)
    end
  end

  defp process_regular_line(line, index, chunks, current_lines, start_line, in_account_block) do
    if starts_new_entry?(line) and current_lines != [] do
      chunk = Enum.reverse(current_lines) |> Enum.join("\n")
      {[{chunk, start_line} | chunks], [line], index, in_account_block}
    else
      start_line = start_line || index
      {chunks, [line | current_lines], start_line, in_account_block}
    end
  end

  defp handle_empty_line(chunks, current_lines, start_line, index) do
    if current_lines == [] do
      {chunks, [], nil, false}
    else
      chunk = Enum.reverse(current_lines) |> Enum.join("\n")
      {[{chunk, start_line || index} | chunks], [], nil, false}
    end
  end

  defp starts_new_entry?(line) do
    starts_with_date?(line) or starts_with_directive?(String.trim_leading(line))
  end

  defp starts_with_date?(line), do: Regex.match?(~r/^\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2}/, line)

  defp starts_with_directive?(line),
    do: String.starts_with?(line, "=") or String.starts_with?(line, "~")

  defp timeclock_line?(line),
    do:
      String.starts_with?(line, "i ") or String.starts_with?(line, "o ") or
        String.starts_with?(line, "O ")

  defp skippable_line?(trimmed, current_lines) do
    current_lines == [] and
      (String.starts_with?(trimmed, ";") or
         String.starts_with?(trimmed, "include ") or
         String.starts_with?(trimmed, "alias ") or
         String.starts_with?(trimmed, "tag ") or
         String.starts_with?(trimmed, "payee ") or
         String.starts_with?(trimmed, "commodity ") or
         old_style_account_declaration?(trimmed))
  end

  defp old_style_account_declaration?(trimmed) do
    String.starts_with?(trimmed, "account ") and String.contains?(trimmed, ";")
  end

  defp finalize_transaction_chunks({chunks, [], _start_line, _in_account_block}),
    do: Enum.reverse(chunks)

  defp finalize_transaction_chunks({chunks, current_lines, start_line, _in_account_block})
       when current_lines != [] do
    chunk = Enum.reverse(current_lines) |> Enum.join("\n")
    start = start_line || 1
    Enum.reverse([{chunk, start} | chunks])
  end

  # ============================================================================
  # Account postings and register
  # ============================================================================

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

  defp format_register_amount(nil), do: String.pad_leading("0.00", 9)

  defp format_register_amount(%{value: value, currency: currency}) do
    value
    |> format_amount_for_currency(currency)
    |> String.pad_leading(9)
  end

  defp format_register_amount(value) when is_integer(value) or is_float(value) do
    ExLedger.format_amount(value)
  end

  # ============================================================================
  # Balance calculations
  # ============================================================================

  @doc """
  Calculates the balance for each account by summing all postings.
  """
  @spec balance([transaction()] | transaction()) :: %{String.t() => [map()]}
  def balance(transaction) when is_map(transaction), do: balance([transaction])

  def balance(transactions) when is_list(transactions) do
    transactions
    |> regular_postings()
    |> Enum.group_by(fn posting -> posting.account end)
    |> Enum.map(fn {account, postings} ->
      amounts =
        postings
        |> Enum.group_by(fn posting -> posting.amount.currency end)
        |> Enum.map(fn {currency, currency_postings} ->
          total = currency_postings |> Enum.map(& &1.amount.value) |> Enum.sum()
          %{amount: total, currency: currency}
        end)
        |> Enum.sort_by(& &1.currency)

      {account, amounts}
    end)
    |> Map.new()
  end

  @doc """
  Formats a balance report for transactions with optional filtering and output options.
  """
  @spec balance_report([transaction()], Regex.t() | nil, keyword()) :: String.t()
  def balance_report(transactions, report_regex \\ nil, opts \\ []) do
    balances =
      transactions
      |> balance()
      |> filter_balances(report_regex)

    show_parents =
      report_regex != nil and not Keyword.get(opts, :flat, false) and
        not Keyword.get(opts, :top_level_only, false)

    opts = Keyword.put_new(opts, :show_parents, show_parents)

    format_balance(balances, opts)
  end

  @doc false
  def filter_balances(balances, nil), do: balances

  def filter_balances(balances, report_regex) do
    balances
    |> Enum.filter(fn {account, _amount} -> Regex.match?(report_regex, account) end)
    |> Map.new()
  end

  @doc """
  Formats account balances as a balance report.
  """
  @spec format_balance(%{String.t() => [map()]}, boolean() | keyword()) :: String.t()
  def format_balance(balances, opts \\ false)

  def format_balance(balances, opts) when is_list(opts) do
    show_empty = Keyword.get(opts, :show_empty, false)
    flat = Keyword.get(opts, :flat, false)
    show_total = Keyword.get(opts, :show_total, true)
    top_level_only = Keyword.get(opts, :top_level_only, false)
    show_parents = Keyword.get(opts, :show_parents, false)

    format_balance_with_options(
      balances,
      show_empty,
      flat,
      show_total,
      top_level_only,
      show_parents
    )
  end

  def format_balance(balances, show_empty) when is_boolean(show_empty) do
    format_balance_with_options(balances, show_empty, false, true, false, false)
  end

  defp format_balance_with_options(
         balances,
         show_empty,
         flat,
         show_total,
         top_level_only,
         show_parents
       ) do
    account_summaries = build_account_summaries(balances)
    children_map = build_children_map(Map.keys(account_summaries))
    direct_accounts = Map.keys(balances) |> MapSet.new()

    lines =
      cond do
        top_level_only ->
          children_map
          |> Map.get(nil, [])
          |> Enum.sort()
          |> Enum.flat_map(fn account ->
            render_account_lines(account, account_summaries, 0, show_empty)
          end)

        flat ->
          balances
          |> Map.keys()
          |> Enum.sort()
          |> Enum.flat_map(fn account ->
            render_account_lines(account, account_summaries, 0, show_empty)
          end)

        true ->
          children_map
          |> Map.get(nil, [])
          |> Enum.sort()
          |> Enum.flat_map(fn account ->
            render_account(
              account,
              account_summaries,
              children_map,
              direct_accounts,
              0,
              show_empty,
              show_parents
            )
          end)
      end

    totals_section = if show_total, do: format_totals_section(balances), else: ""

    body =
      case lines do
        [] -> ""
        _ -> Enum.join(lines, "\n") <> "\n"
      end

    body <> totals_section
  end

  defp build_account_summaries(balances) do
    Enum.reduce(balances, %{}, fn {account, amounts_list}, acc ->
      segments = String.split(account, ":")

      Enum.reduce(amounts_list, acc, fn %{amount: value, currency: currency}, acc_currencies ->
        add_amount_to_account_hierarchy(acc_currencies, segments, currency, value)
      end)
    end)
  end

  defp add_amount_to_account_hierarchy(acc, segments, currency, value) do
    Enum.reduce(1..length(segments), acc, fn idx, acc_inner ->
      prefix = Enum.take(segments, idx) |> Enum.join(":")
      update_account_summary(acc_inner, prefix, currency, value)
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
      segments -> segments |> Enum.slice(0, length(segments) - 1) |> Enum.join(":")
    end
  end

  defp render_account(
         account,
         summaries,
         children_map,
         direct_accounts,
         visible_depth,
         show_empty,
         show_parents
       ) do
    children = Map.get(children_map, account, []) |> Enum.sort()
    direct? = MapSet.member?(direct_accounts, account)
    should_show = direct? or length(children) > 1 or show_parents

    %{amounts: amounts} = Map.get(summaries, account, %{amounts: %{}})
    has_non_zero_balance = Enum.any?(amounts, fn {_currency, value} -> abs(value) >= 0.01 end)
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
          show_empty,
          show_parents
        )
      end)

    lines ++ child_lines
  end

  defp render_account_lines(account, summaries, visible_depth, show_empty) do
    %{amounts: amounts} = Map.get(summaries, account, %{amounts: %{}})

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

  defp display_account_name(account, 0), do: account
  defp display_account_name(account, _), do: account |> String.split(":") |> List.last()

  defp format_totals_section(balances) do
    currency_totals =
      balances
      |> Enum.reduce(%{}, fn {_account, amounts_list}, acc ->
        Enum.reduce(amounts_list, acc, fn %{amount: value, currency: currency}, acc_inner ->
          Map.update(acc_inner, currency, value, &(&1 + value))
        end)
      end)

    separator = String.duplicate("-", 20) <> "\n"

    if map_size(currency_totals) == 1 do
      [{currency, total}] = Map.to_list(currency_totals)
      normalized_total = if abs(total) < 0.005, do: 0.0, else: total
      amount_str = format_amount_for_currency(normalized_total, currency)
      separator <> String.pad_leading(amount_str, 20) <> "\n"
    else
      # Don't filter out zero amounts - they're meaningful in totals
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

  # ============================================================================
  # Balance by period
  # ============================================================================

  @spec format_balance_by_period(%{String.t() => any()}, keyword()) :: String.t()
  def format_balance_by_period(%{"periods" => periods, "balances" => balances}, opts \\ []) do
    show_empty = Keyword.get(opts, :show_empty, false)
    show_total = Keyword.get(opts, :show_total, true)

    case periods do
      [] ->
        ""

      _ ->
        period_labels = Enum.map(periods, & &1.label)
        account_currency_periods = build_account_currency_periods(period_labels, balances)
        rows = build_period_rows(account_currency_periods, period_labels, show_empty)
        period_widths = calculate_period_widths(rows, period_labels)
        account_width = calculate_account_width(rows)
        header = build_period_header(periods, period_labels, account_width, period_widths)

        body =
          rows
          |> Enum.map_join("\n", fn row ->
            build_period_line(row.account, row.formatted, account_width, period_widths)
          end)

        totals_section =
          if show_total do
            totals = build_period_totals(period_labels, balances)
            build_period_totals_section(totals, account_width, period_widths)
          else
            ""
          end

        header <> body <> totals_section
    end
  end

  defp build_account_currency_periods(period_labels, balances) do
    Enum.reduce(period_labels, %{}, fn label, acc ->
      period_balances = Map.get(balances, label, %{})
      Enum.reduce(period_balances, acc, &add_period_balance_to_account(&1, &2, label))
    end)
  end

  defp add_period_balance_to_account({account, amounts_list}, acc_accounts, label) do
    Enum.reduce(amounts_list, acc_accounts, fn %{amount: amount, currency: currency}, acc1 ->
      update_account_currency_period(acc1, account, currency, label, amount)
    end)
  end

  defp update_account_currency_period(acc, account, currency, label, amount) do
    Map.update(acc, account, %{currency => %{label => amount}}, fn currencies ->
      Map.update(currencies, currency, %{label => amount}, fn amounts ->
        Map.update(amounts, label, amount, &(&1 + amount))
      end)
    end)
  end

  defp build_period_rows(account_currency_periods, period_labels, show_empty) do
    account_currency_periods
    |> Enum.sort_by(fn {account, _} -> account end)
    |> Enum.flat_map(fn {account, currency_map} ->
      build_currency_rows_for_account(account, currency_map, period_labels, show_empty)
    end)
  end

  defp build_currency_rows_for_account(account, currency_map, period_labels, show_empty) do
    currency_map
    |> Enum.sort_by(fn {currency, _} -> currency end)
    |> Enum.reduce([], fn {currency, amounts_map}, acc ->
      amounts = Enum.map(period_labels, &Map.get(amounts_map, &1, 0.0))
      maybe_add_currency_row(acc, account, currency, amounts, show_empty)
    end)
    |> Enum.reverse()
  end

  defp maybe_add_currency_row(acc, account, currency, amounts, show_empty) do
    if show_empty or Enum.any?(amounts, fn value -> abs(value) >= 0.01 end) do
      formatted = Enum.map(amounts, &format_amount_for_currency(&1, currency))
      [%{account: account, currency: currency, amounts: amounts, formatted: formatted} | acc]
    else
      acc
    end
  end

  defp calculate_period_widths(rows, period_labels) do
    Enum.reduce(rows, Enum.map(period_labels, &String.length/1), fn row, acc ->
      Enum.zip(acc, row.formatted)
      |> Enum.map(fn {width, value} -> max(width, String.length(value)) end)
    end)
  end

  defp calculate_account_width(rows) do
    rows
    |> Enum.map(&String.length(&1.account))
    |> Enum.max(fn -> 0 end)
  end

  defp build_period_header(periods, period_labels, account_width, period_widths) do
    start_date = periods |> List.first() |> Map.fetch!(:start_date) |> Date.to_iso8601()
    end_date = periods |> List.last() |> Map.fetch!(:end_date) |> Date.to_iso8601()
    label_line = build_period_label_line(period_labels, period_widths)
    account_pad = String.duplicate(" ", account_width)
    header_line = account_pad <> " || " <> label_line

    separator_line =
      String.duplicate("=", account_width) <>
        "++" <> String.duplicate("=", String.length(label_line))

    "Balance changes in #{start_date}..#{end_date}:\n\n" <>
      header_line <> "\n" <> separator_line <> "\n"
  end

  defp build_period_label_line(period_labels, period_widths) do
    period_labels
    |> Enum.zip(period_widths)
    |> Enum.map_join("  ", fn {label, width} -> String.pad_leading(label, width) end)
  end

  defp build_period_line(account, formatted_values, account_width, period_widths) do
    account_column = String.pad_trailing(account, account_width)

    values_line =
      formatted_values
      |> Enum.zip(period_widths)
      |> Enum.map_join("  ", fn {value, width} -> String.pad_leading(value, width) end)

    account_column <> " || " <> values_line
  end

  defp build_period_totals(period_labels, balances) do
    period_labels
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {label, idx}, acc ->
      period_balances = Map.get(balances, label, %{})
      add_period_to_totals(period_balances, acc, idx, period_labels)
    end)
  end

  defp add_period_to_totals(period_balances, acc_totals, idx, period_labels) do
    Enum.reduce(period_balances, acc_totals, fn {_account, amounts_list}, acc ->
      add_amounts_to_totals(amounts_list, acc, idx, period_labels)
    end)
  end

  defp add_amounts_to_totals(amounts_list, acc_totals, idx, period_labels) do
    Enum.reduce(amounts_list, acc_totals, fn %{amount: amount, currency: currency}, acc ->
      update_currency_total(acc, currency, amount, idx, period_labels)
    end)
  end

  defp update_currency_total(acc, currency, amount, idx, period_labels) do
    initial = List.duplicate(0.0, length(period_labels)) |> List.update_at(idx, &(&1 + amount))

    Map.update(acc, currency, initial, fn totals ->
      List.update_at(totals, idx, &(&1 + amount))
    end)
  end

  defp build_period_totals_section(totals, account_width, period_widths) do
    totals_lines =
      totals
      |> Enum.sort_by(fn {currency, _} -> currency end)
      |> Enum.map_join("\n", fn {currency, amounts} ->
        formatted = Enum.map(amounts, &format_amount_for_currency(&1, currency))
        build_period_line("", formatted, account_width, period_widths)
      end)

    separator =
      String.duplicate("-", account_width) <>
        "++" <>
        String.duplicate("-", total_period_width(period_widths))

    "\n" <> separator <> "\n" <> totals_lines <> "\n"
  end

  defp total_period_width(period_widths) do
    case period_widths do
      [] -> 0
      _ -> Enum.sum(period_widths) + (length(period_widths) - 1) * 2
    end
  end

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
    sorted_txns = transactions |> regular_transactions() |> Enum.sort_by(& &1.date, Date)

    if Enum.empty?(sorted_txns) do
      %{"periods" => [], "balances" => %{}}
    else
      do_balance_by_period(sorted_txns, group_by, start_date, end_date, account_filter)
    end
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
    case Map.get(acc, :__previous_balances__) do
      nil -> balance(period_txns)
      prev_balances -> merge_balances(prev_balances, balance(period_txns))
    end
  end

  defp maybe_filter_balances(period_balances, nil), do: period_balances

  defp maybe_filter_balances(period_balances, account_filter) do
    period_balances
    |> Enum.filter(fn {account, _balance} -> account_filter.(account) end)
    |> Map.new()
  end

  defp merge_balances(bal1, bal2) do
    Map.merge(bal1, bal2, fn _account, amounts_list1, amounts_list2 ->
      (amounts_list1 ++ amounts_list2)
      |> Enum.group_by(& &1.currency)
      |> Enum.map(fn {currency, amounts} ->
        total = amounts |> Enum.map(& &1.amount) |> Enum.sum()
        %{amount: total, currency: currency}
      end)
      |> Enum.sort_by(& &1.currency)
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
    generate_periods_by_interval(start_date, end_date, 1, &Date.to_iso8601/1)
  end

  defp generate_weekly_periods(start_date, end_date) do
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

  # ============================================================================
  # Stats, Select, and Query
  # ============================================================================

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
      unique_accounts: Declarations.list_accounts(transactions, %{}) |> length(),
      unique_payees: Declarations.list_payees(transactions) |> length(),
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
        _ -> {:ok, EntryFormatter.format_entry(transaction, date, false)}
      end
    end
  end

  defp min_max_dates([]), do: {nil, nil}
  defp min_max_dates(dates), do: {Enum.min(dates), Enum.max(dates)}

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
  defp select_value(posting, "amount"), do: posting_formatted_amount(posting)
  defp select_value(posting, "commodity"), do: posting_currency(posting)
  defp select_value(posting, "quantity"), do: Helpers.posting_amount_value(posting)
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
  defp select_filter_value(posting, "tag"), do: posting.tags |> Enum.join(",")
  defp select_filter_value(posting, "commodity"), do: posting_currency(posting)
  defp select_filter_value(_posting, _field), do: nil

  defp posting_formatted_amount(%{amount: %{value: value, currency: currency}}) do
    format_amount_for_currency(value, currency)
  end

  defp posting_formatted_amount(_posting), do: nil

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

  # ============================================================================
  # Budget and Forecast
  # ============================================================================

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

  @spec forecast_balance([transaction()], pos_integer()) :: %{String.t() => [map()]}
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
      |> Enum.flat_map(fn {account, amounts_list} ->
        Enum.map(amounts_list, fn %{amount: value, currency: currency} ->
          {{account, currency}, value}
        end)
      end)
      |> Map.new()

    current_entries
    |> Map.merge(budget_adjustments, fn _key, value, adjustment -> value + adjustment end)
    |> Enum.reduce(%{}, fn {{account, currency}, value}, acc ->
      Map.update(acc, account, [%{amount: value, currency: currency}], fn amounts_list ->
        update_or_add_currency_amount(amounts_list, currency, value)
      end)
    end)
  end

  defp update_or_add_currency_amount(amounts_list, currency, value) do
    existing_idx = Enum.find_index(amounts_list, fn a -> a.currency == currency end)

    if existing_idx do
      List.update_at(amounts_list, existing_idx, fn a -> %{a | amount: value} end)
    else
      [%{amount: value, currency: currency} | amounts_list] |> Enum.sort_by(& &1.currency)
    end
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
    if String.contains?(normalized, "bi"), do: 26.0 / 12.0, else: 52.0 / 12.0
  end

  defp monthly_multiplier(normalized) do
    if String.contains?(normalized, "bi"), do: 0.5, else: 1.0
  end
end
