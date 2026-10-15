defmodule SymphonyElixir.GovernanceRequestSnapshot do
  @moduledoc "Builds a safe, complete source snapshot from the authorized Issue readback, never model prose."
  @private_key ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/
  @bare_secret ~r/\b(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|sk-[A-Za-z0-9_-]{12,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\b/
  @credential_header ~r/(?im)((?:authorization|proxy-authorization|cookie|set-cookie)\s*:\s*)[^\r\n]+/
  @url_userinfo ~r{(https?://)[^/\s@]+@}i
  @email ~r/\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b/i
  @phone ~r/(?i)((?:phone|mobile|telephone|tel[eé]fono)\s*:\s*)\+?[0-9][0-9 ()\-]{6,}[0-9]/

  def build(%{"number" => number, "title" => title, "body" => body, "definitionDigest" => digest} = source, repository_id)
      when is_integer(number) and number > 0 and is_binary(title) and is_binary(body) and is_binary(digest) do
    if Regex.match?(~r/^sha256:[0-9a-f]{64}$/, digest) do
      safe_body = sanitize(body)
      safe_title = sanitize(title)

      snapshot = %{
        "schemaVersion" => 1,
        "number" => number,
        "title" => safe_title,
        "url" => safe_url(source["url"]),
        "bodySanitized" => safe_body,
        "definitionDigest" => digest,
        "provenance" => %{
          "source" => "game-api",
          "operation" => "fetch_issue",
          "repositoryId" => repository_id,
          "definitionDigestKind" => "exact-github-body-sha256",
          "sanitizationPolicy" => "request-snapshot-1",
          "redactionApplied" => safe_body != body or safe_title != title
        }
      }

      {:ok, if(is_binary(source["createdAt"]), do: Map.put(snapshot, "createdAt", source["createdAt"]), else: snapshot)}
    else
      {:error, :governance_request_snapshot_unavailable}
    end
  end

  def build(_, _), do: {:error, :governance_request_snapshot_unavailable}

  def sanitize(text) do
    text
    |> then(&Regex.replace(@credential_header, &1, "\\1[REDACTED]"))
    |> then(&Regex.replace(@url_userinfo, &1, "\\1[REDACTED_CREDENTIALS]@"))
    |> SymphonyElixir.Audit.Outbox.redact_text_for_evidence()
    |> then(&Regex.replace(@private_key, &1, "[REDACTED_PRIVATE_KEY]"))
    |> then(&Regex.replace(@bare_secret, &1, "[REDACTED_SECRET]"))
    |> then(&Regex.replace(@email, &1, "[REDACTED_EMAIL]"))
    |> then(&Regex.replace(@phone, &1, "\\1[REDACTED_PHONE]"))
  end

  defp safe_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["http", "https"] and is_binary(host) ->
        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})

      _ ->
        nil
    end
  end

  defp safe_url(_), do: nil
end
