defmodule ExLedger.CLI do
  @moduledoc false

  alias ExLedger.LedgerParser

  @switches [file: :string, help: :boolean, strict: :boolean, empty: :boolean]
  @aliases [f: :file, h: :help, E: :empty]

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
    print_error("missing required option `-f/--file`")
    print_usage()
    System.halt(64)
  end

  defp execute(%{file: file, command: "balance", strict?: strict?, empty?: empty?}) do
    with_parsed(file, fn transactions, accounts ->
      resolved_transactions =
        ExLedger.LedgerParser.resolve_transaction_aliases(transactions, accounts)

      case maybe_validate_strict(resolved_transactions, accounts, strict?) do
        :ok ->
          resolved_transactions
          |> ExLedger.LedgerParser.balance()
          |> ExLedger.LedgerParser.format_balance(empty?)
          |> IO.write()

        {:error, {:undeclared_account, account_name}} ->
          print_error("account '#{account_name}' is used but not declared (strict mode)")
          System.halt(1)
      end
    end)
  end

  defp execute(%{file: file, command: "accounts", command_args: args}) do
    with_parsed(file, fn transactions, accounts ->
      resolved_transactions =
        ExLedger.LedgerParser.resolve_transaction_aliases(transactions, accounts)

      accounts_list = ExLedger.LedgerParser.list_accounts(resolved_transactions, accounts)

      accounts_list
      |> filter_list(first_arg(args))
      |> Enum.join("\n")
      |> Kernel.<>("\n")
      |> IO.write()
    end)
  end

  defp execute(%{file: file, command: "payees", command_args: args}) do
    with_parsed(file, fn transactions, _accounts ->
      payees = ExLedger.LedgerParser.list_payees(transactions)

      payees
      |> filter_list(first_arg(args))
      |> Enum.join("\n")
      |> Kernel.<>("\n")
      |> IO.write()
    end)
  end

  defp execute(%{file: file, command: "commodities", command_args: args}) do
    with_parsed(file, fn transactions, _accounts ->
      commodities = ExLedger.LedgerParser.list_commodities(transactions)

      commodities
      |> filter_list(first_arg(args))
      |> Enum.join("\n")
      |> Kernel.<>("\n")
      |> IO.write()
    end)
  end

  defp execute(%{file: file, command: "tags", command_args: args}) do
    with_parsed(file, fn transactions, _accounts ->
      tags = ExLedger.LedgerParser.list_tags(transactions)

      tags
      |> filter_list(first_arg(args))
      |> Enum.join("\n")
      |> Kernel.<>("\n")
      |> IO.write()
    end)
  end

  defp execute(%{file: file, command: "stats"}) do
    with_parsed(file, fn transactions, _accounts ->
      transactions
      |> ExLedger.LedgerParser.stats()
      |> ExLedger.LedgerParser.format_stats()
      |> IO.write()
    end)
  end

  defp execute(%{file: file, command: "select", command_args: args}) do
    query = Enum.join(args, " ")

    if query == "" do
      print_error("select requires a query")
      System.halt(64)
    end

    with_parsed(file, fn transactions, _accounts ->
      case ExLedger.LedgerParser.select(transactions, query) do
        {:ok, fields, rows} ->
          ExLedger.LedgerParser.format_select(fields, rows)
          |> IO.write()

        {:error, reason} ->
          print_error("invalid select query: #{reason}")
          System.halt(64)
      end
    end)
  end

  defp execute(%{file: file, command: "xact", command_args: args}) do
    case args do
      [date_string, payee_pattern] ->
        with_parsed(file, fn transactions, _accounts ->
          with {:ok, date} <- LedgerParser.parse_date(date_string),
               {:ok, output} <- LedgerParser.build_xact(transactions, date, payee_pattern) do
            IO.write(output)
          else
            {:error, :invalid_date_format} ->
              print_error("invalid date format for xact")
              System.halt(64)

            {:error, :xact_not_found} ->
              print_error("no transaction matches xact pattern")
              System.halt(1)
          end
        end)

      _ ->
        print_error("xact requires DATE and PAYEE_PATTERN")
        System.halt(64)
    end
  end

  defp execute(%{command: command}) do
    print_error("unknown command #{command}")
    print_usage()
    System.halt(64)
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
      fun.(transactions, accounts)
    else
      {:file_read, {:error, reason}} ->
        print_error("cannot read file #{file}: #{:file.format_error(reason)}")
        System.halt(1)

      {:parsed, {:error, error}} ->
        handle_parse_error(error, file)
    end
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
      "  xact DATE REGEX    Generate a transaction template",
      "  select QUERY       Run a simple select query"
    ]
    |> Enum.join("\n")
    |> IO.puts()
  end

  defp print_error(message) do
    IO.puts(:stderr, "exledger: #{message}")
  end

  defp format_error_location(file, nil), do: file
  defp format_error_location(file, line), do: "#{file}:#{line}"

  defp format_parse_error({:unexpected_input, rest}), do: "unexpected input #{inspect(rest)}"

  defp format_parse_error({:include_not_found, filename}),
    do: "include file not found: #{filename}"

  defp format_parse_error({:circular_include, filename}),
    do: "circular include detected: #{filename}"

  defp format_parse_error(:multi_currency_missing_amount),
    do: "cannot auto-balance multi-currency transaction with missing amount"

  defp format_parse_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_parse_error(reason), do: inspect(reason)

  defp first_arg([arg | _]), do: arg
  defp first_arg(_), do: nil

  defp filter_list(items, nil), do: items

  defp filter_list(items, pattern) do
    with {:ok, regex} <- Regex.compile(pattern) do
      Enum.filter(items, fn item -> Regex.match?(regex, item) end)
    else
      _ -> items
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

    print_error(error_msg)
    System.halt(1)
  end

  defp handle_parse_error(error, fallback_file) do
    print_error(
      "failed to parse ledger file #{format_error_location(fallback_file, nil)}: #{format_parse_error(error)}"
    )

    System.halt(1)
  end
end
