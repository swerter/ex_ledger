ExUnit.start()

defmodule ExLedger.TestHelpers do
  import ExUnit.Assertions
  import ExUnit.Callbacks

  def find_executable!(name) do
    System.find_executable(name) || flunk("#{name} executable not found")
  end

  def require_executable(name) do
    case System.find_executable(name) do
      nil -> {:skip, "#{name} executable not available"}
      executable -> {:ok, executable}
    end
  end

  def tmp_dir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    dir
  end
end
