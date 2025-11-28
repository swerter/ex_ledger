defmodule ExLedger.CLI do
  @moduledoc false

  @switches [file: :string, help: :boolean, strict: :boolean]
  @aliases [f: :file, h: :help]

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
      help?: opts[:help] || false,
      strict?: opts[:strict] || false
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

  defp execute(%{file: file, command: "balance", strict?: strict?}) do
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
            )},
         resolved_transactions =
           ExLedger.LedgerParser.resolve_transaction_aliases(transactions, accounts),
         {:validated, :ok} <-
           {:validated, maybe_validate_strict(resolved_transactions, accounts, strict?)} do
      resolved_transactions
      |> ExLedger.LedgerParser.balance()
      |> ExLedger.LedgerParser.format_balance()
      |> IO.write()
    else
      {:file_read, {:error, reason}} ->
        print_error("cannot read file #{file}: #{:file.format_error(reason)}")
        System.halt(1)

      {:parsed, {:error, {reason, line, source_file, import_chain}}} ->
        handle_parse_error({reason, line, source_file, import_chain}, file)

      {:parsed, {:error, {reason, line, source_file}}} ->
        handle_parse_error({reason, line, source_file}, file)

      {:parsed, {:error, reason}} ->
        handle_parse_error(reason, file)

      {:validated, {:error, {:undeclared_account, account_name}}} ->
        print_error("account '#{account_name}' is used but not declared (strict mode)")
        System.halt(1)
    end
  end

  defp execute(%{command: command}) do
    print_error("unknown command #{command}")
    print_usage()
    System.halt(64)
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
      "Usage: exledger -f <ledger_file> balance",
      "",
      "Options:",
      "  -f, --file    Path to the ledger file",
      "  -h, --help    Show this message",
      "  --strict      Require all accounts to be declared"
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

  defp format_parse_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_parse_error(reason), do: inspect(reason)

  defp handle_parse_error({reason, line, source_file, import_chain}, fallback_file) do
    import_trace =
      Enum.map_join(import_chain || [], "\n", fn {import_file, import_line} ->
        "    imported from #{format_error_location(import_file, import_line)}"
      end)

    location = format_error_location(source_file || fallback_file, line)

    error_msg =
      "failed to parse ledger file #{location}: #{format_parse_error(reason)}\n#{import_trace}"

    print_error(error_msg)
    System.halt(1)
  end

  defp handle_parse_error({reason, line, source_file}, fallback_file) do
    location = format_error_location(source_file || fallback_file, line)
    print_error("failed to parse ledger file #{location}: #{format_parse_error(reason)}")
    System.halt(1)
  end

  defp handle_parse_error(reason, fallback_file) do
    print_error(
      "failed to parse ledger file #{format_error_location(fallback_file, nil)}: #{format_parse_error(reason)}"
    )

    System.halt(1)
  end
end
