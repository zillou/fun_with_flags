if Code.ensure_loaded?(Ecto) do

defmodule FunWithFlags.Store.Persistent.Ecto do
  @moduledoc false

  @behaviour FunWithFlags.Store.Persistent

  alias FunWithFlags.Gate
  alias FunWithFlags.Store.Persistent.Ecto.Record
  alias FunWithFlags.Store.Serializer.Ecto, as: Serializer

  import FunWithFlags.Config, only: [ecto_repo: 0, ecto_table_name: 0]
  import Ecto.Query

  require Logger

  @mysql_lock_timeout_s 3


  @impl true
  def worker_spec do
    nil
  end


  @impl true
  def get(flag_name) do
    name_string = to_string(flag_name)
    query = from(r in Record, where: r.flag_name == ^name_string)
    try do
      results = ecto_repo().all(query)
      flag = deserialize(flag_name, results)
      {:ok, flag}
    rescue
      e in [Ecto.QueryError] -> {:error, e}
    end
  end


  @impl true
  def put(flag_name, gate = %Gate{type: type})
  when type in [:percentage_of_time, :percentage_of_actors] do
    name_string = to_string(flag_name)

    find_one_q = from(
      r in Record,
      where: r.flag_name == ^name_string,
      where: r.gate_type == "percentage"
    )

    transaction_fn = case db_type() do
      :postgres -> &_transaction_with_lock_postgres/1
      :mysql -> &_transaction_with_lock_mysql/1
    end

    out = transaction_fn.(fn() ->
      case ecto_repo().one(find_one_q) do
        record = %Record{} ->
          changeset = Record.update_target(record, gate)
          do_update(flag_name, changeset)
        nil ->
          changeset = Record.build(flag_name, gate)
          do_insert(flag_name, changeset)
      end
    end)


    case out do
      {:ok, {:ok, result}} ->
        {:ok, result}
      {:error, _} = error ->
        error
    end
  end


  @impl true
  def put(flag_name, gate = %Gate{}) do
    changeset = Record.build(flag_name, gate)
    options = upsert_options(gate)

    case do_insert(flag_name, changeset, options) do
      {:ok, flag} ->
        {:ok, flag}
      other ->
        other
    end
  end


  defp _transaction_with_lock_postgres(upsert_fn) do
    ecto_repo().transaction fn() ->
      postgres_table_lock!()
      upsert_fn.()
    end
  end

  defp _transaction_with_lock_mysql(upsert_fn) do
    ecto_repo().transaction fn() ->
      if mysql_lock!() do
        try do
          upsert_fn.()
        rescue
          e ->
            ecto_repo().rollback("Exception: #{inspect(e)}")
        else
          {:error, reason} ->
            ecto_repo().rollback("Error while upserting the gate: #{inspect(reason)}")
          {:ok, value} ->
            {:ok, value}
        after
          # This is not guaranteed to run if the VM crashes, but at least the
          # lock gets released when the MySQL client session is terminated.
          mysql_unlock!()
        end
      else
        Logger.error("Couldn't acquire lock with 'SELECT GET_LOCK()' after #{@mysql_lock_timeout_s} seconds")
        ecto_repo().rollback("couldn't acquire lock")
      end
    end
  end


  @impl true
  def delete(flag_name, %Gate{type: type})
  when type in [:percentage_of_time, :percentage_of_actors] do
    name_string = to_string(flag_name)

    query = from(
      r in Record,
      where: r.flag_name == ^name_string
      and r.gate_type == "percentage"
    )

    try do
      {_count, _} = ecto_repo().delete_all(query)
      {:ok, flag} = get(flag_name)
      {:ok, flag}
    rescue
      e in [Ecto.QueryError] -> {:error, e}
    end
  end


  # Deletes one gate from the toggles table in the DB.
  # Deleting gates is idempotent and deleting unknown gates is safe.
  # A flag will continue to exist even though it has no gates.
  #
  @impl true
  def delete(flag_name, gate = %Gate{}) do
    name_string = to_string(flag_name)
    gate_type = to_string(gate.type)
    target    = Record.serialize_target(gate.for)

    query = from(
      r in Record,
      where: r.flag_name == ^name_string
      and r.gate_type == ^gate_type
      and r.target == ^target
    )

    try do
      {_count, _} = ecto_repo().delete_all(query)
      {:ok, flag} = get(flag_name)
      {:ok, flag}
    rescue
      e in [Ecto.QueryError] -> {:error, e}
    end
  end


  # Deletes all of of this flags' gates from the toggles table, thus deleting
  # the entire flag.
  # Deleting flags is idempotent and deleting unknown flags is safe.
  # After the operation fetching the now-deleted flag will return the default
  # empty flag structure.
  #
  @impl true
  def delete(flag_name) do
    name_string = to_string(flag_name)

    query = from(
      r in Record,
      where: r.flag_name == ^name_string
    )

    try do
      {_count, _} = ecto_repo().delete_all(query)
      {:ok, flag} = get(flag_name)
      {:ok, flag}
    rescue
      e in [Ecto.QueryError] -> {:error, e}
    end
  end


  @impl true
  def all_flags do
    flags =
      Record
      |> ecto_repo().all()
      |> Enum.group_by(&(&1.flag_name))
      |> Enum.map(fn ({name, records}) -> deserialize(name, records) end)
    {:ok, flags}
  end


  @impl true
  def all_flag_names do
    query = from(r in Record, select: r.flag_name, distinct: true)
    strings = ecto_repo().all(query)
    atoms = Enum.map(strings, &String.to_atom(&1))
    {:ok, atoms}
  end


  defp deserialize(flag_name, records) do
    Serializer.deserialize_flag(flag_name, records)
  end


  defp postgres_table_lock! do
    Ecto.Adapters.SQL.query!(
      ecto_repo(),
      "LOCK TABLE #{ecto_table_name()} IN SHARE ROW EXCLUSIVE MODE;"
    )
  end


  defp mysql_lock! do
    result = Ecto.Adapters.SQL.query!(
      ecto_repo(),
      "SELECT GET_LOCK('fun_with_flags_percentage_gate_upsert', #{@mysql_lock_timeout_s})"
    )

    %{rows: [[i]]} = result
    i == 1
  end


  defp mysql_unlock! do
    result = Ecto.Adapters.SQL.query!(
      ecto_repo(),
      "SELECT RELEASE_LOCK('fun_with_flags_percentage_gate_upsert');"
    )

    %{rows: [[i]]} = result
    i == 1
  end


  # PostgreSQL's UPSERTs require an explicit conflict target.
  # MySQL's UPSERTs don't need it.
  #
  defp upsert_options(gate = %Gate{}) do
    options = [on_conflict: [set: [enabled: gate.enabled]]]

    case db_type() do
      :postgres ->
        options ++ [conflict_target: [:flag_name, :gate_type, :target]]
      :mysql ->
        options
    end
  end


  defp db_type do
    case ecto_repo().__adapter__() do
      Ecto.Adapters.Postgres -> :postgres
      Ecto.Adapters.MySQL -> :mysql # legacy, Mariaex
      Ecto.Adapters.MyXQL -> :mysql # new in ecto_sql 3.1
      other -> raise "Ecto adapter #{inspect(other)} is not supported"
    end
  end


  defp do_insert(flag_name, changeset, options \\ []) do
    changeset
    |> ecto_repo().insert(options)
    |> handle_write(flag_name)
  end


  defp do_update(flag_name, changeset, options \\ []) do
    changeset
    |> ecto_repo().update(options)
    |> handle_write(flag_name)
  end


  defp handle_write(result, flag_name) do
    case result do
      {:ok, %Record{}} ->
        get(flag_name) # {:ok, flag}
      {:error, bad_changeset} ->
        {:error, bad_changeset.errors}
    end
  end

end

end # Code.ensure_loaded?
