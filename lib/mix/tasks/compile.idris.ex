defmodule Mix.Tasks.Compile.Idris do
  use Mix.Task.Compiler

  @recursive true
  @manifest "compile.idris"
  @manifest_vsn 1

  @switches [
    force: :boolean,
    all_warnings: :boolean
  ]

  defmodule Manifest do
    defstruct entrypoints: [],
              generated_erl_modules: %{}
  end

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

    idris_tmp_dir = Mix.Project.app_path(project) |> Path.join("idris")
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
    result = do_run(manifest, annotated_entrypoints, idris_tmp_dir, ebin_dir, force, opts)

    case result do
      {:ok, generated_erl_modules} ->
        # Update manifest
        timestamp = System.os_time(:second)

        new_manifest = %Manifest{
          entrypoints: Enum.map(annotated_entrypoints, &annotated_entrypoint_to_manifest_entry/1),
          generated_erl_modules: generated_erl_modules
        }

        write_manifest(manifest_file(), new_manifest, timestamp)
    end

    {:ok, []}
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

  defp do_run(manifest, entrypoints, idris_tmp_dir, ebin_dir, force, _opts) do
    # Calculate added/changed/removed modules

    manifest_erl_modules = Enum.map(manifest.entrypoints, &elem(&1, 0))
    entrypoints_erl_modules = Enum.map(entrypoints, & &1.erl_module)

    %{added: added, existing: existing, removed: removed} =
      calc_diff(manifest_erl_modules, entrypoints_erl_modules)

    changed =
      existing
      |> Enum.filter(&erl_module_changed?(manifest.entrypoints, entrypoints, &1))
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

    generated_erl_modules =
      Enum.reduce(to_be_compiled, manifest.generated_erl_modules, fn erl_module,
                                                                     already_compiled_erl_modules ->
        entrypoint = Enum.find(entrypoints, &(&1.erl_module == erl_module))

        compiled_erl_modules =
          compile_idris(
            idris_tmp_dir,
            ebin_dir,
            already_compiled_erl_modules,
            erl_module,
            entrypoint.idris_root_dir,
            entrypoint.idris_main_file,
            entrypoint.idris_entrypoint
          )

        Enum.each(compiled_erl_modules, fn {compiled_erl_module, _} ->
          :code.purge(compiled_erl_module)
          :code.delete(compiled_erl_module)
        end)

        compiled_erl_modules
        |> Enum.into(already_compiled_erl_modules)
      end)

    {:ok, generated_erl_modules}
  end

  defp compile_idris(
         idris_tmp_dir,
         ebin_dir,
         already_compiled_erl_modules,
         erl_module,
         idris_root_dir,
         idris_main_file,
         idris_entrypoint
       ) do
    File.mkdir_p!(idris_tmp_dir)

    System.cmd(
      "idris2",
      [
        "--cg",
        "erlang",
        "--cg-opt",
        "--library --format erlang",
        "-o",
        idris_tmp_dir,
        idris_main_file
      ],
      cd: idris_root_dir
    )

    all_generated_erl_modules =
      File.ls!(idris_tmp_dir)
      |> Enum.filter(fn filename -> Path.extname(filename) == ".erl" end)
      |> Enum.map(fn filename -> Path.basename(filename, ".erl") |> String.to_atom() end)

    erl_modules_hashes =
      generated_files_with_hash(idris_tmp_dir, all_generated_erl_modules)
      |> Enum.filter(fn {erl_module, new_hash} ->
        case Map.fetch(already_compiled_erl_modules, erl_module) do
          {:ok, old_hash} -> old_hash != new_hash
          :error -> true
        end
      end)

    erl_file_paths =
      erl_modules_hashes
      |> Enum.map(fn {filename, _} -> path_to_generated_erl_module(idris_tmp_dir, filename) end)

    System.cmd("erlc", ["-W0", "-o", ebin_dir] ++ erl_file_paths)

    erl_modules_hashes
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

  defp delete_erl_module(ebin_dir, erl_module) do
    # File.rm(path_to_beam(ebin_dir, erl_module)) -- TODO: Uncomment
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

  defp generated_files_with_hash(idris_tmp_dir, erl_modules) do
    erl_modules
    |> Enum.map(fn erl_module ->
      path = path_to_generated_erl_module(idris_tmp_dir, erl_module)
      {erl_module, hash_file(path)}
    end)
    |> Enum.into(%{})
  end

  defp path_to_generated_erl_module(idris_tmp_dir, erl_module) do
    Path.join(idris_tmp_dir, "#{erl_module}.erl")
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
      _ -> %Manifest{}
    else
      {@manifest_vsn, data} -> data
      _ -> %Manifest{}
    end
  end

  defp write_manifest(file, manifest, timestamp) do
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, :erlang.term_to_binary({@manifest_vsn, manifest}))
    File.touch!(file, timestamp)
  end

  defp hash_file(path, algorithm \\ :sha256) do
    path
    |> File.stream!([], 16_384)
    |> Enum.reduce(:crypto.hash_init(algorithm), fn chunk, digest ->
      :crypto.hash_update(digest, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16()
  end
end
