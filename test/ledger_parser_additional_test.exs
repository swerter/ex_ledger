defmodule ExLedger.LedgerParserAdditionalTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias ExLedger.LedgerParser
  alias ExLedger.TestHelpers

  setup do
    {:ok, tmp_dir: TestHelpers.tmp_dir!("ex_ledger_additional")}
  end

  describe "check_string/2" do
    test "returns true for valid content" do
      input = """
      2024/01/01 Sample
          Assets:Cash  $1.00
          Equity:Opening
      """

      assert LedgerParser.check_string(input, ".")
    end

    test "returns false for invalid content" do
      refute LedgerParser.check_string("invalid", ".")
    end
  end

  describe "check_file_with_error/1" do
    test "returns ok for valid file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "valid.ledger")

      File.write!(path, """
      2024/01/01 Sample
          Assets:Cash  $1.00
          Equity:Opening
      """)

      assert {:ok, :valid} = LedgerParser.check_file_with_error(path)
    end

    test "returns error details for parse failures", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "invalid.ledger")
      File.write!(path, "invalid")

      assert {:error, error} = LedgerParser.check_file_with_error(path)
      assert error.reason == :missing_date
      assert error.line == 1
    end

    test "returns file read errors", %{tmp_dir: tmp_dir} do
      missing_path = Path.join(tmp_dir, "missing.ledger")

      assert {:error, :enoent} = LedgerParser.check_file_with_error(missing_path)
    end
  end

  describe "expand_includes/4" do
    test "expands included content", %{tmp_dir: tmp_dir} do
      included_path = Path.join(tmp_dir, "included.ledger")

      File.write!(included_path, """
      2024/01/01 Included
          Assets:Cash  $5.00
          Equity:Opening
      """)

      content = """
      include included.ledger

      2024/01/02 Main
          Assets:Cash  $6.00
          Equity:Opening
      """

      assert {:ok, expanded} =
               LedgerParser.expand_includes(content, tmp_dir, MapSet.new(), "main.ledger")

      assert String.contains?(expanded, "Included")
      assert String.contains?(expanded, "Main")
    end

    test "returns ok for empty content" do
      assert {:ok, ""} = LedgerParser.expand_includes("", ".", MapSet.new(), nil)
    end

    test "returns error for absolute include paths" do
      content = "include /tmp/ledger.ledger\n"

      assert {:error, {:include_outside_base, "/tmp/ledger.ledger"}} =
               LedgerParser.expand_includes(content, ".", MapSet.new(), "main.ledger")
    end

    test "returns error for missing include file", %{tmp_dir: tmp_dir} do
      content = "include missing.ledger\n"

      assert {:error, {:include_not_found, "missing.ledger"}} =
               LedgerParser.expand_includes(content, tmp_dir, MapSet.new(), "main.ledger")
    end

    test "returns error for circular includes", %{tmp_dir: tmp_dir} do
      file_a = Path.join(tmp_dir, "a.ledger")
      file_b = Path.join(tmp_dir, "b.ledger")

      File.write!(file_a, "include b.ledger\n")
      File.write!(file_b, "include a.ledger\n")

      assert {:error, {:circular_include, "a.ledger"}} =
               LedgerParser.expand_includes(
                 "include a.ledger\n",
                 tmp_dir,
                 MapSet.new(),
                 "main.ledger"
               )
    end

    test "returns error when include path is unreadable", %{tmp_dir: tmp_dir} do
      directory_path = Path.join(tmp_dir, "included.ledger")
      File.mkdir_p!(directory_path)

      assert {:error, {:file_read_error, "included.ledger", :eisdir}} =
               LedgerParser.expand_includes(
                 "include included.ledger\n",
                 tmp_dir,
                 MapSet.new(),
                 "main.ledger"
               )
    end
  end

  describe "parse_ledger/1" do
    test "returns empty list for empty input" do
      assert {:ok, [], _accounts} = LedgerParser.parse_ledger("")
    end
  end

  describe "parse_transaction/1" do
    test "returns missing_predicate for empty automated header" do
      input = """
      =
          Assets:Cash  $1.00
      """

      assert {:error, :missing_predicate} = LedgerParser.parse_transaction(input)
    end

    test "returns missing_period for empty periodic header" do
      input = """
      ~
          Assets:Cash  $1.00
      """

      assert {:error, :missing_period} = LedgerParser.parse_transaction(input)
    end

    test "returns insufficient_postings for automated transaction" do
      input = """
      = expr
      """

      assert {:error, :insufficient_postings} = LedgerParser.parse_transaction(input)
    end

    test "returns unexpected_input when trailing content remains" do
      input = """
      2024/01/01 Sample
          Assets:Cash  $1.00
          Equity:Opening
          ; trailing note
      """

      assert {:error, {:unexpected_input, _}} = LedgerParser.parse_transaction(input)
    end

    test "returns parse_error for invalid dates" do
      input = """
      2024/99/01 Sample
          Assets:Cash  $1.00
          Equity:Opening
      """

      assert {:ok, transaction} = LedgerParser.parse_transaction(input)
      assert transaction.date == {:error, :invalid_date}
    end
  end

  describe "parse_ledger/2" do
    test "adds source file to parsed transactions" do
      input = """
      2024/01/01 Sample
          Assets:Cash  $1.00
          Equity:Opening
      """

      assert {:ok, [transaction], _accounts} = LedgerParser.parse_ledger(input, source_file: "main.ledger")
      assert transaction.source_file == "main.ledger"
      assert transaction.source_line == 1
    end

    test "skips timeclock and account directives when splitting" do
      input = """
      i 2024/01/01 09:00:00 Work
      account Assets:Cash
          alias cash
      2024/01/02 Payee
          Assets:Cash  $1.00
          Equity:Opening
      i 2024/01/03 09:00:00 Work
      2024/01/04 Payee Two
          Assets:Cash  $2.00
          Equity:Opening
      """

      assert {:ok, transactions, _accounts} = LedgerParser.parse_ledger(input, source_file: "main.ledger")
      assert Enum.map(transactions, & &1.payee) == ["Payee", "Payee Two"]
      assert Enum.map(transactions, & &1.source_line) == [4, 8]
    end
  end

  describe "parse_ledger_with_includes/4" do
    test "returns empty result for empty content" do
      assert {:ok, [], %{}} = LedgerParser.parse_ledger("", base_dir: ".")
    end

    test "adds source files to included transactions", %{tmp_dir: tmp_dir} do
      included_path = Path.join(tmp_dir, "included.ledger")

      File.write!(included_path, """
      2024/01/01 Included
          Assets:Cash  $5.00
          Equity:Opening
      """)

      content = """
      include included.ledger

      2024/01/02 Main
          Assets:Cash  $6.00
          Equity:Opening
      """

      assert {:ok, transactions, _accounts} =
               LedgerParser.parse_ledger(
                 content,
                 base_dir: tmp_dir,
                 source_file: "main.ledger"
               )

      assert Enum.at(transactions, 0).source_file == "included.ledger"
      assert Enum.at(transactions, 1).source_file == "main.ledger"
      assert Enum.at(transactions, 0).source_line == 1
      assert Enum.at(transactions, 1).source_line == 2
    end

    test "skips comment-only content before includes", %{tmp_dir: tmp_dir} do
      included_path = Path.join(tmp_dir, "included.ledger")

      File.write!(included_path, """
      2024/01/01 Included
          Assets:Cash  $5.00
          Equity:Opening
      """)

      content = """
      ; Comment only block
      account Assets:Cash
      alias cash

      include included.ledger
      """

      assert {:ok, [transaction], _accounts} =
               LedgerParser.parse_ledger(
                 content,
                 base_dir: tmp_dir,
                 source_file: "main.ledger"
               )

      assert transaction.payee == "Included"
    end
  end

  describe "parser helpers" do
    test "rejects date strings with trailing content" do
      assert {:error, :invalid_date_format} = LedgerParser.parse_date("2024/01/01 extra")
    end

    test "rejects amount strings with trailing content" do
      assert {:error, :invalid_amount} = LedgerParser.parse_amount("$1.00 extra")
    end

    test "rejects note strings with trailing content" do
      assert {:error, :invalid_note} = LedgerParser.parse_note("; :Tag: extra")
    end
  end

  describe "select/2" do
    test "returns error for invalid query" do
      assert {:error, :invalid_select_query} = LedgerParser.select([], "bad query")
    end

    test "returns error for invalid filter" do
      assert {:error, :invalid_select_query} =
               LedgerParser.select([], "payee from posts where account=~/[/")
    end

    test "filters by tag and commodity" do
      transactions = [
        transaction("Coffee Shop", [
          posting("Expenses:Food", %{value: 5.0, currency: "USD"}, ["meal"]),
          posting("Assets:Cash", %{value: -5.0, currency: "USD"}, [])
        ])
      ]

      query = "payee,amount,commodity,quantity from posts where tag=~/meal/ and commodity=~/USD/"

      assert {:ok, fields, rows} = LedgerParser.select(transactions, query)
      assert fields == ["payee", "amount", "commodity", "quantity"]
      assert length(rows) == 1
      assert Enum.at(rows, 0)["amount"] == "USD 5.00"
    end

    test "formats empty select values" do
      transactions = [
        transaction("Transfer", [posting("Assets:Bank", nil, [])])
      ]

      assert {:ok, fields, rows} =
               LedgerParser.select(transactions, "account,amount,commodity,quantity from posts")

      assert LedgerParser.format_select(fields, rows) == "Assets:Bank\t\t\t\n"
    end

    test "formats date fields" do
      transactions = [
        transaction("Coffee Shop", [posting("Expenses:Food", %{value: 5.0, currency: "$"}, [])])
      ]

      assert {:ok, fields, rows} = LedgerParser.select(transactions, "date from posts")
      assert LedgerParser.format_select(fields, rows) == "2024-01-01\n"
    end

    test "returns error for overly long filter regex" do
      long_pattern = String.duplicate("a", 257)

      assert {:error, :invalid_select_query} =
               LedgerParser.select([], "payee from posts where payee=~/#{long_pattern}/")
    end
  end

  describe "build_xact/3" do
    test "returns error when no transaction matches" do
      transactions = [
        transaction("Coffee Shop", [posting("Expenses:Food", %{value: 5.0, currency: "$"}, [])])
      ]

      assert {:error, :xact_not_found} =
               LedgerParser.build_xact(transactions, ~D[2024-01-01], "Rent")
    end

    test "returns error for invalid regex" do
      transactions = [
        transaction("Coffee Shop", [posting("Expenses:Food", %{value: 5.0, currency: "$"}, [])])
      ]

      long_pattern = String.duplicate("a", 257)

      assert {:error, :invalid_regex} =
               LedgerParser.build_xact(transactions, ~D[2024-01-01], long_pattern)
    end

    test "formats comments in transaction header" do
      transactions = [
        %{
          kind: :regular,
          date: ~D[2024-01-01],
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: "Coffee Shop",
          comment: "note",
          predicate: nil,
          period: nil,
          postings: [posting("Expenses:Food", %{value: 5.0, currency: "$"}, [])]
        }
      ]

      assert {:ok, output} = LedgerParser.build_xact(transactions, ~D[2024-02-02], "Coffee")
      assert output =~ "2024/02/02 Coffee Shop  ; note"
    end

    test "omits amount when posting amount is nil" do
      transactions = [
        transaction("Transfer", [posting("Assets:Bank", nil, [])])
      ]

      assert {:ok, output} = LedgerParser.build_xact(transactions, ~D[2024-02-02], "Transfer")
      assert output =~ "    Assets:Bank"
    end

    test "formats non-dollar currencies" do
      transactions = [
        transaction("Transfer", [posting("Assets:Bank", %{value: 5.0, currency: "CHF"}, [])])
      ]

      assert {:ok, output} = LedgerParser.build_xact(transactions, ~D[2024-02-02], "Transfer")
      assert output =~ "CHF 5.00"
    end
  end

  describe "timeclock parsing" do
    test "ignores invalid check-in lines" do
      output =
        capture_io(:stderr, fn ->
          entries = LedgerParser.parse_timeclock_entries("i 2024/99/99 09:00:00 Work:Project")
          assert entries == []
        end)

      assert output == ""
    end

    test "warns when checkout is invalid" do
      input = """
      i 2024/03/01 09:00:00 Work:Project
      o 2024/03/01 99:00:00
      """

      output =
        capture_io(:stderr, fn ->
          entries = LedgerParser.parse_timeclock_entries(input)
          assert entries == []
        end)

      assert output =~ "unclosed timeclock check-in"
    end

    test "marks cleared entries with uppercase checkout" do
      input = """
      i 2024/03/01 09:00:00 Work:Project
      O 2024/03/01 10:00:00
      """

      entries = LedgerParser.parse_timeclock_entries(input)
      assert Enum.at(entries, 0).cleared
    end

    test "ignores unmatched checkout lines" do
      output =
        capture_io(:stderr, fn ->
          entries = LedgerParser.parse_timeclock_entries("o 2024/03/01 09:00:00")
          assert entries == []
        end)

      assert output == ""
    end
  end

  describe "budget_report/2" do
    test "ignores periodic transactions with unknown period" do
      transactions = [
        %{
          kind: :periodic,
          date: nil,
          aux_date: nil,
          state: :uncleared,
          code: "",
          payee: nil,
          comment: nil,
          predicate: nil,
          period: "Sporadic",
          postings: [
            %{
              account: "Expenses:Misc",
              amount: %{value: 10.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            },
            %{
              account: "Assets:Cash",
              amount: %{value: -10.0, currency: "$"},
              metadata: %{},
              tags: [],
              comments: []
            }
          ]
        }
      ]

      assert LedgerParser.budget_report(transactions, ~D[2024-01-15]) == []
    end

    test "includes periodic multipliers" do
      transactions = [
        periodic("Daily", 3.0),
        periodic("Biweekly", 4.0),
        periodic("Monthly", 5.0),
        periodic("Bimonthly", 6.0),
        periodic("Quarterly", 7.0),
        periodic("Yearly", 8.0)
      ]

      rows = LedgerParser.budget_report(transactions, ~D[2024-01-15])

      assert Enum.any?(rows, fn row -> row.account == "Expenses:Daily" end)
      assert Enum.any?(rows, fn row -> row.account == "Expenses:Biweekly" end)
      assert Enum.any?(rows, fn row -> row.account == "Expenses:Monthly" end)
      assert Enum.any?(rows, fn row -> row.account == "Expenses:Bimonthly" end)
      assert Enum.any?(rows, fn row -> row.account == "Expenses:Quarterly" end)
      assert Enum.any?(rows, fn row -> row.account == "Expenses:Yearly" end)
    end
  end

  describe "format_budget_report/1" do
    test "renders header and rows" do
      rows = [
        %{
          account: "Expenses:Rent",
          currency: "$",
          actual: 500.0,
          budget: 1000.0,
          remaining: 500.0
        }
      ]

      output = LedgerParser.format_budget_report(rows)

      assert output =~ "Actual"
      assert output =~ "Budget"
      assert output =~ "Remaining"
      assert output =~ "Expenses:Rent"
    end
  end

  describe "format_stats/1" do
    test "formats empty statistics" do
      stats = LedgerParser.stats([])
      output = LedgerParser.format_stats(stats)

      assert output =~ "Time range of all postings: N/A"
      assert output =~ "Days since last posting: N/A"
    end
  end

  describe "format_timeclock_report/1" do
    test "formats timeclock report lines" do
      report = %{"Work:Admin" => 2.0, "Work:Project" => 1.5}

      output = LedgerParser.format_timeclock_report(report)

      assert output =~ "Work:Admin"
      assert output =~ "Work:Project"
      assert output =~ "2.00"
      assert output =~ "1.50"
    end
  end

  describe "format_balance/2" do
    test "formats empty balances" do
      output = LedgerParser.format_balance(%{})

      assert String.starts_with?(output, "--------------------\n")
    end

    test "formats multi-currency totals" do
      balances = %{
        "Assets:Cash" => [%{amount: 10.0, currency: "$"}],
        "Assets:Bank" => [%{amount: 5.0, currency: "EUR"}]
      }

      output = LedgerParser.format_balance(balances)

      assert output =~ "$10.00"
      assert output =~ "EUR 5.00"
    end

    test "normalizes tiny totals to zero" do
      balances = %{
        "Assets:Cash" => [%{amount: 0.004, currency: "$"}]
      }

      output = LedgerParser.format_balance(balances)

      assert output =~ "$0.00"
    end
  end

  describe "balance_by_period/5" do
    test "calculates daily balances" do
      transactions = [transaction("Coffee", [simple_posting("Expenses:Food", 5.0)])]

      result = LedgerParser.balance_by_period(transactions, "daily")

      assert Enum.at(result["periods"], 0).label == "2024-01-01"
      assert result["balances"]["2024-01-01"]["Expenses:Food"] |> hd() |> Map.get(:amount) == 5.0
    end

    test "calculates weekly balances" do
      transactions = [transaction("Coffee", [simple_posting("Expenses:Food", 5.0)])]

      result = LedgerParser.balance_by_period(transactions, "weekly")

      assert Enum.at(result["periods"], 0).label =~ "Week"
      assert result["balances"][Enum.at(result["periods"], 0).label]["Expenses:Food"] |> hd() |> Map.get(:amount) == 5.0
    end

    test "returns empty periods for unknown grouping" do
      transactions = [transaction("Coffee", [simple_posting("Expenses:Food", 5.0)])]

      result = LedgerParser.balance_by_period(transactions, "unknown")

      assert result == %{"periods" => [], "balances" => %{}}
    end

    test "filters balances with account_filter" do
      transactions = [
        transaction("Coffee", [
          simple_posting("Expenses:Food", 5.0),
          simple_posting("Assets:Cash", -5.0)
        ])
      ]

      filter = fn account -> String.starts_with?(account, "Expenses") end

      result = LedgerParser.balance_by_period(transactions, "monthly", nil, nil, filter)

      assert Map.has_key?(result["balances"]["2024-01"], "Expenses:Food")
      refute Map.has_key?(result["balances"]["2024-01"], "Assets:Cash")
    end

    test "returns empty when no regular transactions" do
      transactions = [periodic("Monthly", 10.0)]

      result = LedgerParser.balance_by_period(transactions, "monthly")

      assert result == %{"periods" => [], "balances" => %{}}
    end
  end

  describe "extract_account_declarations/1" do
    test "ignores invalid standalone aliases" do
      input = """
      alias =
      account Assets:Checking
      """

      accounts = LedgerParser.extract_account_declarations(input)
      assert accounts == %{"Assets:Checking" => :asset}
    end

    test "ignores unsupported account block lines" do
      input = """
      account Expenses:Meals
              note should be ignored
      """

      accounts = LedgerParser.extract_account_declarations(input)

      assert accounts["Expenses:Meals"] == :asset
      assert map_size(accounts) == 1
    end
  end

  describe "parse_posting/1" do
    test "returns error for invalid posting" do
      assert {:error, :invalid_posting} = LedgerParser.parse_posting("")
    end
  end

  describe "parse_note/1" do
    test "returns error for invalid note" do
      assert {:error, :invalid_note} = LedgerParser.parse_note("Not a note")
    end
  end

  describe "list_commodities/1" do
    test "ignores postings without amounts" do
      transactions = [transaction("No Amount", [posting("Assets:Cash", nil, [])])]

      assert LedgerParser.list_commodities(transactions) == []
    end
  end

  defp transaction(payee, postings) do
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

  defp posting(account, amount, tags) do
    %{
      account: account,
      amount: amount,
      metadata: %{},
      tags: tags,
      comments: []
    }
  end

  defp simple_posting(account, value) do
    posting(account, %{value: value, currency: "$"}, [])
  end

  defp periodic(period, value) do
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
          amount: %{value: value, currency: "$"},
          metadata: %{},
          tags: [],
          comments: []
        },
        %{
          account: "Assets:Cash",
          amount: %{value: -value, currency: "$"},
          metadata: %{},
          tags: [],
          comments: []
        }
      ]
    }
  end
end
