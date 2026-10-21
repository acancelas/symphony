defmodule SymphonyElixir.GovernanceBuildReceiptTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GovernanceBuildReceipt

  test "whole-root receipts also seal new top-level imports" do
    root = Path.join(System.tmp_dir!(), "bos-root-receipt-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    receipt = root <> ".receipt.json"

    on_exit(fn ->
      File.rm(receipt)
      File.rm_rf!(root)
    end)

    File.write!(root <> "/module", "trusted")

    bytes =
      Jason.encode!(%{
        "files" => %{"module" => GovernanceBuildReceipt.file_digest(root <> "/module")},
        "sealedDirectories" => ["."]
      })

    File.write!(receipt, bytes)
    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert {:ok, _} = GovernanceBuildReceipt.verify(root, receipt, digest)
    File.write!(root <> "/extra", "untrusted")
    assert {:error, _} = GovernanceBuildReceipt.verify(root, receipt, digest)
  end

  test "full build pins contents, rejects added imports and outside symlink dependencies" do
    root = Path.join(System.tmp_dir!(), "governance-receipt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "dist"))
    on_exit(fn -> File.rm_rf!(root) end)
    entry = Path.join(root, "dist/entry.js")
    File.write!(entry, "safe-pinned-build")
    receipt = Path.join(root, "receipt.json")

    bytes =
      Jason.encode!(%{
        "files" => %{"dist/entry.js" => GovernanceBuildReceipt.file_digest(entry)},
        "sealedDirectories" => ["dist"]
      })

    File.write!(receipt, bytes)
    digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert {:ok, _} = GovernanceBuildReceipt.verify(root, receipt, digest)
    File.write!(Path.join(root, "dist/extra.js"), "unreviewed-import")
    assert {:error, _} = GovernanceBuildReceipt.verify(root, receipt, digest)
    File.rm!(Path.join(root, "dist/extra.js"))
    File.write!(entry, "changed-build")
    assert {:error, _} = GovernanceBuildReceipt.verify(root, receipt, digest)
    File.rm!(entry)
    File.ln_s!("/etc/hosts", entry)
    assert {:error, _} = GovernanceBuildReceipt.verify(root, receipt, digest)
    assert {:error, _} = GovernanceBuildReceipt.verify(root, receipt, String.duplicate("0", 64))
  end
end
