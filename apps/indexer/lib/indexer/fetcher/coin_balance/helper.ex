defmodule Indexer.Fetcher.CoinBalance.Helper do
  @moduledoc """
  Common functions for `Indexer.Fetcher.CoinBalance.Catchup` and `Indexer.Fetcher.CoinBalance.Realtime` modules
  """

  import EthereumJSONRPC, only: [integer_to_quantity: 1, quantity_to_integer: 1]

  require Logger

  alias EthereumJSONRPC.{Blocks, FetchedBalances, Utility.RangesHelper}
  alias Explorer.Chain
  alias Explorer.Chain.Cache.Accounts
  alias Explorer.Chain.Hash

  def run(entries, json_rpc_named_arguments) do
    # the same address may be used more than once in the same block, but we only want one `Balance` for a given
    # `{address, block}`, so take unique params only
    unique_entries = Enum.uniq(entries)

    unique_filtered_entries =
      Enum.filter(unique_entries, fn {_hash, block_number} -> RangesHelper.traceable_block_number?(block_number) end)

    unique_entry_count = Enum.count(unique_filtered_entries)
    Logger.metadata(count: unique_entry_count)

    Logger.debug(fn -> "fetching" end)

    unique_filtered_entries
    |> Enum.map(&entry_to_params/1)
    |> EthereumJSONRPC.fetch_balances(json_rpc_named_arguments)
    |> case do
      {:ok, fetched_balances} ->
        run_fetched_balances(fetched_balances, unique_filtered_entries)

      {:error, reason} ->
        Logger.error(
          fn ->
            ["failed to fetch: ", inspect(reason)]
          end,
          error_count: unique_entry_count
        )

        {:retry, unique_filtered_entries}
    end
  end

  def entry(%{address_hash: %Hash{bytes: address_hash_bytes}, block_number: block_number}) do
    {address_hash_bytes, block_number}
  end

  defp entry_to_params({address_hash_bytes, block_number}) when is_integer(block_number) do
    {:ok, address_hash} = Hash.Address.cast(address_hash_bytes)
    %{block_quantity: integer_to_quantity(block_number), hash_data: to_string(address_hash)}
  end

  # We want to record all historical balances for an address, but have the address itself have balance from the
  # `Balance` with the greatest block_number for that address.
  def balances_params_to_address_params(balances_params) do
    balances_params
    |> Enum.group_by(fn %{address_hash: address_hash} -> address_hash end)
    |> Map.values()
    |> Stream.map(&Enum.max_by(&1, fn %{block_number: block_number} -> block_number end))
    |> Enum.map(fn %{address_hash: address_hash, block_number: block_number, value: value} ->
      %{hash: address_hash, fetched_coin_balance_block_number: block_number, fetched_coin_balance: value}
    end)
  end

  def import_fetched_balances(%FetchedBalances{params_list: params_list}, broadcast_type \\ false) do
    value_fetched_at = DateTime.utc_now()

    importable_balances_params = Enum.map(params_list, &Map.put(&1, :value_fetched_at, value_fetched_at))

    json_rpc_named_arguments = Application.get_env(:explorer, :json_rpc_named_arguments)

    importable_balances_daily_params = balances_daily_params(params_list, json_rpc_named_arguments)

    addresses_params = balances_params_to_address_params(importable_balances_params)

    Chain.import(%{
      addresses: %{params: addresses_params, with: :balance_changeset},
      address_coin_balances: %{params: importable_balances_params},
      address_coin_balances_daily: %{params: importable_balances_daily_params},
      broadcast: broadcast_type
    })
  end

  def import_fetched_daily_balances(%FetchedBalances{params_list: params_list}, broadcast_type \\ false) do
    value_fetched_at = DateTime.utc_now()

    importable_balances_params = Enum.map(params_list, &Map.put(&1, :value_fetched_at, value_fetched_at))

    json_rpc_named_arguments = Application.get_env(:explorer, :json_rpc_named_arguments)

    importable_balances_daily_params = balances_daily_params(params_list, json_rpc_named_arguments)

    addresses_params = balances_params_to_address_params(importable_balances_params)

    Chain.import(%{
      addresses: %{params: addresses_params, with: :balance_changeset},
      address_coin_balances_daily: %{params: importable_balances_daily_params},
      broadcast: broadcast_type
    })
  end

  defp run_fetched_balances(%FetchedBalances{errors: errors} = fetched_balances, _) do
    with {:ok, imported} <- import_fetched_balances(fetched_balances) do
      Accounts.drop(imported[:addresses])
    end

    retry(errors)
  end

  defp retry([]), do: :ok

  defp retry(errors) when is_list(errors) do
    retried_entries = fetched_balances_errors_to_entries(errors)

    Logger.error(
      fn ->
        [
          "failed to fetch: ",
          fetched_balance_errors_to_iodata(errors)
        ]
      end,
      error_count: Enum.count(retried_entries)
    )

    {:retry, retried_entries}
  end

  defp fetched_balances_errors_to_entries(errors) when is_list(errors) do
    Enum.map(errors, &fetched_balance_error_to_entry/1)
  end

  defp fetched_balance_error_to_entry(%{data: %{block_quantity: block_quantity, hash_data: hash_data}})
       when is_binary(block_quantity) and is_binary(hash_data) do
    {:ok, %Hash{bytes: address_hash_bytes}} = Hash.Address.cast(hash_data)
    block_number = quantity_to_integer(block_quantity)
    {address_hash_bytes, block_number}
  end

  defp fetched_balance_errors_to_iodata(errors) when is_list(errors) do
    fetched_balance_errors_to_iodata(errors, [])
  end

  defp fetched_balance_errors_to_iodata([], iodata), do: iodata

  defp fetched_balance_errors_to_iodata([error | errors], iodata) do
    fetched_balance_errors_to_iodata(errors, [iodata | fetched_balance_error_to_iodata(error)])
  end

  defp fetched_balance_error_to_iodata(%{
         code: code,
         message: message,
         data: %{block_quantity: block_quantity, hash_data: hash_data}
       })
       when is_integer(code) and is_binary(message) and is_binary(block_quantity) and is_binary(hash_data) do
    [hash_data, "@", quantity_to_integer(block_quantity), ": (", to_string(code), ") ", message, ?\n]
  end

  def block_timestamp_map(params_list, json_rpc_named_arguments) do
    block_numbers =
      params_list
      |> Enum.map(&Map.get(&1, :block_number))
      |> Enum.sort()
      |> Enum.dedup()

    Enum.reduce(block_numbers, %{}, fn block_number, map ->
      case EthereumJSONRPC.fetch_blocks_by_range(block_number..block_number, json_rpc_named_arguments) do
        {:ok, %Blocks{blocks_params: [%{timestamp: timestamp}]}} ->
          day = DateTime.to_date(timestamp)
          Map.put(map, "#{block_number}", day)

        _ ->
          %{}
      end
    end)
  end

  defp balances_daily_params(params_list, json_rpc_named_arguments) do
    block_timestamp_map = block_timestamp_map(params_list, json_rpc_named_arguments)

    params_list
    |> Enum.map(fn balance_param ->
      if Map.has_key?(block_timestamp_map, "#{balance_param.block_number}") do
        day = Map.get(block_timestamp_map, "#{balance_param.block_number}")

        incoming_balance_daily_param = %{
          address_hash: balance_param.address_hash,
          day: day,
          value: balance_param.value
        }

        incoming_balance_daily_param
      else
        nil
      end
    end)
  end
end
