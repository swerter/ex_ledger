defmodule ExLedger.LedgerCLIRunTest do
  use ExUnit.Case
  alias ExLedger.TestHelpers

  describe "run/2" do
    test "returns output when command succeeds" do
      echo = TestHelpers.find_executable!("echo")

      assert {:ok, output} = ExLedger.LedgerCLI.run(["hello", "world"], ledger_bin: echo)
      assert output == "hello world\n"
    end

    test "uses default ledger binary when not specified" do
      tmp_dir = TestHelpers.tmp_dir!("ex_ledger_ledger")

      ledger_path = Path.join(tmp_dir, "ledger")
      File.write!(ledger_path, "#!/bin/sh\necho default-ledger \"$@\"\n")
      File.chmod!(ledger_path, 0o755)

      original_path = System.get_env("PATH") || ""
      env_path = tmp_dir <> ":" <> original_path

      System.put_env("PATH", env_path)

      on_exit(fn ->
        System.put_env("PATH", original_path)
      end)

      assert {:ok, output} =
               ExLedger.LedgerCLI.run(["balance"], cmd_opts: [env: [{"PATH", env_path}]])

      assert output == "default-ledger balance\n"
    end

    test "returns error tuple on non-zero exit" do
      sh = TestHelpers.find_executable!("sh")

      assert {:error, {2, ""}} = ExLedger.LedgerCLI.run(["-c", "exit 2"], ledger_bin: sh)
    end
  end

  describe "run_with_file/4" do
    test "includes file and command in args" do
      echo = TestHelpers.find_executable!("echo")

      assert {:ok, output} =
               ExLedger.LedgerCLI.run_with_file(
                 "/tmp/ledger.dat",
                 "balance",
                 ["Assets"],
                 ledger_bin: echo
               )

      assert output == "-f /tmp/ledger.dat balance Assets\n"
    end

    test "uses default args when none provided" do
      echo = TestHelpers.find_executable!("echo")

      assert {:ok, output} =
               ExLedger.LedgerCLI.run_with_file("/tmp/ledger.dat", "balance", [],
                 ledger_bin: echo
               )

      assert output == "-f /tmp/ledger.dat balance\n"
    end
  end
end
