defmodule ExLedger.Parser.Accounts do
  @moduledoc """
  Account declaration parsing and alias resolution.
  """

  alias ExLedger.Parser.Core

  @doc """
  Extracts account declarations from ledger input.

  Returns a map where:
  - Keys are account names, values are atoms (:asset, :expense, etc.) for declared accounts
  - Keys are alias names, values are strings (target account) for aliases
  """
  @spec extract_account_declarations(String.t()) :: %{String.t() => atom() | String.t()}
  def extract_account_declarations(input) when is_binary(input) do
    input
    |> String.split("\n")
    |> parse_account_blocks([])
    |> build_account_map()
    |> expand_account_aliases()
  end

  @doc """
  Parses an account declaration line.
  """
  @spec parse_account_declaration(String.t()) ::
          {:ok, Core.account_declaration()}
          | {:error, :invalid_account_declaration | :invalid_account_type}
  def parse_account_declaration(input) when is_binary(input) do
    case Core.account_declaration_parser(input) do
      {:ok, [result], "", _, _, _} ->
        {:ok, result}

      {:ok, _, _rest, _, _, _} ->
        {:error, :invalid_account_declaration}

      {:error, _reason, _rest, _context, _line, _column} ->
        {:error, :invalid_account_declaration}
    end
  end

  @doc """
  Resolves an account name or alias to the canonical account name.
  """
  @spec resolve_account_name(String.t(), %{String.t() => atom() | String.t()}) :: String.t()
  def resolve_account_name(account_name, account_map) do
    case Map.get(account_map, account_name) do
      target when is_binary(target) -> target
      _ -> account_name
    end
  end

  @doc """
  Resolves all account names in transactions from aliases to canonical names.
  """
  @spec resolve_transaction_aliases([Core.transaction()], %{String.t() => atom() | String.t()}) ::
          [Core.transaction()]
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

  # Private functions

  @spec parse_account_blocks([String.t()], [map()]) :: [map()]
  defp parse_account_blocks([], acc), do: Enum.reverse(acc)

  defp parse_account_blocks([line | rest], acc) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "alias ") ->
        parse_account_blocks(rest, maybe_prepend_account(acc, standalone_alias_entry(trimmed)))

      old_account_format_line?(trimmed, line) ->
        parse_account_blocks(rest, maybe_prepend_account(acc, old_account_entry(line)))

      String.starts_with?(trimmed, "account ") ->
        {account_lines, remaining} = collect_account_block([line | rest])
        account = parse_account_block(account_lines)
        parse_account_blocks(remaining, [account | acc])

      true ->
        parse_account_blocks(rest, acc)
    end
  end

  defp old_account_format_line?(trimmed, line) do
    String.starts_with?(trimmed, "account ") and String.contains?(line, ";")
  end

  defp standalone_alias_entry(trimmed) do
    case parse_standalone_alias(trimmed) do
      {:ok, alias_name, account_name} ->
        %{
          name: alias_name,
          type: :alias,
          aliases: [],
          assertions: [],
          target: account_name
        }

      {:error, _} ->
        nil
    end
  end

  defp old_account_entry(line) do
    case parse_account_declaration(line) do
      {:ok, account} -> Map.merge(account, %{aliases: [], assertions: []})
      {:error, _} -> nil
    end
  end

  defp maybe_prepend_account(acc, nil), do: acc
  defp maybe_prepend_account(acc, entry), do: [entry | acc]

  @spec parse_standalone_alias(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :invalid_alias}
  defp parse_standalone_alias(line) do
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
        trimmed = String.trim(line)
        trimmed == "" or (String.starts_with?(line, " ") or String.starts_with?(line, "\t"))
      end)

    {[first_line | block_lines], remaining}
  end

  @spec parse_account_block([String.t()]) :: map()
  defp parse_account_block([first_line | rest]) do
    account_name =
      first_line
      |> String.trim_leading("account")
      |> String.trim()

    {aliases, assertions} = Enum.reduce(rest, {[], []}, &parse_account_block_line/2)

    %{
      name: account_name,
      type: :asset,
      aliases: Enum.reverse(aliases),
      assertions: Enum.reverse(assertions)
    }
  end

  defp parse_account_block_line(line, {aliases, assertions}) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {aliases, assertions}

      String.starts_with?(trimmed, "alias ") ->
        alias_name = String.trim_leading(trimmed, "alias") |> String.trim()
        {[alias_name | aliases], assertions}

      String.starts_with?(trimmed, "assert ") ->
        assertion = String.trim_leading(trimmed, "assert") |> String.trim()
        {aliases, [assertion | assertions]}

      true ->
        {aliases, assertions}
    end
  end

  @spec build_account_map([map()]) :: %{String.t() => atom() | String.t()}
  defp build_account_map(account_declarations) do
    Enum.reduce(account_declarations, %{}, &add_account_to_map/2)
  end

  defp add_account_to_map(%{type: :alias} = account, acc), do: add_standalone_alias(account, acc)
  defp add_account_to_map(account, acc), do: add_account_with_aliases(account, acc)

  defp add_standalone_alias(account, acc) do
    Map.put(acc, account.name, account.target)
  end

  defp add_account_with_aliases(account, acc) do
    acc = Map.put(acc, account.name, account.type)

    Enum.reduce(account.aliases, acc, fn alias_name, acc_inner ->
      Map.put(acc_inner, alias_name, account.name)
    end)
  end

  defp expand_account_aliases(accounts) do
    Enum.reduce(accounts, accounts, fn {name, value}, acc ->
      case value do
        target when is_binary(target) ->
          resolved_target = resolve_alias_target(target, accounts, MapSet.new([name]))
          Map.put(acc, name, resolved_target)

        _ ->
          acc
      end
    end)
  end

  defp resolve_alias_target(target, accounts, seen) do
    if MapSet.member?(seen, target) do
      target
    else
      case Map.get(accounts, target) do
        next when is_binary(next) ->
          resolve_alias_target(next, accounts, MapSet.put(seen, target))

        _ ->
          target
      end
    end
  end
end
