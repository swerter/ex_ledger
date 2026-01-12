defmodule ExLedger.RegisterPrintCheckTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  @fixtures_dir Path.expand("fixtures", __DIR__)

  test "register lists postings and supports account filtering" do
    ledger = """
    2024/01/01 Opening
        Assets:Cash  $10
        Equity:Opening

    2024/01/02 Lunch
        Expenses:Food  $-5
        Assets:Cash
    """

    file = write_fixture("register_sample.ledger", ledger)

    output =
      capture_io(fn ->
        ExLedger.CLI.main(["-f", file, "register", "Assets:Cash"])
      end)

    assert output =~ "Assets:Cash"
    assert output =~ "Opening"
    assert output =~ "Lunch"
    refute output =~ "Expenses:Food"
  end

  test "print outputs ledger-formatted transactions" do
    ledger = """
    2024/01/01 Opening
        Assets:Cash  $10
        Equity:Opening
    """

    file = write_fixture("print_sample.ledger", ledger)

    output =
      capture_io(fn ->
        ExLedger.CLI.main(["-f", file, "print"])
      end)

    assert output =~ "2024/01/01 Opening"
    assert output =~ "Assets:Cash"
    assert output =~ "Equity:Opening"
  end

  test "check validates accounts, payees, commodities, and tags" do
    ledger = """
    commodity $
    account Assets:Cash  ; type:asset
    account Equity:Opening  ; type:equity
    payee Store
    tag lunch

    2024/01/01 Store  ; lunch:
        Assets:Cash  $10
        Equity:Opening
    """

    file = write_fixture("check_sample.ledger", ledger)

    output =
      capture_io(fn ->
        ExLedger.CLI.main(["-f", file, "check"])
      end)

    assert output == ""
  end

  test "check reports missing account declarations" do
    ledger = """
    commodity $
    account Assets:Cash  ; type:asset

    2024/01/01 Store
        Assets:Cash  $10
        Equity:Opening
    """

    {:ok, transactions, _accounts} = ExLedger.LedgerParser.parse_ledger(ledger)
    accounts = ExLedger.LedgerParser.extract_account_declarations(ledger)

    assert {:error, "Equity:Opening"} =
             ExLedger.LedgerParser.check_accounts(transactions, accounts)
  end

  test "check reports missing payee declarations" do
    ledger = """
    2024/01/01 Store
        Assets:Cash  $10
        Equity:Opening
    """

    {:ok, transactions, _accounts} = ExLedger.LedgerParser.parse_ledger(ledger)
    declared = ExLedger.LedgerParser.extract_payee_declarations(ledger)

    assert {:error, "Store"} = ExLedger.LedgerParser.check_payees(transactions, declared)
  end

  defp write_fixture(name, contents) do
    path = Path.join(@fixtures_dir, name)
    File.write!(path, contents)
    path
  end
end
