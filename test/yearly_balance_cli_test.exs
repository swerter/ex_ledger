defmodule ExLedger.YearlyBalanceCLITest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  @fixtures_dir Path.expand("fixtures", __DIR__)

  test "-Y balance groups by year" do
    ledger = """
    2024/01/01 Opening
        Assets:Cash  $100
        Equity:Opening

    2025/01/01 Lunch
        Expenses:Food  $20
        Assets:Cash  $-20
    """

    file = write_fixture("yearly_balance_sample.ledger", ledger)

    output =
      capture_io(fn ->
        ExLedger.CLI.main(["-f", file, "-Y", "balance"])
      end)

    assert output =~ "Balance changes in 2024-01-01..2025-12-31:"
    assert output =~ "2024"
    assert output =~ "2025"
    assert output =~ "Assets:Cash"
    assert output =~ "$100.00"
    assert output =~ "$-20.00"
  end

  defp write_fixture(name, contents) do
    path = Path.join(@fixtures_dir, name)
    File.write!(path, contents)
    path
  end
end
