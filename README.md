# ExLedger

An Elixir-based [ledger-cli](https://ledger-cli.org/docs.html) file parser and processor. ExLedger provides both a command-line interface and a library for parsing, validating, and reporting on plain-text accounting ledger files.

## Features

- Parse ledger-cli formatted transaction files
- Support for multi-currency transactions
- Account declarations with types and aliases
- Include directives for splitting ledgers across files
- Transaction validation and balance checking
- Multiple report types (balance, register, budget, forecast)
- Timeclock support for time tracking
- Query interface for data extraction
- Strict mode for enforcing declared accounts
- Periodic/scheduled transactions

## Installation

### As a Library

Add `ex_ledger` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_ledger, "~> 0.1.0"}
  ]
end
```

### Building the CLI

Build the standalone executable:

```bash
mix deps.get
mix release
```

Or for a portable binary using Burrito:

```bash
MIX_ENV=prod mix release
```

The executable will be available at `./bin/exledger` (or in `_build/prod/burrito_out/`).

## CLI Usage

### Basic Commands

#### Balance Report

Show account balances:

```bash
# Show all balances
bin/exledger -f ledger.dat balance

# Filter by account pattern
bin/exledger -f ledger.dat balance Assets

# Show zero-balance accounts
bin/exledger -f ledger.dat balance --empty

# Yearly balance report
bin/exledger -f ledger.dat balance --yearly

# Top-level accounts only (cost basis)
bin/exledger -f ledger.dat balance --basis

# Flat report (no hierarchy)
bin/exledger -f ledger.dat balance --flat
```

#### Register Report

Show detailed transaction register:

```bash
# Show all postings
bin/exledger -f ledger.dat register

# Filter by account
bin/exledger -f ledger.dat register Checking

# Filter with regex
bin/exledger -f ledger.dat register "Expenses:.*"
```

#### Print Transactions

Print formatted ledger transactions:

```bash
bin/exledger -f ledger.dat print
```

#### Validation

Check file integrity and declarations:

```bash
# Check everything (accounts, payees, commodities, tags)
bin/exledger -f ledger.dat check

# Check specific declarations
bin/exledger -f ledger.dat check accounts
bin/exledger -f ledger.dat check payees
bin/exledger -f ledger.dat check commodities
bin/exledger -f ledger.dat check tags

# Strict mode - require all accounts to be declared
bin/exledger -f ledger.dat --strict balance
```

#### List Commands

Extract information from ledger:

```bash
# List all accounts
bin/exledger -f ledger.dat accounts

# List accounts matching pattern
bin/exledger -f ledger.dat accounts "Assets:.*"

# List payees
bin/exledger -f ledger.dat payees

# List commodities (currencies)
bin/exledger -f ledger.dat commodities

# List tags
bin/exledger -f ledger.dat tags
```

#### Stats

Show ledger statistics:

```bash
bin/exledger -f ledger.dat stats
```

#### Budget & Forecast

Budget tracking and forecasting:

```bash
# Show budget vs actual
bin/exledger -f ledger.dat budget

# Forecast balances for next N months
bin/exledger -f ledger.dat forecast 3
```

#### Query Interface

Run SQL-like queries:

```bash
# Select specific fields
bin/exledger -f ledger.dat select "account from posts where account=~/Expenses/"

# Complex queries
bin/exledger -f ledger.dat select "account, sum(amount) from posts group by account"
```

#### Transaction Templates

Generate transaction templates based on historical data:

```bash
# Create a new transaction based on payee pattern
bin/exledger -f ledger.dat xact 2024/01/15 "Grocery"
```

#### Timeclock

Track time entries:

```bash
bin/exledger -f timelog.dat timeclock
```

### Example Ledger File

```ledger
; Account declarations
account Assets:Checking
    alias checking
account Expenses:Groceries
account Expenses:Gas

; Commodity declarations
commodity $

; Payee declarations
payee Grocery Store
payee Gas Station

; Transactions
2024/01/15 Grocery Store
    Expenses:Groceries          $50.00
    Assets:Checking

2024/01/20 Gas Station
    Expenses:Gas                $40.00
    checking                    ; uses alias

; Periodic transaction (budget)
~ monthly
    Expenses:Rent               $1000.00
    Assets:Checking
```

## Library Usage

### Basic Parsing

```elixir
# Parse a ledger file
{:ok, transactions} = ExLedger.parse_ledger("""
2024/01/01 Opening Balance
    Assets:Cash     $100.00
    Equity:Opening
""")

# Parse with include resolution
{:ok, transactions, accounts} = ExLedger.parse_ledger_with_includes(
  ledger_content,
  "/path/to/base/dir"
)

