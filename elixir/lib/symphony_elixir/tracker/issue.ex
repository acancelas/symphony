defmodule SymphonyElixir.Tracker.Issue do
  @moduledoc """
  Normalized work item representation used by the orchestrator.

  `id` is the stable dispatch identity for the configured tracker scope. It may
  differ from a provider's underlying issue ID when the scheduled item is a
  board or project entry. `native_ref` carries non-secret provider identifiers
  needed by provider-native agent tools. `identifier` remains the human-readable
  value used to derive the workspace key and must be unique within that scope.
  """

  defstruct [
    :id,
    :native_ref,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    blocked_by: [],
    labels: [],
    dispatchable: false,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          native_ref: map() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          labels: [String.t()],
          blocked_by: [map()],
          dispatchable: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @spec routable?(t(), [String.t()]) :: boolean()
  def routable?(%__MODULE__{dispatchable: true, labels: labels}, required_labels)
      when is_list(labels) and is_list(required_labels) do
    issue_labels = MapSet.new(labels, &normalize_label/1)
    Enum.all?(required_labels, &MapSet.member?(issue_labels, normalize_label(&1)))
  end

  def routable?(%__MODULE__{}, _required_labels), do: false

  @doc """
  Returns the canonical repository identity carried by a work item.

  BOS issues expose it explicitly through `native_ref`. The stable dispatch ID
  remains a safe fallback for recovered projections created by older runtimes.
  Tracker types without repository ownership return `nil` and are therefore not
  subject to repository-scoped serialization.
  """
  @spec repository_id(t()) :: String.t() | nil
  def repository_id(%__MODULE__{native_ref: native_ref, id: id}) do
    explicit =
      if is_map(native_ref) do
        Map.get(native_ref, "repositoryId") || Map.get(native_ref, :repository_id)
      end

    normalize_repository_id(explicit) || repository_id_from_dispatch_id(id)
  end

  defp repository_id_from_dispatch_id(id) when is_binary(id) do
    case String.split(id, "#", parts: 2) do
      [repository_id, issue_number] when repository_id != "" and issue_number != "" ->
        normalize_repository_id(repository_id)

      _ ->
        nil
    end
  end

  defp repository_id_from_dispatch_id(_id), do: nil

  defp normalize_repository_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_repository_id(_value), do: nil

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end
end
