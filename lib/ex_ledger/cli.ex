defmodule ExLedger.CLI do
  @moduledoc false

  alias ExLedger.LedgerParser

  @switches [
    file: :string,
    help: :boolean,
    strict: :boolean,
    empty: :boolean,
    basis: :boolean,
    flat: :boolean,
    no_total: :boolean,
    yearly: :boolean
  ]
  @aliases [f: :file, h: :help, E: :empty, s: :strict, B: :basis, Y: :yearly]
  @max_regex_length 256

  defp list_command_fns do
    %{
      "accounts" => fn transactions, accounts ->
        LedgerParser.list_accounts(transactions, accounts)
      end,
      "payees" => fn transactions, _accounts -> LedgerParser.list_payees(transactions) end,
      "commodities" => fn transactions, _accounts ->
        LedgerParser.list_commodities(transactions)
      end,
      "tags" => fn transactions, _accounts -> LedgerParser.list_tags(transactions) end
    }
  end

  defp command_handlers do
    %{
      "balance" => &handle_balance/1,
      "bal" => &handle_balance/1,
      "b" => &handle_balance/1,
      "register" => &handle_register/1,
      "print" => &handle_print/1,
      "check" => &handle_check/1,
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
      empty?: opts[:empty] || false,
      basis?: opts[:basis] || false,
      flat?: opts[:flat] || false,
      no_total?: opts[:no_total] || false,
      yearly?: opts[:yearly] || false
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

  defp handle_balance(%{file: file, strict?: strict?, empty?: empty?, yearly?: yearly?} = opts) do
    report_query = first_arg(opts.command_args)
    report_regex = compile_filter_regex(report_query)
    flat = opts.flat? && not opts.basis?

    if yearly? do
      run_yearly_balance(file, report_regex, strict?, empty?, opts.no_total?)
    else
      format_opts = [
        show_empty: empty?,
        flat: flat,
        show_total: not opts.no_total?,
        top_level_only: opts.basis?
      ]

      with_resolved_transactions(file, fn resolved_transactions, accounts, _contents ->
        case maybe_validate_strict(resolved_transactions, accounts, strict?) do
          :ok ->
            resolved_transactions
            |> LedgerParser.balance_report(report_regex, format_opts)
            |> IO.write()

          {:error, {:undeclared_account, account_name}} ->
            halt_error("account '#{account_name}' is used but not declared (strict mode)", 1)
        end
      end)
    end
  end

  defp run_yearly_balance(file, report_regex, strict?, empty?, no_total?) do
    format_opts = [show_empty: empty?, show_total: not no_total?]

    account_filter =
      if report_regex do
        fn account -> Regex.match?(report_regex, account) end
      else
        nil
      end

    with_resolved_transactions(file, fn resolved_transactions, accounts, _contents ->
      case maybe_validate_strict(resolved_transactions, accounts, strict?) do
        :ok ->
          resolved_transactions
          |> LedgerParser.balance_by_period("yearly", nil, nil, account_filter)
          |> LedgerParser.format_balance_by_period(format_opts)
          |> IO.write()

        {:error, {:undeclared_account, account_name}} ->
          halt_error("account '#{account_name}' is used but not declared (strict mode)", 1)
      end
    end)
  end

  defp handle_register(%{file: file, command_args: args}) do
    account_pattern = first_arg(args)

    with_resolved_transactions(file, fn resolved_transactions, _accounts, _contents ->
      regex = compile_filter_regex(account_pattern)

      resolved_transactions
      |> LedgerParser.register(regex)
      |> LedgerParser.format_account_register(account_pattern || "")
      |> IO.write()
    end)
  end

  defp handle_print(%{file: file}) do
    with_resolved_transactions(file, fn resolved_transactions, _accounts, _contents ->
      resolved_transactions
      |> LedgerParser.format_transactions()
      |> IO.write()
    end)
  end

  defp handle_check(%{file: file, command_args: args}) do
    base_dir = Path.dirname(file)
    filename = Path.basename(file)

    with_resolved_transactions(file, fn resolved_transactions, accounts, contents ->
      run_checks(resolved_transactions, accounts, contents, base_dir, filename, args, file)
    end)
  end

  defp run_checks(resolved_transactions, accounts, contents, base_dir, filename, args, file) do
    case LedgerParser.expand_includes(contents, base_dir, MapSet.new(), filename) do
      {:ok, expanded_contents} ->
        declared_payees = LedgerParser.extract_payee_declarations(expanded_contents)
        declared_commodities = LedgerParser.extract_commodity_declarations(expanded_contents)
        declared_tags = LedgerParser.extract_tag_declarations(expanded_contents)
        check_targets = normalize_check_targets(args)

        run_check_targets(
          check_targets,
          resolved_transactions,
          accounts,
          expanded_contents,
          declared_payees,
          declared_commodities,
          declared_tags
        )

      {:error, error} ->
        handle_parse_error(error, file)
    end
  end

  defp run_check_targets(
         check_targets,
         resolved_transactions,
         accounts,
         expanded_contents,
         declared_payees,
         declared_commodities,
         declared_tags
       ) do
    Enum.reduce_while(check_targets, :ok, fn target, :ok ->
      case run_check(
             target,
             resolved_transactions,
             accounts,
             expanded_contents,
             declared_payees,
             declared_commodities,
             declared_tags
           ) do
        :ok ->
          {:cont, :ok}

        {:error, {message, status}} ->
          halt_error(message, status)
      end
    end)
  end

  defp handle_list_command(%{file: file, command: command, command_args: args}) do
    list_fun = Map.fetch!(list_command_fns(), command)

    run_list_command(file, args, list_fun)
  end

  defp handle_stats(%{file: file}) do
    with_resolved_transactions(file, fn resolved_transactions, _accounts, _contents ->
      resolved_transactions
      |> LedgerParser.stats()
      |> LedgerParser.format_stats()
      |> IO.write()
    end)
  end

  defp handle_budget(%{file: file}) do
    with_resolved_transactions(file, fn resolved_transactions, _accounts, _contents ->
      resolved_transactions
      |> LedgerParser.budget_report()
      |> LedgerParser.format_budget_report()
      |> IO.write()
    end)
  end

  defp handle_forecast(%{file: file, command_args: args, empty?: empty?}) do
    months =
      case args do
        [value] -> parse_positive_integer(value, 1)
        _ -> 1
      end

    with_resolved_transactions(file, fn resolved_transactions, _accounts, _contents ->
      resolved_transactions
      |> LedgerParser.forecast_balance(months)
      |> LedgerParser.format_balance(empty?)
      |> IO.write()
    end)
  end

  defp handle_timeclock(%{file: file}) do
    with_parsed(file, fn _transactions, _accounts, contents ->
      base_dir = Path.dirname(file)
      filename = Path.basename(file)

      case LedgerParser.expand_includes(contents, base_dir, MapSet.new(), filename) do
        {:ok, expanded_contents} ->
          expanded_contents
          |> LedgerParser.parse_timeclock_entries()
          |> LedgerParser.timeclock_report()
          |> LedgerParser.format_timeclock_report()
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

    with_resolved_transactions(file, fn resolved_transactions, _accounts, _contents ->
      case LedgerParser.select(resolved_transactions, query) do
        {:ok, fields, rows} ->
          LedgerParser.format_select(fields, rows)
          |> IO.write()

        {:error, reason} ->
          halt_error("invalid select query: #{reason}", 64)
      end
    end)
  end

  defp handle_xact(%{file: file, command_args: args}) do
    case args do
      [date_string, payee_pattern] ->
        with_resolved_transactions(file, fn resolved_transactions, _accounts, _contents ->
          with {:ok, date} <- LedgerParser.parse_date(date_string),
               {:ok, output} <-
                 LedgerParser.build_xact(resolved_transactions, date, payee_pattern) do
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
    with_resolved_transactions(file, fn resolved_transactions, accounts, _contents ->
      items = list_fun.(resolved_transactions, accounts)

      items
      |> filter_list(first_arg(args))
      |> Enum.join("\n")
      |> Kernel.<>("\n")
      |> IO.write()
    end)
  end

  defp resolve_transactions(transactions, accounts) do
    LedgerParser.resolve_transaction_aliases(transactions, accounts)
  end

  defp with_resolved_transactions(file, fun) do
    with_parsed(file, fn transactions, accounts, contents ->
      fun.(resolve_transactions(transactions, accounts), accounts, contents)
    end)
  end

  defp with_parsed(file, fun) do
    base_dir = Path.dirname(file)
    filename = Path.basename(file)

    with {:file_read, {:ok, contents}} <- {:file_read, File.read(file)},
         {:parsed, {:ok, transactions, accounts}} <-
           {:parsed,
            LedgerParser.parse_ledger_with_includes(
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

  defp maybe_validate_strict(_transactions, _accounts, false), do: :ok

  defp maybe_validate_strict(transactions, accounts, true) do
    # Get all account names used in transactions
    used_accounts =
      transactions
      |> LedgerParser.list_accounts()

    # Get all declared main account names (filter out aliases which have string values)
    declared_accounts =
      accounts
      |> Enum.filter(fn {_name, value} -> is_atom(value) end)
      |> Enum.map(fn {name, _type} -> name end)

    declared_set = MapSet.new(declared_accounts)

    # Find any undeclared accounts
    case Enum.find(used_accounts, fn account ->
           not MapSet.member?(declared_set, account)
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
      "  -B, --basis   Report in terms of cost basis",
      "  -Y, --yearly  Group balance report by year",
      "  -E, --empty   Show accounts whose total is zero",
      "      --flat    Flatten the balance report",
      "      --no-total Suppress summary totals",
      "  -s, --strict  Require all accounts to be declared",
      "",
      "Commands:",
      "  balance [QUERY]    Show account balances",
      "  bal, b             Synonyms for balance",
      "  register [REGEX]   Show postings by account",
      "  print              Print ledger transactions",
      "  check [TARGET]     Validate declarations (accounts, payees, commodities, tags)",
      "  accounts [REGEX]   List accounts",
      "  payees [REGEX]     List payees",
      "  commodities [REGEX] List commodities",
      "  tags [REGEX]       List tags",
      "  stats              Show journal stats",
      "  budget             Show monthly budget vs actual",
      "  forecast [MONTHS]  Forecast balances using budget",
      "  timeclock          Show timeclock totals",
      "  xact DATE REGEX    Generate a transaction template",
      "  select QUERY       Run a simple select query",
      "",
      "balance [report-query]",
      "    Print a balance report showing totals for postings that match",
      "    report-query, and aggregate totals for parents of those accounts.",
      "    Options most commonly used with this command are:",
      "    --basis (-B)     Report in terms of cost basis, not amount or value.",
      "                    Only show totals for the top-most accounts.",
      "    --empty (-E)     Show accounts whose total is zero.",
      "    --flat           Flatten the report to show subtotals for only",
      "                    accounts matching report-query.",
      "    --no-total       Suppress the summary total shown at the bottom",
      "                    of the report.",
      "    --yearly (-Y)    Group balances by year.",
      "",
      "    The synonyms bal and b are also accepted."
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
    case compile_regex(pattern) do
      {:ok, regex} ->
        Enum.filter(items, fn item -> Regex.match?(regex, item) end)

      {:error, :invalid_regex} ->
        IO.puts(:stderr, "Error: regex pattern is too long (max #{@max_regex_length} characters)")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Error: invalid regex pattern '#{pattern}': #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp compile_regex(pattern) do
    if String.length(pattern) > @max_regex_length do
      {:error, :invalid_regex}
    else
      Regex.compile(pattern)
    end
  end

  defp compile_filter_regex(nil), do: nil

  defp compile_filter_regex(pattern) do
    case compile_regex(pattern) do
      {:ok, regex} ->
        regex

      {:error, :invalid_regex} ->
        IO.puts(:stderr, "Error: regex pattern is too long (max #{@max_regex_length} characters)")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Error: invalid regex pattern '#{pattern}': #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp normalize_check_targets([]), do: [:commodities, :accounts, :payees, :tags]

  defp normalize_check_targets([target]) do
    [normalize_check_target(target)]
  end

  defp normalize_check_targets(_targets) do
    usage_error("check accepts at most one subcommand")
  end

  defp normalize_check_target("accounts"), do: :accounts
  defp normalize_check_target("payees"), do: :payees
  defp normalize_check_target("commodities"), do: :commodities
  defp normalize_check_target("tags"), do: :tags
  defp normalize_check_target(target), do: usage_error("unknown check target #{target}")

  defp run_check(:accounts, transactions, accounts, _contents, _payees, _commodities, _tags) do
    case LedgerParser.check_accounts(transactions, accounts) do
      :ok -> :ok
      {:error, account} -> {:error, {"account \"#{account}\" has not been declared", 1}}
    end
  end

  defp run_check(
         :payees,
         transactions,
         _accounts,
         _contents,
         declared_payees,
         _commodities,
         _tags
       ) do
    case LedgerParser.check_payees(transactions, declared_payees) do
      :ok -> :ok
      {:error, payee} -> {:error, {"payee \"#{payee}\" has not been declared", 1}}
    end
  end

  defp run_check(
         :commodities,
         transactions,
         _accounts,
         _contents,
         _payees,
         declared_commodities,
         _tags
       ) do
    case LedgerParser.check_commodities(transactions, declared_commodities) do
      :ok -> :ok
      {:error, commodity} -> {:error, {"commodity \"#{commodity}\" has not been declared", 1}}
    end
  end

  defp run_check(:tags, transactions, _accounts, contents, _payees, _commodities, declared_tags) do
    case LedgerParser.check_tags(transactions, contents, declared_tags) do
      :ok -> :ok
      {:error, tag} -> {:error, {"tag \"#{tag}\" has not been declared", 1}}
    end
  end

  @spec handle_parse_error(LedgerParser.ledger_error(), String.t()) :: no_return()
  defp handle_parse_error(
         %{reason: reason, line: line, file: source_file, import_chain: import_chain},
         fallback_file
       ) do
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
