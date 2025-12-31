defmodule ExLedger.CLI do
  @moduledoc false

  alias ExLedger.LedgerParser

  @switches [file: :string, help: :boolean, strict: :boolean, empty: :boolean]
  @aliases [f: :file, h: :help, E: :empty]
  @max_regex_length 256

  defp list_command_fns do
    %{
      "accounts" => fn transactions, accounts ->
        transactions
        |> LedgerParser.resolve_transaction_aliases(accounts)
        |> LedgerParser.list_accounts(accounts)
      end,
      "payees" => fn transactions, _accounts -> LedgerParser.list_payees(transactions) end,
      "commodities" => fn transactions, _accounts -> LedgerParser.list_commodities(transactions) end,
      "tags" => fn transactions, _accounts -> LedgerParser.list_tags(transactions) end
    }
  end

  defp command_handlers do
    %{
      "balance" => &handle_balance/1,
      "accounts" => &handle_list_command/1,
      "payees" => &handle_list_command/1,
      "commodities" => &handle_list_command/1,
      "tags" => &handle_list_command/1,
      "stats" => &handle_stats/1,
      "budget" => &handle_budget/1,
      "forecast" => &handle_forecast/1,
      "timeclock" => &handle_timeclock/1,
      "select" => &handle_select/1,
      "xact" => &handle_xact/1
    }
  end

  @doc """
  Entry point for the CLI. Accepts arguments like `-f ledger.dat balance`.
  """
  @spec main([String.t()]) :: :ok
  def main(argv) do
    argv
    |> parse_args()
    |> execute()
  end

  defp parse_args(argv) do
    {opts, commands, _} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    %{
      file: opts[:file],
      command: List.first(commands) || "balance",
      command_args: Enum.drop(commands, 1),
      help?: opts[:help] || false,
      strict?: opts[:strict] || false,
      empty?: opts[:empty] || false
    }
  end

  defp execute(%{help?: true}) do
    print_usage()
  end

  defp execute(%{file: nil}) do
    usage_error("missing required option `-f/--file`")
  end

  defp execute(%{command: command} = opts) do
    case Map.get(command_handlers(), command) do
      nil ->
        usage_error("unknown command #{command}")

      handler ->
        handler.(opts)
    end
  end

  defp handle_balance(%{file: file, strict?: strict?, empty?: empty?}) do
    with_parsed(file, fn transactions, accounts, _contents ->
      resolved_transactions =
        ExLedger.LedgerParser.resolve_transaction_aliases(transactions, accounts)

      case maybe_validate_strict(resolved_transactions, accounts, strict?) do
        :ok ->
          resolved_transactions
          |> ExLedger.LedgerParser.balance()
          |> ExLedger.LedgerParser.format_balance(empty?)
          |> IO.write()

        {:error, {:undeclared_account, account_name}} ->
          halt_error("account '#{account_name}' is used but not declared (strict mode)", 1)
      end
    end)
  end

  defp handle_list_command(%{file: file, command: command, command_args: args}) do
    list_fun = Map.fetch!(list_command_fns(), command)

    run_list_command(file, args, list_fun)
  end

  defp handle_stats(%{file: file}) do
    with_transactions(file, fn transactions ->
      transactions
      |> ExLedger.LedgerParser.stats()
      |> ExLedger.LedgerParser.format_stats()
      |> IO.write()
    end)
  end

  defp handle_budget(%{file: file}) do
    with_transactions(file, fn transactions ->
      transactions
      |> ExLedger.LedgerParser.budget_report()
      |> ExLedger.LedgerParser.format_budget_report()
      |> IO.write()
    end)
  end

  defp handle_forecast(%{file: file, command_args: args}) do
    months =
      case args do
        [value] -> parse_positive_integer(value, 1)
        _ -> 1
      end

    with_transactions(file, fn transactions ->
      transactions
      |> ExLedger.LedgerParser.forecast_balance(months)
      |> ExLedger.LedgerParser.format_balance()
      |> IO.write()
    end)
  end

  defp handle_timeclock(%{file: file}) do
    with_parsed(file, fn _transactions, _accounts, contents ->
      base_dir = Path.dirname(file)
      filename = Path.basename(file)

      case ExLedger.LedgerParser.expand_includes(contents, base_dir, MapSet.new(), filename) do
        {:ok, expanded_contents} ->
          expanded_contents
          |> ExLedger.LedgerParser.parse_timeclock_entries()
          |> ExLedger.LedgerParser.timeclock_report()
          |> ExLedger.LedgerParser.format_timeclock_report()
          |> IO.write()

        {:error, error} ->
          handle_parse_error(error, file)
      end
    end)
  end

  defp handle_select(%{file: file, command_args: args}) do
    query = Enum.join(args, " ")

    if query == "" do
      halt_error("select requires a query", 64)
    end

    with_transactions(file, fn transactions ->
      case ExLedger.LedgerParser.select(transactions, query) do
        {:ok, fields, rows} ->
          ExLedger.LedgerParser.format_select(fields, rows)
          |> IO.write()

        {:error, reason} ->
          halt_error("invalid select query: #{reason}", 64)
      end
    end)
  end

  defp handle_xact(%{file: file, command_args: args}) do
    case args do
      [date_string, payee_pattern] ->
        with_parsed(file, fn transactions, _accounts, _contents ->
          with {:ok, date} <- LedgerParser.parse_date(date_string),
               {:ok, output} <- LedgerParser.build_xact(transactions, date, payee_pattern) do
            IO.write(output)
          else
            {:error, :invalid_date_format} ->
              halt_error("invalid date format for xact", 64)

            {:error, :xact_not_found} ->
              halt_error("no transaction matches xact pattern", 1)
          end
        end)

      _ ->
        halt_error("xact requires DATE and PAYEE_PATTERN", 64)
    end
  end

  defp run_list_command(file, args, list_fun) do
    with_parsed(file, fn transactions, accounts, _contents ->
      items = list_fun.(transactions, accounts)

      items
      |> filter_list(first_arg(args))
      |> Enum.join("\n")
      |> Kernel.<>("\n")
      |> IO.write()
    end)
  end

  defp with_parsed(file, fun) do
    base_dir = Path.dirname(file)
    filename = Path.basename(file)

    with {:file_read, {:ok, contents}} <- {:file_read, File.read(file)},
         {:parsed, {:ok, transactions, accounts}} <-
           {:parsed,
            ExLedger.LedgerParser.parse_ledger_with_includes(
              contents,
              base_dir,
              MapSet.new(),
              filename
            )} do
      fun.(transactions, accounts, contents)
    else
      {:file_read, {:error, reason}} ->
        halt_error("cannot read file #{file}: #{:file.format_error(reason)}", 1)

      {:parsed, {:error, error}} ->
        handle_parse_error(error, file)
    end
  end

  defp with_transactions(file, fun) do
    with_parsed(file, fn transactions, _accounts, _contents -> fun.(transactions) end)
  end

  defp maybe_validate_strict(_transactions, _accounts, false), do: :ok

  defp maybe_validate_strict(transactions, accounts, true) do
    # Get all account names used in transactions
    used_accounts =
      transactions
      |> Enum.flat_map(fn transaction ->
        Enum.map(transaction.postings, & &1.account)
      end)
      |> Enum.uniq()

    # Get all declared main account names (filter out aliases which have string values)
    declared_accounts =
      accounts
      |> Enum.filter(fn {_name, value} -> is_atom(value) end)
      |> Enum.map(fn {name, _type} -> name end)

    # Find any undeclared accounts
    case Enum.find(used_accounts, fn account ->
           account not in declared_accounts
         end) do
      nil -> :ok
      undeclared -> {:error, {:undeclared_account, undeclared}}
    end
  end

  defp print_usage do
    [
      "Usage: exledger -f <ledger_file> <command> [args]",
      "",
      "Options:",
      "  -f, --file    Path to the ledger file",
      "  -h, --help    Show this message",
      "  -E, --empty   Show accounts whose total is zero",
      "  --strict      Require all accounts to be declared",
      "",
      "Commands:",
      "  balance            Show account balances",
      "  accounts [REGEX]   List accounts",
      "  payees [REGEX]     List payees",
      "  commodities [REGEX] List commodities",
      "  tags [REGEX]       List tags",
      "  stats              Show journal stats",
      "  budget             Show monthly budget vs actual",
      "  forecast [MONTHS]  Forecast balances using budget",
      "  timeclock          Show timeclock totals",
      "  xact DATE REGEX    Generate a transaction template",
      "  select QUERY       Run a simple select query"
    ]
    |> Enum.join("\n")
    |> IO.puts()
  end

  defp print_error(message) do
    IO.puts(:stderr, "exledger: #{message}")
  end

  defp halt_error(message, code) do
    print_error(message)
    System.halt(code)
  end

  defp usage_error(message) do
    print_error(message)
    print_usage()
    System.halt(64)
  end

  defp format_error_location(file, nil), do: file
  defp format_error_location(file, line), do: "#{file}:#{line}"

  defp format_parse_error({:unexpected_input, rest}), do: "unexpected input #{inspect(rest)}"

  defp format_parse_error({:include_not_found, filename}),
    do: "include file not found: #{filename}"

  defp format_parse_error({:circular_include, filename}),
    do: "circular include detected: #{filename}"

  defp format_parse_error({:include_outside_base, filename}),
    do: "include path escapes base directory: #{filename}"

  defp format_parse_error(:multi_currency_missing_amount),
    do: "cannot auto-balance multi-currency transaction with missing amount"

  defp format_parse_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_parse_error(reason), do: inspect(reason)

  defp parse_positive_integer(value, fallback) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> fallback
    end
  end

  defp first_arg([arg | _]), do: arg
  defp first_arg(_), do: nil

  defp filter_list(items, nil), do: items

  defp filter_list(items, pattern) do
    with {:ok, regex} <- compile_regex(pattern) do
      Enum.filter(items, fn item -> Regex.match?(regex, item) end)
    else
      _ -> items
    end
  end

  defp compile_regex(pattern) do
    if String.length(pattern) > @max_regex_length do
      {:error, :invalid_regex}
    else
      Regex.compile(pattern)
    end
  end

  @spec handle_parse_error(LedgerParser.ledger_error(), String.t()) :: no_return()
  defp handle_parse_error(%{reason: reason, line: line, file: source_file, import_chain: import_chain}, fallback_file) do
    import_trace =
      if import_chain do
        Enum.map_join(import_chain, "\n", fn {import_file, import_line} ->
          "    imported from #{format_error_location(import_file, import_line)}"
        end)
      else
        ""
      end

    location = format_error_location(source_file || fallback_file, line)

    error_msg =
      if import_trace != "" do
        "failed to parse ledger file #{location}: #{format_parse_error(reason)}\n#{import_trace}"
      else
        "failed to parse ledger file #{location}: #{format_parse_error(reason)}"
      end

    halt_error(error_msg, 1)
  end

  defp handle_parse_error(error, fallback_file) do
    halt_error(
      "failed to parse ledger file #{format_error_location(fallback_file, nil)}: #{format_parse_error(error)}",
      1
    )
  end
end
