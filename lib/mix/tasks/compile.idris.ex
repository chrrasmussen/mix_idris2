defmodule Mix.Tasks.Compile.Idris do
  use Mix.Task.Compiler

  @recursive true
  @manifest "compile.idris"
  @manifest_vsn 1

  @switches [
    force: :boolean,
    all_warnings: :boolean
  ]

  defmodule AnnotatedEntrypoint do
    @enforce_keys [
      :erl_module,
      :idris_root_dir,
      :idris_main_file,
      :idris_entrypoint,
      :files_with_mtime
    ]
    defstruct [
      :erl_module,
      :idris_root_dir,
      :idris_main_file,
      :idris_entrypoint,
      :files_with_mtime
    ]
  end

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    project = Mix.Project.config()
    entrypoints = project[:idris_entrypoints] || []

    ebin_dir = Mix.Project.compile_path(project)

    unless is_list(entrypoints) && Enum.all?(entrypoints, &entrypoint_valid?/1) do
      Mix.raise(
        ":idris_entrypoints should be a list of entrypoints {:module_name, root_dir, main_path, idris_entrypoint}, got: #{
          inspect(entrypoints)
        }"
      )
    end

    manifest = read_manifest(manifest_file())

    # Force recompile if any config files has been updated since last compile
    configs = [Mix.Project.config_mtime()]
    force = opts[:force] || Mix.Utils.stale?(configs, [manifest_file()])

    annotated_entrypoints = Enum.map(entrypoints, &annotate_entrypoint(&1, [:idr]))

    opts = Keyword.merge(project[:idris_options] || [], opts)
    result = do_run(manifest, annotated_entrypoints, ebin_dir, force, opts)

    case result do
      {:ok, _} ->
        # Update manifest
        timestamp = System.os_time(:second)
        new_manifest = Enum.map(annotated_entrypoints, &annotated_entrypoint_to_manifest_entry/1)
        write_manifest(manifest_file(), new_manifest, timestamp)
    end

    result
  end

  def entrypoint_valid?({module_name, root_dir, main_path, idris_entrypoint}) do
    is_atom(module_name) && String.valid?(root_dir) && String.valid?(main_path) &&
      String.valid?(idris_entrypoint)
  end

  def entrypoint_valid?(_), do: false

  @impl true
  def manifests, do: [manifest_file()]

  defp manifest_file, do: Path.join(Mix.Project.manifest_path(), @manifest)

  @impl true
  def clean() do
    ebin_dir = Mix.Project.compile_path()
    do_clean(manifest_file(), ebin_dir)
  end

  # Helper functions

  defp do_run(manifest, entrypoints, ebin_dir, force, _opts) do
    # Calculate added/changed/removed modules

    manifest_erl_modules = Enum.map(manifest, &elem(&1, 0))
    entrypoints_erl_modules = Enum.map(entrypoints, & &1.erl_module)

    %{added: added, existing: existing, removed: removed} =
      calc_diff(manifest_erl_modules, entrypoints_erl_modules)

    changed =
      existing
      |> Enum.filter(&erl_module_changed?(manifest, entrypoints, &1))
      |> MapSet.new()

    # Clean up removed modules

    Enum.each(removed, fn erl_module ->
      delete_erl_module(ebin_dir, erl_module)
    end)

    # Recompile changed modules

    to_be_compiled =
      if force,
        do: entrypoints_erl_modules,
        else: MapSet.union(added, changed)

    Enum.each(to_be_compiled, fn erl_module ->
      entrypoint = Enum.find(entrypoints, &(&1.erl_module == erl_module))

      compile_idris(
        ebin_dir,
        erl_module,
        entrypoint.idris_root_dir,
        entrypoint.idris_main_file,
        entrypoint.idris_entrypoint
      )

      :code.purge(erl_module)
      :code.delete(erl_module)
    end)

    {:ok, []}
  end

  defp compile_idris(ebin_dir, erl_module, idris_root_dir, idris_main_file, idris_entrypoint) do
    beam_file = path_to_beam(ebin_dir, erl_module)

    System.cmd(
      "idris2",
      ["--cg", "erlang", "--library", beam_file, idris_entrypoint, idris_main_file],
      cd: idris_root_dir
    )
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

  defp do_clean(manifest_file, ebin_dir) do
    manifest = read_manifest(manifest_file)

    manifest_erl_modules = Enum.map(manifest, &elem(&1, 0))

    Enum.each(manifest_erl_modules, fn erl_module ->
      delete_erl_module(ebin_dir, erl_module)
    end)

    File.rm(manifest_file)

    :ok
  end

  defp erl_module_changed?(manifest_entries, entrypoints, erl_module) do
    manifest_entry = Enum.find(manifest_entries, &(elem(&1, 0) == erl_module))

    entrypoint = Enum.find(entrypoints, &(&1.erl_module == erl_module))

    if manifest_entry && entrypoint do
      {_, manifest_files} = manifest_entry

      manifest_files != entrypoint.files_with_mtime
    else
      true
    end
  end

  defp path_to_beam(ebin_dir, erl_module) do
    Path.join(ebin_dir, "#{erl_module}.beam")
  end

  defp delete_erl_module(ebin_dir, erl_module) do
    File.rm(path_to_beam(ebin_dir, erl_module))
  end

  defp annotate_entrypoint(
         {erl_module, idris_root_dir, idris_main_file, idris_entrypoint},
         exts
       ) do
    files = Mix.Utils.extract_files([idris_root_dir], exts)
    files_with_mtime = source_files_with_mtime(files)

    %AnnotatedEntrypoint{
      erl_module: erl_module,
      idris_root_dir: idris_root_dir,
      idris_main_file: idris_main_file,
      idris_entrypoint: idris_entrypoint,
      files_with_mtime: files_with_mtime
    }
  end

  defp source_files_with_mtime(files) do
    Enum.map(files, fn file ->
      {file, Mix.Utils.last_modified(file)}
    end)
  end

  defp annotated_entrypoint_to_manifest_entry(%AnnotatedEntrypoint{
         erl_module: erl_module,
         files_with_mtime: files_with_mtime
       }) do
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
