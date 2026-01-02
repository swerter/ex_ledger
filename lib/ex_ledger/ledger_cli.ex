defmodule ExLedger.LedgerCLI do
  @moduledoc """
  Wrapper for calling the external `ledger` CLI binary.
  """

  @default_ledger_bin "ledger"

  @type cmd_error :: {non_neg_integer(), String.t()}

  @doc """
  Runs the `ledger` CLI with the given arguments.

  Returns `{:ok, output}` on success or `{:error, {status, output}}` on failure.
  """
  @spec run([String.t()], keyword()) :: {:ok, String.t()} | {:error, cmd_error()}
  def run(args, opts \\ []) when is_list(args) and is_list(opts) do
    ledger_bin = Keyword.get(opts, :ledger_bin, @default_ledger_bin)
    cmd_opts = build_cmd_opts(opts)

    ledger_bin
    |> System.cmd(args, cmd_opts)
    |> format_cmd_result()
  end

  @doc """
  Runs the `ledger` CLI for a specific ledger file and command.

  Example:

      ExLedger.LedgerCLI.run_with_file("/tmp/ledger.dat", "balance", ["Assets"])
  """
  @spec run_with_file(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, cmd_error()}
  def run_with_file(file, command, args \\ [], opts \\ [])
      when is_binary(file) and is_binary(command) and is_list(args) and is_list(opts) do
    run(["-f", file, command | args], opts)
  end

  defp build_cmd_opts(opts) do
    Keyword.merge([stderr_to_stdout: true], Keyword.get(opts, :cmd_opts, []))
  end

  defp format_cmd_result({output, 0}), do: {:ok, output}
  defp format_cmd_result({output, status}), do: {:error, {status, output}}
end
