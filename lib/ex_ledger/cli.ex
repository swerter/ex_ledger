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
    file
    |> File.read()
    |> case do
      {:ok, contents} ->
        # Get the directory of the main file for resolving includes
        base_dir = Path.dirname(file)

        case ExLedger.LedgerParser.parse_ledger_with_includes(contents, base_dir) do
          {:ok, transactions, accounts} ->
            case maybe_validate_strict(transactions, accounts, strict?) do
              :ok ->
                transactions
                |> ExLedger.LedgerParser.balance()
                |> ExLedger.LedgerParser.format_balance()
                |> IO.write()

              {:error, {:undeclared_account, account_name}} ->
                print_error("account '#{account_name}' is used but not declared (strict mode)")
                System.halt(1)
            end

          {:error, {reason, line, source_file}} ->
            error_msg =
              if source_file do
                "failed to parse ledger file #{format_error_location(source_file, line)}: #{format_parse_error(reason)}"
              else
                "failed to parse ledger file #{format_error_location(file, line)}: #{format_parse_error(reason)}"
              end

            print_error(error_msg)
            System.halt(1)

          {:error, reason} ->
            print_error("failed to parse ledger file #{format_error_location(file, nil)}: #{format_parse_error(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        print_error("cannot read file #{file}: #{:file.format_error(reason)}")
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

    # Get all declared account names
    declared_accounts = Map.keys(accounts)

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
  defp format_parse_error({:include_not_found, filename}), do: "include file not found: #{filename}"
  defp format_parse_error({:circular_include, filename}), do: "circular include detected: #{filename}"
  defp format_parse_error({:file_read_error, filename, reason}), do: "cannot read include file #{filename}: #{:file.format_error(reason)}"
  defp format_parse_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_parse_error(reason), do: inspect(reason)
end
