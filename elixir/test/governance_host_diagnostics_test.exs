defmodule SymphonyElixir.GovernanceHostDiagnosticsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{GovernanceHostDiagnostics, GovernanceToolBoundary}

  test "transport identity changes per invocation and payload without changing immutable artifact ID" do
    original = %{"operationId" => "logical-stable-op", "artifact" => %{"governanceId" => "logical-stable-gov", "summary" => "same-body"}}
    one = GovernanceToolBoundary.bind_operation("bos_record_governance", original, "inv-one")
    assert one == GovernanceToolBoundary.bind_operation("bos_record_governance", original, "inv-one")
    refute one["operationId"] == GovernanceToolBoundary.bind_operation("bos_record_governance", original, "inv-two")["operationId"]
    refute one["operationId"] == GovernanceToolBoundary.bind_operation("bos_record_governance", put_in(original, ["artifact", "summary"], "corrected-body"), "inv-one")["operationId"]
    assert one["artifact"] == original["artifact"]
    assert original == GovernanceToolBoundary.bind_operation("bos_get_issue", original, "inv-one")
  end

  test "native terminal status distinguishes completed from failed or interrupted notifications" do
    for status <- ~w(completed failed interrupted cancelled) do
      assert status == GovernanceHostDiagnostics.terminal_status(%{"method" => "turn/completed", "params" => %{"turn" => %{"status" => status}}})
    end

    assert nil == GovernanceHostDiagnostics.terminal_status(%{"method" => "item/completed"})
  end

  test "diagnostics retain status and code but no request, body, credential or error details" do
    raw = %{
      "isError" => true,
      "content" => [
        %{
          "type" => "text",
          "text" => Jason.encode!(%{"error" => %{"code" => "forbidden", "message" => "SYNTHETIC_PRIVATE_SECRET", "details" => %{"status" => 403, "authorization" => "SYNTHETIC_PRIVATE_SECRET"}}})
        }
      ]
    }

    result = GovernanceHostDiagnostics.outcome({:ok, raw})
    assert result == %{privateMcpInvoked: true, success: false, errorCode: "forbidden", httpStatus: 403}
    refute Jason.encode!(result) =~ "SYNTHETIC_PRIVATE_SECRET"
  end
end