# Parse a single transaction
{:ok, transaction} = ExLedger.parse_transaction("""
2024/01/15 Grocery Store
    Expenses:Food   $50.00
    Assets:Cash
""")
```

### Validation

```elixir
# Check if a file is valid
ExLedger.check_file("path/to/ledger.dat")
# => true

# Get detailed error information
{:ok, :valid} = ExLedger.check_file_with_error("path/to/ledger.dat")

# Validate transaction balance
ExLedger.validate_transaction(transaction)
# => :ok or {:error, reason}

# Check account declarations
ExLedger.check_accounts(transactions, account_map)

# Check payee declarations
ExLedger.check_payees(transactions, declared_payees_set)

# Check commodity declarations
ExLedger.check_commodities(transactions, declared_commodities_set)
```

### Reporting

```elixir
# Calculate balances
balances = ExLedger.balance(transactions)
# => %{"Assets:Cash" => [%{amount: 50.0, currency: "$"}], ...}

# Format balance report
formatted = ExLedger.format_balance(balances, show_empty: false)
IO.puts(formatted)

# Get register for an account
postings = ExLedger.get_account_postings(transactions, "Assets:Checking")

# Build register report
register = ExLedger.register(transactions, ~r/Assets/)
formatted_register = ExLedger.format_account_register(register, "Assets")

# Generate statistics
stats = ExLedger.stats(transactions)
ExLedger.format_stats(stats) |> IO.puts()
```

### Working with Accounts

```elixir
# List all accounts
accounts = ExLedger.list_accounts(transactions)
# => ["Assets:Cash", "Assets:Checking", "Expenses:Food", ...]

# List payees
payees = ExLedger.list_payees(transactions)
# => ["Grocery Store", "Gas Station", ...]

# List commodities
commodities = ExLedger.list_commodities(transactions)
# => ["$", "EUR", "CHF"]

# Resolve account aliases
canonical_name = ExLedger.resolve_account_name("checking", account_map)
# => "Assets:Checking"

# Resolve aliases in transactions
resolved = ExLedger.resolve_transaction_aliases(transactions, account_map)
```

### Budgeting and Forecasting

```elixir
# Generate budget report
budget_rows = ExLedger.budget_report(transactions, ~D[2024-01-15])

formatted = ExLedger.format_budget_report(budget_rows)
IO.puts(formatted)

# Forecast future balances
forecast = ExLedger.forecast_balance(transactions, 3) # 3 months
formatted_forecast = ExLedger.format_balance(forecast)
```

### Advanced Features

```elixir
# Parse with date filtering
{:ok, date} = ExLedger.parse_date("2024/01/15")

# Build transaction template
{:ok, template} = ExLedger.build_xact(transactions, ~D[2024-02-01], "Grocery")
IO.puts(template)

# Balance postings (fill in missing amounts)
balanced_postings = ExLedger.balance_postings(postings)

# Query transactions
{:ok, fields, rows} = ExLedger.select(transactions, "account, amount from posts where account=~/Expenses/")
formatted = ExLedger.format_select(fields, rows)

# Balance by time period
result = ExLedger.balance_by_period(
  transactions,
  "monthly",  # or "yearly", "quarterly"
  ~D[2024-01-01],  # start date
  ~D[2024-12-31]   # end date
)
```

### Account Declarations

```elixir
# Extract account declarations
accounts = ExLedger.extract_account_declarations("""
account Assets:Checking  ; type:asset
account Expenses:Food    ; type:expense
""")
# => %{"Assets:Checking" => :asset, "Expenses:Food" => :expense}

# Parse single declaration
{:ok, %{name: name, type: type}} = ExLedger.parse_account_declaration(
  "account Assets:Cash  ; type:asset"
)
```

### Formatting

```elixir
# Format a date in ledger format
ExLedger.format_date(~D[2024-01-15])
# => "24-Jan-15"

# Format an amount
ExLedger.format_amount(50.00)
# => "   $50.00"

# Format specific currency
ExLedger.format_amount_for_currency(42.50, "EUR")
# => "EUR42.50"

# Format transactions
formatted = ExLedger.format_transactions(transactions)
IO.puts(formatted)
```

### Timeclock

```elixir
# Parse timeclock entries
entries = ExLedger.parse_timeclock_entries("""
i 2024/01/15 09:00:00 Work:ProjectA
o 2024/01/15 12:00:00
""")

# Generate report
report = ExLedger.timeclock_report(entries)
# => %{"Work:ProjectA" => 3.0}

formatted = ExLedger.format_timeclock_report(report)
```

## Development

### Running Tests

```bash
mix test
```

### Type Checking

```bash
mix dialyzer
```

### Linting

```bash
mix credo
```

### Test Coverage

```bash
mix coveralls
```

## Documentation

Generate documentation with ExDoc:

```bash
mix docs
```

Documentation will be available at `doc/index.html`.

## License

See LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
