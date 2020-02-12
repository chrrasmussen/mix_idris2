defmodule Mix.Tasks.Compile.Idris do
  use Mix.Task.Compiler

  @recursive true
  @manifest "compile.idris"
  @manifest_vsn 1

  @switches [
    force: :boolean,
    debug: :boolean,
    all_warnings: :boolean
  ]

  defmodule Manifest do
    defstruct idris_modules: %{},
              compiled_erl_modules: %{}
  end

  defmodule AnnotatedEntrypoint do
    @enforce_keys [
      :idris_root_dir,
      :idris_main_file,
      :files_with_mtime
    ]
    defstruct [
      :idris_root_dir,
      :idris_main_file,
      :files_with_mtime
    ]
  end

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    project = Mix.Project.config()

    entrypoint = project[:idris_entrypoint]

    unless entrypoint_valid?(entrypoint) do
      Mix.raise(
        ":idris_entrypoint should be a tuple with values {idris_root_dir, idris_main_file}, got: #{
          inspect(entrypoint)
        }"
      )
    end

    annotated_entrypoint = annotate_entrypoint(entrypoint, [:idr])

    idris_tmp_dir = Mix.Project.app_path() |> Path.join("idris")
    ebin_dir = Mix.Project.compile_path()

    manifest = read_manifest(manifest_file())

    # Force recompile if any config files has been updated since last compile
    configs = [Mix.Project.config_mtime()]
    force = opts[:force] || Mix.Utils.stale?(configs, [manifest_file()])

    app_name = project[:app] || ""
    opts = Keyword.merge(project[:idris_options] || [], opts)

    result =
      do_run(app_name, manifest, annotated_entrypoint, idris_tmp_dir, ebin_dir, force, opts)

    case result do
      {:ok, compiled_erl_modules} ->
        # Update manifest
        timestamp = System.os_time(:second)

        new_manifest = %Manifest{
          idris_modules: annotated_entrypoint.files_with_mtime,
          compiled_erl_modules: compiled_erl_modules
        }

        write_manifest(manifest_file(), new_manifest, timestamp)
    end

    {:ok, []}
  end

  @impl true
  def manifests, do: [manifest_file()]

  defp manifest_file, do: Path.join(Mix.Project.manifest_path(), @manifest)

  @impl true
  def clean() do
    ebin_dir = Mix.Project.compile_path()
    do_clean(manifest_file(), ebin_dir)
  end

  # Helper functions

  defp do_run(app_name, manifest, entrypoint, idris_tmp_dir, ebin_dir, force, opts) do
    has_idris_modules_changed = manifest.idris_modules != entrypoint.files_with_mtime

    if has_idris_modules_changed || force do
      IO.puts("==> #{app_name}")

      if force do
        idris_modules_count = map_size(entrypoint.files_with_mtime)
        IO.puts("Force recompile of all Idris modules (#{idris_modules_count})")
      else
        changed_files_count =
          MapSet.difference(
            MapSet.new(entrypoint.files_with_mtime),
            MapSet.new(manifest.idris_modules)
          )
          |> MapSet.size()

        IO.puts(
          "Detected changes in #{changed_files_count} file#{plural_s(changed_files_count)} (.idr)"
        )
      end

      # Re-create output folder on every build
      # Makes it easier to track newly generated files
      File.rm_rf!(idris_tmp_dir)
      File.mkdir_p!(idris_tmp_dir)

      newly_compiled_erl_modules =
        compile_idris(
          idris_tmp_dir,
          ebin_dir,
          manifest.compiled_erl_modules,
          entrypoint.idris_root_dir,
          entrypoint.idris_main_file,
          opts
        )

      Enum.each(newly_compiled_erl_modules, fn {erl_module, _} ->
        :code.purge(erl_module)
        :code.delete(erl_module)
      end)

      {:ok, Map.merge(manifest.compiled_erl_modules, newly_compiled_erl_modules)}
    else
      {:ok, manifest.compiled_erl_modules}
    end
  end

  defp compile_idris(
         idris_tmp_dir,
         ebin_dir,
         already_compiled_erl_modules,
         idris_root_dir,
         idris_main_file,
         opts
       ) do
    idris2_args = [
      "--cg",
      "erlang",
      "--cg-opt",
      "--library --format erlang",
      "-o",
      idris_tmp_dir,
      idris_main_file
    ]

    debug_log("Running cmd: idris2 " <> show_args(idris2_args), opts[:debug])

    {idris2_output, _idris2_exit_status} =
      System.cmd(
        "idris2",
        idris2_args,
        cd: idris_root_dir
      )

    idris2_trimmed_output = String.trim(idris2_output)

    if idris2_trimmed_output != "" do
      IO.puts(idris2_trimmed_output)
    end

    all_generated_erl_modules =
      File.ls!(idris_tmp_dir)
      |> Enum.filter(fn filename -> Path.extname(filename) == ".erl" end)
      |> Enum.map(fn filename -> Path.basename(filename, ".erl") |> String.to_atom() end)

    generated_erl_modules_hashes =
      generated_erl_modules_with_hash(idris_tmp_dir, all_generated_erl_modules)
      |> Enum.filter(fn {erl_module, new_hash} ->
        case Map.fetch(already_compiled_erl_modules, erl_module) do
          {:ok, old_hash} -> old_hash != new_hash
          :error -> true
        end
      end)
      |> Enum.into(%{})

    erl_file_paths =
      generated_erl_modules_hashes
      |> Enum.map(fn {filename, _} -> path_to_generated_erl_module(idris_tmp_dir, filename) end)

    generated_files_count = length(all_generated_erl_modules)
    IO.puts("Generated #{generated_files_count} file#{plural_s(generated_files_count)} (.erl)")

    changed_files_count = length(erl_file_paths)
    IO.puts("Compiling #{changed_files_count} file#{plural_s(changed_files_count)} (.erl)")

    erlc_args = ["-W0", "-o", ebin_dir] ++ erl_file_paths
    debug_log("Running cmd: erlc " <> show_args(erlc_args), opts[:debug])

    {erlc_output, _erlc_exit_status} = System.cmd("erlc", erlc_args)

    erlc_trimmed_output = String.trim(erlc_output)

    if erlc_trimmed_output != "" do
      IO.puts(erlc_trimmed_output)
    end

    generated_erl_modules_hashes
  end

  defp plural_s(count) do
    if count != 1, do: "s", else: ""
  end

  defp do_clean(manifest_file, ebin_dir) do
    manifest = read_manifest(manifest_file)

    manifest_erl_modules = Enum.map(manifest.compiled_erl_modules, &elem(&1, 0))

    Enum.each(manifest_erl_modules, fn erl_module ->
      delete_erl_module(ebin_dir, erl_module)
    end)

    File.rm(manifest_file)

    :ok
  end

  def entrypoint_valid?({idris_root_dir, idris_main_file}) do
    String.valid?(idris_root_dir) && String.valid?(idris_main_file)
  end

  def entrypoint_valid?(_), do: false

  defp delete_erl_module(ebin_dir, erl_module) do
    beam_path = Path.join(ebin_dir, "#{erl_module}.beam")
    File.rm!(beam_path)
  end

  defp annotate_entrypoint(
         {idris_root_dir, idris_main_file},
         exts
       ) do
    files = Mix.Utils.extract_files([idris_root_dir], exts)
    files_with_mtime = source_files_with_mtime(files)

    %AnnotatedEntrypoint{
      idris_root_dir: idris_root_dir,
      idris_main_file: idris_main_file,
      files_with_mtime: files_with_mtime
    }
  end

  defp source_files_with_mtime(files) do
    files
    |> Enum.map(fn file -> {file, Mix.Utils.last_modified(file)} end)
    |> Enum.into(%{})
  end

  defp generated_erl_modules_with_hash(idris_tmp_dir, erl_modules) do
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

  defp show_args(args) do
    args
    |> Enum.map(&"\"#{&1}\"")
    |> Enum.join(" ")
  end

  defp debug_log(msg, debug) do
    if debug do
      IO.puts("[debug] #{msg}")
    end
  end
end
