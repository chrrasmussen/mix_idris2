defmodule Mix.Tasks.Compile.Blodwen do
  use Mix.Task.Compiler

  @recursive true
  @manifest "compile.blodwen"
  @manifest_vsn 1

  @switches [
    force: :boolean,
    all_warnings: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    project = Mix.Project.config()
    entrypoints = project[:blodwen_entrypoints] || []

    dest = Mix.Project.compile_path(project)

    manifest = read_manifest(manifest_file())

    # Force recompile if any config files has been updated since last compile
    configs = [Mix.Project.config_mtime()]
    force = opts[:force] || Mix.Utils.stale?(configs, [manifest_file()])

    annotated_entrypoints = Enum.map(entrypoints, &annotate_entrypoint(&1, [:blod]))

    opts = Keyword.merge(project[:blodwen_options] || [], opts)
    result = do_run(manifest, annotated_entrypoints, dest, force, opts)

    case result do
      {:ok, _} ->
        # Update manifest
        timestamp = System.os_time(:second)
        new_manifest = Enum.map(annotated_entrypoints, &annotated_entrypoint_to_manifest_entry/1)
        write_manifest(manifest_file(), new_manifest, timestamp)
    end

    result
  end

  @impl true
  def manifests, do: [manifest_file()]

  defp manifest_file, do: Path.join(Mix.Project.manifest_path(), @manifest)

  @impl true
  def clean() do
    dest = Mix.Project.compile_path()
    do_clean(manifest_file(), dest)
  end

  # Helper functions

  defp do_run(manifest, entrypoints, dest, force, _opts) do
    # Calculate added/changed/removed modules

    manifest_erl_modules = Enum.map(manifest, &elem(&1, 0))
    entrypoints_erl_modules = Enum.map(entrypoints, &elem(&1, 0))

    %{added: added, existing: existing, removed: removed} =
      calc_diff(manifest_erl_modules, entrypoints_erl_modules)

    changed =
      existing
      |> Enum.filter(&erl_module_changed?(manifest, entrypoints, &1))
      |> MapSet.new()

    # Clean up removed modules

    Enum.each(removed, fn erl_module ->
      delete_erl_module(dest, erl_module)
    end)

    # Recompile changed modules

    to_be_compiled =
      if force,
        do: entrypoints_erl_modules,
        else: MapSet.union(added, changed)

    Enum.each(to_be_compiled, fn erl_module ->
      {_, blodwen_root_dir, blodwen_main, _} =
        Enum.find(entrypoints, &(elem(&1, 0) == erl_module))

      compile_blodwen(dest, erl_module, blodwen_root_dir, blodwen_main)

      :code.purge(erl_module)
      :code.delete(erl_module)
    end)

    {:ok, []}
  end

  defp compile_blodwen(dest, erl_module, blodwen_root_dir, blodwen_main) do
    # TODO: Improve command
    dest_beam = path_to_beam(dest, erl_module)
    compile_cmd = ~s(echo -n ':c "#{dest_beam}" main' | blodwen --cg erlang #{blodwen_main})

    System.cmd("bash", ["-c", compile_cmd], cd: blodwen_root_dir)
  end

  defp calc_diff(previous, current) do
    previous_set = MapSet.new(previous)
    current_set = MapSet.new(current)

    %{
      added: MapSet.difference(current_set, previous_set),
      existing: MapSet.intersection(previous_set, current_set),
      removed: MapSet.difference(previous_set, current_set)
    }
  end

  defp do_clean(manifest_file, dest) do
    manifest = read_manifest(manifest_file)

    manifest_erl_modules = Enum.map(manifest, &elem(&1, 0))

    Enum.each(manifest_erl_modules, fn erl_module ->
      delete_erl_module(dest, erl_module)
    end)

    File.rm(manifest_file)

    :ok
  end

  defp erl_module_changed?(manifest_entries, entrypoints, erl_module) do
    manifest_entry = Enum.find(manifest_entries, &(elem(&1, 0) == erl_module))

    entrypoint = Enum.find(entrypoints, &(elem(&1, 0) == erl_module))

    if manifest_entry && entrypoint do
      {_, manifest_files} = manifest_entry
      {_, _, _, entrypoint_files} = entrypoint

      manifest_files != entrypoint_files
    else
      true
    end
  end

  defp path_to_beam(dest, erl_module) do
    Path.join(dest, "#{erl_module}.beam")
  end

  defp delete_erl_module(dest, erl_module) do
    File.rm(path_to_beam(dest, erl_module))
  end

  defp annotate_entrypoint({erl_module, blodwen_root_dir, blodwen_main}, exts) do
    files = Mix.Utils.extract_files([blodwen_root_dir], exts)
    files_with_mtime = source_files_with_mtime(files)

    {erl_module, blodwen_root_dir, blodwen_main, files_with_mtime}
  end

  defp source_files_with_mtime(files) do
    Enum.map(files, fn file ->
      {file, Mix.Utils.last_modified(file)}
    end)
  end

  defp annotated_entrypoint_to_manifest_entry({erl_module, _, _, files_with_mtime}) do
    {erl_module, files_with_mtime}
  end

  defp read_manifest(file) do
    try do
      file
      |> File.read!()
      |> :erlang.binary_to_term()
    rescue
      _ -> []
    else
      {@manifest_vsn, data} when is_list(data) -> data
      _ -> []
    end
  end

  defp write_manifest(file, entries, timestamp) do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, :erlang.term_to_binary({@manifest_vsn, entries}))
    File.touch!(file, timestamp)
  end
end
