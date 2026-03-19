defmodule ExLedger.TransactionHelpers do
  @moduledoc """
  Shared test helpers for parsing and building test transactions.
  """

  import ExUnit.Assertions
  alias ExLedger.LedgerParser

  @doc """
  Parses a transaction string and returns the transaction or flunks on error.
  """
  def parse_transaction!(input) do
    case LedgerParser.parse_transaction(input) do
      {:ok, transaction} -> transaction
      {:error, reason} -> flunk("Expected transaction to parse, got: #{inspect(reason)}")
    end
  end

  @doc """
  Parses a ledger string and returns the transactions list or flunks on error.
  """
  def parse_ledger!(input, opts \\ []) do
    case LedgerParser.parse_ledger(input, opts) do
      {:ok, result} -> result.transactions
      {:error, reason} -> flunk("Expected ledger to parse, got: #{inspect(reason)}")
    end
  end

  @doc """
  Parses a posting string and returns the posting or flunks on error.
  """
  def parse_posting!(input) do
    case LedgerParser.parse_posting(input) do
      {:ok, posting} -> posting
      {:error, reason} -> flunk("Expected posting to parse, got: #{inspect(reason)}")
    end
  end

  @doc """
  Builds a transaction struct for test assertions.
  """
  def transaction(payee, postings) do
    %{
      kind: :regular,
      date: ~D[2024-01-01],
      aux_date: nil,
      state: :uncleared,
      code: "",
      payee: payee,
      comment: nil,
      predicate: nil,
      period: nil,
      postings: postings
    }
  end

  @doc """
  Builds a posting struct for test assertions.
  """
  def posting(account, amount, tags \\ []) do
    %{
      account: account,
      amount: amount,
      metadata: %{},
      tags: tags,
      comments: []
    }
  end

  @doc """
  Builds a simple posting with USD currency.
  """
  def simple_posting(account, value) do
    posting(account, %{value: Decimal.from_float(value), currency: "$"}, [])
  end

  @doc """
  Builds a periodic transaction struct for test assertions.
  """
  def periodic(period, value) do
    %{
      kind: :periodic,
      date: nil,
      aux_date: nil,
      state: :uncleared,
      code: "",
      payee: nil,
      comment: nil,
      predicate: nil,
      period: period,
      postings: [
        %{
          account: "Expenses:#{period}",
          amount: %{value: Decimal.from_float(value), currency: "$"},
          metadata: %{},
          tags: [],
          comments: []
        },
        %{
          account: "Assets:Cash",
          amount: %{value: Decimal.from_float(-value), currency: "$"},
          metadata: %{},
          tags: [],
          comments: []
        }
      ]
    }
  end

  @doc """
  Builds an amount struct for test assertions.
  """
  def amount(value, currency) when is_binary(value) do
    %{value: Decimal.new(value), currency: currency}
  end

  def amount(value, currency) when is_float(value) do
    %{value: Decimal.from_float(value), currency: currency}
  end

  def amount(value, currency) when is_integer(value) do
    %{value: Decimal.new(value), currency: currency}
  end
end
