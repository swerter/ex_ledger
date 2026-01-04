defmodule ExLedger do
  @moduledoc """
  Main module for ExLedger - a ledger-cli format parser and processor.

  Provides utility functions for formatting dates and amounts in ledger format.
  """

  alias ExLedger.LedgerParser

  @month_names ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  Formats a Date struct into ledger register format: YY-Mon-DD

  ## Examples

      iex> ExLedger.format_date(~D[2009-10-29])
      "09-Oct-29"

      iex> ExLedger.format_date(~D[2009-11-01])
      "09-Nov-01"
  """
  @spec format_date(Date.t()) :: String.t()
  def format_date(%Date{year: year, month: month, day: day}) do
    year_short = rem(year, 100)
    month_name = Enum.at(@month_names, month - 1)

    "#{pad_two(year_short)}-#{month_name}-#{pad_two(day)}"
  end

  @doc """
  Formats a float amount into ledger format with currency symbol and 2 decimal places.

  ## Examples

      iex> ExLedger.format_amount(4.50)
      "    $4.50"

      iex> ExLedger.format_amount(-4.50)
      "   -$4.50"

      iex> ExLedger.format_amount(20.00)
      "   $20.00"
  """
  @spec format_amount(number()) :: String.t()
  def format_amount(amount) when is_float(amount) or is_integer(amount) do
    normalized_amount = amount * 1.0
    sign = if normalized_amount < 0, do: "-", else: ""
    abs_amount = abs(normalized_amount)

    formatted = :erlang.float_to_binary(abs_amount, decimals: 2)
    String.pad_leading("#{sign}$#{formatted}", 9)
  end

  @doc """
  Returns list of month abbreviations.
  """
  @spec month_names() :: [String.t()]
  def month_names, do: @month_names

  @doc """
  Parses ledger content and returns formatted transactions.

  ## Examples

      iex> input = """
      ...> 2024/01/01 Opening
      ...>     Assets:Cash  $10.00
      ...>     Equity:Opening
      ...> """
      iex> ExLedger.format_ledger(input)
      {:ok, "2024/01/01 Opening\n    Assets:Cash  $10.00\n    Equity:Opening  $-10.00\n"}
  """
  @spec format_ledger(String.t()) :: {:ok, String.t()} | {:error, term()}
  def format_ledger(input) when is_binary(input) do
    with {:ok, transactions} <- LedgerParser.parse_ledger(input) do
      {:ok, LedgerParser.format_transactions(transactions)}
    end
  end

  @doc """
  Parses a single transaction from a string.

  ## Examples

      iex> input = "2024/01/01 Opening\n    Assets:Cash  $10.00\n    Equity:Opening\n"
      iex> {:ok, transaction} = ExLedger.parse_transaction(input)
      iex> transaction.payee
      "Opening"
  """
  defdelegate parse_transaction(input), to: LedgerParser

  @doc """
  Parses multiple transactions from a ledger string.

  ## Examples

      iex> input = "2024/01/01 Opening\n    Assets:Cash  $10.00\n    Equity:Opening\n"
      iex> {:ok, transactions} = ExLedger.parse_ledger(input)
      iex> length(transactions)
      1
  """
  defdelegate parse_ledger(input), to: LedgerParser

  @doc """
  Parses a ledger string while attaching source file metadata.

  ## Examples

      iex> input = "2024/01/01 Opening\n    Assets:Cash  $10.00\n    Equity:Opening\n"
      iex> {:ok, [transaction]} = ExLedger.parse_ledger(input, "journal.ledger")
      iex> transaction.source_file
      "journal.ledger"
  """
  defdelegate parse_ledger(input, source_file), to: LedgerParser

  @doc """
  Checks whether a ledger file parses successfully.

  ## Examples

      iex> is_boolean(ExLedger.check_file("path/to/file.ledger"))
      true
  """
  defdelegate check_file(path), to: LedgerParser

  @doc """
  Checks a ledger file and returns an error tuple on failure.

  ## Examples

      iex> result = ExLedger.check_file_with_error("path/to/file.ledger")
      iex> match?({:ok, :valid}, result) or match?({:error, _}, result)
      true
  """
  defdelegate check_file_with_error(path), to: LedgerParser

  @doc """
  Checks whether a ledger string parses successfully.

  ## Examples

      iex> input = "2024/01/01 Opening\n    Assets:Cash  $10.00\n    Equity:Opening\n"
      iex> ExLedger.check_string(input, ".")
      true
  """
  def check_string(content, base_dir \\ ".") do
    LedgerParser.check_string(content, base_dir)
  end

  @doc """
  Parses a ledger file and resolves include directives.

  ## Examples

      iex> input = "2024/01/01 Opening\n    Assets:Cash  $10.00\n    Equity:Opening\n"
      iex> {:ok, transactions, accounts} = ExLedger.parse_ledger_with_includes(input, ".")
      iex> length(transactions) > 0 and is_map(accounts)
      true
  """
  def parse_ledger_with_includes(input, base_dir, seen_files \\ MapSet.new(), source_file \\ nil) do
    LedgerParser.parse_ledger_with_includes(input, base_dir, seen_files, source_file)
  end

  @doc """
  Expands include directives and returns the resolved ledger content.

  ## Examples

      iex> input = "2024/01/01 Opening\n    Assets:Cash  $10.00\n    Equity:Opening\n"
      iex> {:ok, expanded} = ExLedger.expand_includes(input, ".")
      iex> expanded == input
      true
  """
  def expand_includes(input, base_dir, seen_files \\ MapSet.new(), source_file \\ nil) do
    LedgerParser.expand_includes(input, base_dir, seen_files, source_file)
  end

  @doc """
  Extracts account declarations from ledger content.

  ## Examples

      iex> input = "account Assets:Checking  ; type:asset\n"
      iex> ExLedger.extract_account_declarations(input)
      %{"Assets:Checking" => :asset}
  """
  defdelegate extract_account_declarations(input), to: LedgerParser

  @doc """
  Parses an account declaration line.

  ## Examples

      iex> ExLedger.parse_account_declaration("account Assets:Checking  ; type:asset")
      {:ok, %{name: "Assets:Checking", type: :asset}}
  """
  defdelegate parse_account_declaration(input), to: LedgerParser

  @doc """
  Parses a date string into a `Date` struct.

  ## Examples

      iex> ExLedger.parse_date("2024/01/01")
      {:ok, ~D[2024-01-01]}
  """
  defdelegate parse_date(date_string), to: LedgerParser

  @doc """
  Parses a posting line.

  ## Examples

      iex> {:ok, posting} = ExLedger.parse_posting("Assets:Cash  $10.00")
      iex> posting.account
      "Assets:Cash"
  """
  defdelegate parse_posting(line), to: LedgerParser

  @doc """
  Parses an amount string into a structured amount map.

  ## Examples

      iex> {:ok, amount} = ExLedger.parse_amount("$10.00")
      iex> amount.value
      10.0
  """
  defdelegate parse_amount(amount_string), to: LedgerParser

  @doc """
  Parses a note line and returns the note tuple.

  ## Examples

      iex> ExLedger.parse_note(";:Food:")
      {:ok, {:tag, "Food"}}
  """
  defdelegate parse_note(note_string), to: LedgerParser

  @doc """
  Balances postings by filling in a single missing amount.

  ## Examples

      iex> postings = [
      ...>   %{account: "Assets:Cash", amount: %{value: 10.0, currency: "$"}},
      ...>   %{account: "Equity:Opening", amount: nil}
      ...> ]
      iex> [_filled, missing] = ExLedger.balance_postings(postings)
      iex> missing.amount.value
      -10.0
  """
  defdelegate balance_postings(transaction_or_postings), to: LedgerParser

  @doc """
  Validates that a transaction is balanced.

  ## Examples

      iex> transaction = %{postings: [
      ...>   %{account: "Assets:Cash", amount: %{value: 10.0, currency: "$"}},
      ...>   %{account: "Equity:Opening", amount: %{value: -10.0, currency: "$"}}
      ...> ]}
      iex> ExLedger.validate_transaction(transaction)
      :ok
  """
  defdelegate validate_transaction(transaction), to: LedgerParser

  @doc """
  Returns postings for an account with running balance.

  ## Examples

      iex> transactions = [
      ...>   %{date: ~D[2024-01-01], payee: "Open", postings: [
      ...>     %{account: "Assets:Cash", amount: %{value: 10.0, currency: "$"}}
      ...>   ]}
      ...> ]
      iex> ExLedger.get_account_postings(transactions, "Assets:Cash") |> length()
      1
  """
  defdelegate get_account_postings(transactions, account_name), to: LedgerParser

  @doc """
  Lists all account names, including declared accounts.

  ## Examples

      iex> transactions = [%{postings: [%{account: "Assets:Cash", amount: %{value: 1.0, currency: "$"}}]}]
      iex> ExLedger.list_accounts(transactions, %{"Assets:Bank" => :asset})
      ["Assets:Bank", "Assets:Cash"]
  """
  def list_accounts(transactions, account_map \\ %{}) do
    LedgerParser.list_accounts(transactions, account_map)
  end

  @doc """
  Lists all payees in the transactions.

  ## Examples

      iex> transactions = [%{payee: "Store", postings: []}, %{payee: "Cafe", postings: []}]
      iex> ExLedger.list_payees(transactions)
      ["Cafe", "Store"]
  """
  defdelegate list_payees(transactions), to: LedgerParser

  @doc """
  Lists all commodities referenced in postings.

  ## Examples

      iex> transactions = [%{postings: [%{account: "Assets:Cash", amount: %{value: 1.0, currency: "$"}}]}]
      iex> ExLedger.list_commodities(transactions)
      ["$"]
  """
  defdelegate list_commodities(transactions), to: LedgerParser

  @doc """
  Lists all tags referenced in postings.

  ## Examples

      iex> transactions = [%{postings: [%{account: "Expenses:Food", amount: %{value: 5.0, currency: "$"}, tags: ["Food"]}]}]
      iex> ExLedger.list_tags(transactions)
      ["Food"]
  """
  defdelegate list_tags(transactions), to: LedgerParser

  @doc """
  Returns the earliest regular transaction by date.

  ## Examples

      iex> transactions = [%{date: ~D[2024-01-01], payee: "Open", postings: []}]
      iex> ExLedger.first_transaction(transactions).payee
      "Open"
  """
  defdelegate first_transaction(transactions), to: LedgerParser

  @doc """
  Returns the latest regular transaction by date.

  ## Examples

      iex> transactions = [%{date: ~D[2024-01-01], payee: "Open", postings: []}]
      iex> ExLedger.last_transaction(transactions).payee
      "Open"
  """
  defdelegate last_transaction(transactions), to: LedgerParser

  @doc """
  Extracts declared payees from ledger content.

  ## Examples

      iex> input = "payee Coffee Shop\npayee Grocery\n"
      iex> ExLedger.extract_payee_declarations(input) |> MapSet.member?("Grocery")
      true
  """
  defdelegate extract_payee_declarations(input), to: LedgerParser

  @doc """
  Extracts declared commodities from ledger content.

  ## Examples

      iex> input = "commodity $\n"
      iex> ExLedger.extract_commodity_declarations(input) |> MapSet.member?("$")
      true
  """
  defdelegate extract_commodity_declarations(input), to: LedgerParser

  @doc """
  Extracts declared tags from ledger content.

  ## Examples

      iex> input = "tag Travel\n"
      iex> ExLedger.extract_tag_declarations(input) |> MapSet.member?("Travel")
      true
  """
  defdelegate extract_tag_declarations(input), to: LedgerParser

  @doc """
  Checks that all accounts used in transactions are declared.

  ## Examples

      iex> transactions = [%{postings: [%{account: "Assets:Cash", amount: %{value: 1.0, currency: "$"}}]}]
      iex> ExLedger.check_accounts(transactions, %{"Assets:Cash" => :asset})
      :ok
  """
  defdelegate check_accounts(transactions, accounts), to: LedgerParser

  @doc """
  Checks that all payees used in transactions are declared.

  ## Examples

      iex> transactions = [%{payee: "Store", postings: []}]
      iex> ExLedger.check_payees(transactions, MapSet.new(["Store"]))
      :ok
  """
  defdelegate check_payees(transactions, declared_payees), to: LedgerParser

  @doc """
  Checks that all commodities used in transactions are declared.

  ## Examples

      iex> transactions = [%{postings: [%{account: "Assets:Cash", amount: %{value: 1.0, currency: "$"}}]}]
      iex> ExLedger.check_commodities(transactions, MapSet.new(["$"]))
      :ok
  """
  defdelegate check_commodities(transactions, declared_commodities), to: LedgerParser

  @doc """
  Checks that all tags used in transactions are declared.

  ## Examples

      iex> transactions = [%{postings: [%{account: "Expenses:Food", amount: %{value: 5.0, currency: "$"}, tags: ["Food"]}]}]
      iex> contents = "; :Food:\n"
      iex> ExLedger.check_tags(transactions, contents, MapSet.new(["Food"]))
      :ok
  """
  defdelegate check_tags(transactions, contents, declared_tags), to: LedgerParser

  @doc """
  Builds summary statistics for the ledger.

  ## Examples

      iex> transactions = [%{date: ~D[2024-01-01], payee: "Store", postings: [%{account: "Assets:Cash", amount: %{value: -5.0, currency: "$"}}]}]
      iex> ExLedger.stats(transactions).unique_accounts
      1
  """
  defdelegate stats(transactions), to: LedgerParser

  @doc """
  Formats stats into a report string.

  ## Examples

      iex> transactions = [%{date: ~D[2024-01-01], payee: "Store", postings: [%{account: "Assets:Cash", amount: %{value: -5.0, currency: "$"}}]}]
      iex> stats = ExLedger.stats(transactions)
      iex> is_binary(ExLedger.format_stats(stats))
      true
  """
  defdelegate format_stats(stats), to: LedgerParser

  @doc """
  Selects postings matching a query string.

  ## Examples

      iex> transactions = [%{date: ~D[2024-01-01], payee: "Store", postings: [%{account: "Assets:Cash", amount: %{value: -5.0, currency: "$"}, tags: []}]}]
      iex> ExLedger.select(transactions, "account from posts where account=~/Assets/")
      {:ok, ["account"], [%{"account" => "Assets:Cash"}]}
  """
  defdelegate select(transactions, query), to: LedgerParser

  @doc """
  Formats select rows into a tab-separated output.

  ## Examples

      iex> ExLedger.format_select(["account"], [%{"account" => "Assets:Cash"}])
      "Assets:Cash\n"
  """
  defdelegate format_select(fields, rows), to: LedgerParser

  @doc """
  Builds a new transaction entry based on a payee pattern.

  ## Examples

      iex> transactions = [
      ...>   %{date: ~D[2024-01-01], payee: "Coffee", postings: [
      ...>     %{account: "Expenses:Food", amount: %{value: 4.0, currency: "$"}},
      ...>     %{account: "Assets:Cash", amount: %{value: -4.0, currency: "$"}}
      ...>   ]}
      ...> ]
      iex> {:ok, output} = ExLedger.build_xact(transactions, ~D[2024-01-15], "Coffee")
      iex> String.contains?(output, "Coffee")
      true
  """
  defdelegate build_xact(transactions, date, payee_pattern), to: LedgerParser

  @doc """
  Parses timeclock entries from input.

  ## Examples

      iex> input = "i 2024/01/01 09:00:00 Assets:Work  Client\nO 2024/01/01 10:00:00\n"
      iex> ExLedger.parse_timeclock_entries(input) |> length()
      1
  """
  defdelegate parse_timeclock_entries(input), to: LedgerParser

  @doc """
  Builds a timeclock report grouped by account.

  ## Examples

      iex> entries = [%{account: "Work", duration_seconds: 3600}]
      iex> ExLedger.timeclock_report(entries)["Work"]
      1.0
  """
  defdelegate timeclock_report(entries), to: LedgerParser

  @doc """
  Formats a timeclock report.

  ## Examples

      iex> report = %{"Work" => 1.5}
      iex> String.contains?(ExLedger.format_timeclock_report(report), "Work")
      true
  """
  defdelegate format_timeclock_report(report), to: LedgerParser

  @doc """
  Builds a budget report for periodic transactions.

  ## Examples

      iex> transactions = [
      ...>   %{kind: :periodic, period: "monthly", postings: [%{account: "Expenses:Rent", amount: %{value: 100.0, currency: "$"}}]},
      ...>   %{kind: :regular, date: ~D[2024-01-10], postings: [%{account: "Expenses:Rent", amount: %{value: 40.0, currency: "$"}}]}
      ...> ]
      iex> rows = ExLedger.budget_report(transactions, ~D[2024-01-15])
      iex> Enum.any?(rows, &(&1.account == "Expenses:Rent"))
      true
  """
  def budget_report(transactions, date \\ Date.utc_today()) do
    LedgerParser.budget_report(transactions, date)
  end

  @doc """
  Formats a budget report table.

  ## Examples

      iex> rows = [%{account: "Expenses:Rent", currency: "$", actual: 40.0, budget: 100.0, remaining: 60.0}]
      iex> String.contains?(ExLedger.format_budget_report(rows), "Expenses:Rent")
      true
  """
  defdelegate format_budget_report(rows), to: LedgerParser

  @doc """
  Forecasts balances after applying periodic budgets.

  ## Examples

      iex> transactions = [
      ...>   %{kind: :regular, date: ~D[2024-01-01], postings: [%{account: "Assets:Cash", amount: %{value: 10.0, currency: "$"}}]},
      ...>   %{kind: :periodic, period: "monthly", postings: [%{account: "Assets:Cash", amount: %{value: 5.0, currency: "$"}}]}
      ...> ]
      iex> [first | _] = ExLedger.forecast_balance(transactions, 2)["Assets:Cash"]
      iex> first.amount
      20.0
  """
  def forecast_balance(transactions, months \\ 1) do
    LedgerParser.forecast_balance(transactions, months)
  end

  @doc """
  Formats account postings into a register report.

  ## Examples

      iex> postings = [%{date: ~D[2024-01-01], description: "Open", account: "Assets:Cash", amount: %{value: 10.0, currency: "$"}, balance: %{value: 10.0, currency: "$"}}]
      iex> String.contains?(ExLedger.format_account_register(postings, "Assets:Cash"), "Assets:Cash")
      true
  """
  defdelegate format_account_register(postings, account_name), to: LedgerParser

  @doc """
  Builds a register view of postings with running balances.

  ## Examples

      iex> transactions = [%{date: ~D[2024-01-01], payee: "Open", postings: [%{account: "Assets:Cash", amount: %{value: 10.0, currency: "$"}}]}]
      iex> ExLedger.register(transactions) |> length()
      1
  """
  def register(transactions, account_regex \\ nil) do
    LedgerParser.register(transactions, account_regex)
  end

  @doc """
  Formats transactions into ledger-compatible output.

  ## Examples

      iex> input = "2024/01/01 Opening\n    Assets:Cash  $10.00\n    Equity:Opening\n"
      iex> {:ok, transactions} = ExLedger.parse_ledger(input)
      iex> String.contains?(ExLedger.format_transactions(transactions), "Opening")
      true
  """
  defdelegate format_transactions(transactions), to: LedgerParser

  @doc """
  Resolves an account name or alias to its canonical name.

  ## Examples

      iex> accounts = %{"Assets:Checking" => :asset, "checking" => "Assets:Checking"}
      iex> ExLedger.resolve_account_name("checking", accounts)
      "Assets:Checking"
  """
  defdelegate resolve_account_name(account_name, account_map), to: LedgerParser

  @doc """
  Resolves all account aliases inside transactions.

  ## Examples

      iex> transactions = [%{postings: [%{account: "checking", amount: %{value: -10.0, currency: "$"}}]}]
      iex> accounts = %{"Assets:Checking" => :asset, "checking" => "Assets:Checking"}
      iex> ExLedger.resolve_transaction_aliases(transactions, accounts)
      [%{postings: [%{account: "Assets:Checking", amount: %{value: -10.0, currency: "$"}}]}]
  """
  defdelegate resolve_transaction_aliases(transactions, account_map), to: LedgerParser

  @doc """
  Calculates balances per account.

  ## Examples

      iex> transactions = [%{postings: [
      ...>   %{account: "Assets:Cash", amount: %{value: 10.0, currency: "$"}},
      ...>   %{account: "Expenses:Food", amount: %{value: -10.0, currency: "$"}}
      ...> ]}]
      iex> [first | _] = ExLedger.balance(transactions)["Assets:Cash"]
      iex> first.amount
      10.0
  """
  defdelegate balance(transaction_or_transactions), to: LedgerParser

  @doc """
  Formats balances as a report string.

  ## Examples

      iex> balances = %{"Assets:Checking" => [%{amount: -23.0, currency: "$"}], "Expenses:Utilities" => [%{amount: 23.0, currency: "$"}]}
      iex> String.contains?(ExLedger.format_balance(balances), "Assets:Checking")
      true
  """
  def format_balance(balances, show_empty \\ false) do
    LedgerParser.format_balance(balances, show_empty)
  end

  @doc """
  Formats a numeric value for a specific currency.

  ## Examples

      iex> ExLedger.format_amount_for_currency(10.5, "$")
      "$10.50"
  """
  defdelegate format_amount_for_currency(value, currency), to: LedgerParser

  @doc """
  Calculates balances grouped by time period.

  ## Examples

      iex> transactions = [%{date: ~D[2024-01-01], payee: "Open", postings: [%{account: "Assets:Cash", amount: %{value: 10.0, currency: "$"}}]}]
      iex> result = ExLedger.balance_by_period(transactions, "monthly")
      iex> Map.has_key?(result, "balances")
      true
  """
  def balance_by_period(
        transactions,
        group_by \\ "none",
        start_date \\ nil,
        end_date \\ nil,
        account_filter \\ nil
      ) do
    LedgerParser.balance_by_period(transactions, group_by, start_date, end_date, account_filter)
  end

  defp pad_two(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
  end
end
