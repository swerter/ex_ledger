defmodule ExLedger.Parser.BalanceAssertions do
  @moduledoc """
  Validates balance assertions after transactions are parsed.

  Balance assertions use the syntax `AMOUNT = ASSERTION_AMOUNT` to verify
  that the running balance of an account equals a specific value after the
  posting is applied.

  ## Example

      2026/09/30 * Q3 Balance Check
          Assets:Bank:Checking        0 = 45000.00 CHF
          Assets:Cash                 0 = 932.20 CHF

  This asserts that after the zero-amount posting, the running balance of
  `Assets:Bank:Checking` equals 45000.00 CHF.
  """

  alias ExLedger.Parser.Core

  @type assertion_failure :: %{
          account: String.t(),
          expected: Core.amount(),
          actual: Core.amount(),
          transaction_date: Date.t() | nil,
          transaction_payee: String.t() | nil,
          source_file: String.t() | nil,
          source_line: non_neg_integer() | nil
        }

  @type validation_result :: :ok | {:error, [assertion_failure()]}

  @doc """
  Validates all balance assertions in a list of transactions.

  Computes running balances per account/currency and checks assertions.
  Returns `:ok` if all assertions pass, or `{:error, failures}` with all
  failed assertions.

  ## Options

    * `:skip_assertions` - if `true`, skips validation and returns `:ok`

  ## Examples

      iex> BalanceAssertions.validate_assertions(transactions)
      :ok

      iex> BalanceAssertions.validate_assertions(transactions)
      {:error, [%{account: "Assets:Cash", expected: ..., actual: ...}]}

  """
  @spec validate_assertions([Core.transaction()], keyword()) :: validation_result()
  def validate_assertions(transactions, opts \\ [])

  def validate_assertions(_transactions, skip_assertions: true), do: :ok

  def validate_assertions(transactions, _opts) do
    # Filter to regular transactions only (not automated/periodic templates)
    regular_transactions =
      Enum.filter(transactions, fn tx -> tx.kind == :regular end)

    # Sort transactions by date for correct running balance calculation
    sorted = Enum.sort_by(regular_transactions, & &1.date, Date)

    # Build running balances and collect assertion failures
    {_final_balances, failures} =
      Enum.reduce(sorted, {%{}, []}, fn transaction, {balances, failures} ->
        validate_transaction_assertions(transaction, balances, failures)
      end)

    case failures do
      [] -> :ok
      _ -> {:error, Enum.reverse(failures)}
    end
  end

  @doc """
  Validates assertions for a single transaction, updating running balances.

  Returns a tuple of `{updated_balances, updated_failures}`.
  """
  @spec validate_transaction_assertions(
          Core.transaction(),
          %{String.t() => %{String.t() => float()}},
          [assertion_failure()]
        ) :: {%{String.t() => %{String.t() => float()}}, [assertion_failure()]}
  def validate_transaction_assertions(transaction, balances, failures) do
    Enum.reduce(transaction.postings, {balances, failures}, fn posting, {bal, fail} ->
      validate_posting_assertion(posting, transaction, bal, fail)
    end)
  end

  defp validate_posting_assertion(posting, transaction, balances, failures) do
    # Skip virtual unbalanced postings - they don't affect real balances
    if posting.virtual and not posting.must_balance do
      check_assertion_only(posting, balances, transaction, failures)
    else
      # Update running balance for this posting
      updated_balances = update_running_balance(balances, posting)

      # Check assertion if present
      check_assertion(posting, updated_balances, transaction, failures)
    end
  end

  defp check_assertion_only(posting, balances, transaction, failures) do
    case posting.assertion do
      nil ->
        {balances, failures}

      assertion ->
        do_check_assertion(posting, assertion, balances, transaction, failures)
    end
  end

  defp check_assertion(posting, balances, transaction, failures) do
    case posting.assertion do
      nil ->
        {balances, failures}

      assertion ->
        do_check_assertion(posting, assertion, balances, transaction, failures)
    end
  end

  defp do_check_assertion(posting, assertion, balances, transaction, failures) do
    account = posting.account
    currency = assertion.currency || "default"
    expected = assertion.value

    account_balances = Map.get(balances, account, %{})
    actual = Map.get(account_balances, currency, 0.0)

    # Use tolerance for floating-point comparison
    if abs(actual - expected) < 0.005 do
      {balances, failures}
    else
      failure = %{
        account: account,
        expected: assertion,
        actual: %{value: actual, currency: currency, currency_position: nil},
        transaction_date: transaction.date,
        transaction_payee: transaction.payee,
        source_file: Map.get(transaction, :source_file),
        source_line: Map.get(transaction, :source_line)
      }

      {balances, [failure | failures]}
    end
  end

  defp update_running_balance(balances, %{amount: nil}), do: balances

  defp update_running_balance(balances, posting) do
    account = posting.account
    currency = posting.amount.currency || "default"

    # For balance assertions, track the raw commodity amount (not the cost/effective value)
    # e.g., "10 AAPL @ 150 USD" should add 10 to the AAPL balance, not 1500
    value = posting.amount.value

    account_balances = Map.get(balances, account, %{})
    current = Map.get(account_balances, currency, 0.0)
    new_balance = current + value

    Map.put(balances, account, Map.put(account_balances, currency, new_balance))
  end

  @doc """
  Formats assertion failures as a human-readable error message.

  ## Example

      iex> BalanceAssertions.format_failures([failure])
      "Balance assertion failed for account 'Assets:Cash'\\n  Expected: 100.00 CHF\\n  ..."

  """
  @spec format_failures([assertion_failure()]) :: String.t()
  def format_failures(failures) do
    failures
    |> Enum.map(&format_single_failure/1)
    |> Enum.join("\n\n")
  end

  defp format_single_failure(failure) do
    location = format_location(failure.source_file, failure.source_line)
    date = if failure.transaction_date, do: Date.to_iso8601(failure.transaction_date), else: "unknown"
    payee = failure.transaction_payee || "unknown"
    expected = format_amount(failure.expected)
    actual = format_amount(failure.actual)

    """
    Balance assertion failed for account '#{failure.account}'
      Expected: #{expected}
      Actual:   #{actual}
      Transaction: #{date} #{payee}#{location}\
    """
  end

  defp format_location(nil, _), do: ""
  defp format_location(file, nil), do: "\n  File: #{file}"
  defp format_location(file, line), do: "\n  File: #{file}:#{line}"

  defp format_amount(%{value: value, currency: nil}), do: format_number(value)
  defp format_amount(%{value: value, currency: "default"}), do: format_number(value)
  defp format_amount(%{value: value, currency: currency}), do: "#{format_number(value)} #{currency}"

  defp format_number(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 2)
  end

  defp format_number(value), do: to_string(value)
end
