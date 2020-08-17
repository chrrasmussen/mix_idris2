defmodule Mix.Tasks.Compile.Idris do
  use Mix.Task.Compiler

  @recursive true
  @manifest "compile.idris"
  @manifest_vsn 1

  @switches [
    executable_path: :string,
    incremental: :boolean,
    debug: :boolean,
    force: :boolean
  ]

  @idris_extensions ["idr", "lidr"]
  @erlang_source_extension "erl"

  @ipkg_sourcedir_field ~r/^\s*sourcedir\s*=\s*"(.+)"\s*$/m

  defmodule Manifest do
    defstruct idris_modules: %{},
              compiled_erl_modules: %{}
  end

  defmodule AnnotatedEntrypoint do
    @enforce_keys [
      :idris_ipkg_file,
      :idris_source_dir,
      :files_with_mtime
    ]
    defstruct [
      :idris_ipkg_file,
      :idris_source_dir,
      :files_with_mtime
    ]
  end

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    project = Mix.Project.config()

    idris_ipkg_file = project[:idris_ipkg]

    unless entrypoint_valid?(idris_ipkg_file) do
      Mix.raise(
        ":idris_ipkg should point to an Idris package file (.ipkg), got: #{
          inspect(idris_ipkg_file)
        }"
      )
    end

    idris_source_dir = get_ipkg_source_dir(idris_ipkg_file)

    annotated_entrypoint =
      annotate_entrypoint(idris_ipkg_file, idris_source_dir, @idris_extensions)

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

        {:ok, []}

      :error ->
        {:error, []}
    end
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
    changed_idris_modules =
      MapSet.difference(
        MapSet.new(entrypoint.files_with_mtime),
        MapSet.new(manifest.idris_modules)
      )
      |> Enum.into(%{})

    changed_idris_modules_count = map_size(changed_idris_modules)

    if changed_idris_modules_count > 0 || force do
      IO.puts("==> #{app_name}")

      if force do
        idris_modules_count = map_size(entrypoint.files_with_mtime)
        IO.puts("Force recompile of all Idris modules (#{idris_modules_count})")
      else
        IO.puts(
          "Detected changes in #{changed_idris_modules_count} file#{
            plural_s(changed_idris_modules_count)
          } (.idr)"
        )
      end

      # Re-create output folder on every build
      # Makes it easier to track newly generated files
      File.rm_rf!(idris_tmp_dir)
      File.mkdir_p!(idris_tmp_dir)

      compile_result =
        compile_idris(
          changed_idris_modules,
          manifest.compiled_erl_modules,
          idris_tmp_dir,
          ebin_dir,
          entrypoint.idris_ipkg_file,
          entrypoint.idris_source_dir,
          force,
          opts
        )

      case compile_result do
        {:ok, newly_compiled_erl_modules} ->
          Enum.each(newly_compiled_erl_modules, fn {erl_module, _} ->
            :code.purge(erl_module)
            :code.delete(erl_module)
          end)

          {:ok, Map.merge(manifest.compiled_erl_modules, newly_compiled_erl_modules)}

        :error ->
          :error
      end
    else
      {:ok, manifest.compiled_erl_modules}
    end
  end

  defp compile_idris(
         changed_idris_modules,
         already_compiled_erl_modules,
         idris_tmp_dir,
         ebin_dir,
         idris_ipkg_file,
         idris_source_dir,
         force,
         opts
       ) do
    with :ok <-
           generate_idris_modules(
             changed_idris_modules,
             idris_tmp_dir,
             idris_ipkg_file,
             idris_source_dir,
             force,
             opts
           ),
         {:ok, generated_erl_modules_hashes} <-
           compile_erl_modules(already_compiled_erl_modules, idris_tmp_dir, ebin_dir, opts) do
      {:ok, generated_erl_modules_hashes}
    else
      _ ->
        :error
    end
  end

  defp generate_idris_modules(
         changed_idris_modules,
         idris_tmp_dir,
         idris_ipkg_file,
         idris_source_dir,
         force,
         opts
       ) do
    # If the `:incremental` option is enabled and the `force` flag is not set, only
    # generate modules that have changed.
    # Note that the `force` flag is set on initial compilation: Generate all modules.
    only_changed_namespaces_arg =
      if opts[:incremental] && not force do
        source_abs_dir = Path.expand(Path.join(idris_root_dir(idris_ipkg_file), idris_source_dir))

        namespaces =
          changed_idris_modules
          |> Enum.map(fn {path, _} ->
            path
            |> Path.expand()
            |> Path.relative_to(source_abs_dir)
            |> Path.rootname()
            |> String.replace("/", ".")
          end)
          |> Enum.join(",")

        ["--changed-namespaces", "#{namespaces}"]
      else
        []
      end

    all_directives = ["format erl", "prefix Elixir.Idris"]

    directive_args =
      all_directives
      |> Enum.flat_map(fn directive -> ["--directive", directive] end)

    idris2_executable = opts[:executable_path] || "idris2"

    idris2_args =
      [
        "--cg",
        "erlang",
        "--output-dir",
        idris_tmp_dir,
        "--build",
        idris_ipkg_file
      ] ++ directive_args ++ only_changed_namespaces_arg

    debug_log("Running cmd: #{idris2_executable} #{show_args(idris2_args)}", opts[:debug])

    {idris2_output, idris2_exit_status} =
      debug_measure(
        fn ->
          System.cmd(
            idris2_executable,
            idris2_args,
            cd: idris_root_dir(idris_ipkg_file)
          )
        end,
        "idris2 cmd",
        opts[:debug]
      )

    idris2_trimmed_output = String.trim(idris2_output)

    if idris2_trimmed_output != "" do
      IO.puts(idris2_trimmed_output)
    end

    if idris2_exit_status == 0 do
      :ok
    else
      :error
    end
  end

  defp compile_erl_modules(
         already_compiled_erl_modules,
         idris_tmp_dir,
         ebin_dir,
         opts
       ) do
    all_generated_erl_modules =
      File.ls!(idris_tmp_dir)
      |> Enum.filter(fn filename -> Path.extname(filename) == ".#{@erlang_source_extension}" end)
      |> Enum.map(fn filename ->
        Path.basename(filename, ".#{@erlang_source_extension}") |> String.to_atom()
      end)

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

    IO.puts(
      "Generated #{generated_files_count} file#{plural_s(generated_files_count)} (.#{
        @erlang_source_extension
      })"
    )

    changed_files_count = length(erl_file_paths)

    IO.puts(
      "Compiling #{changed_files_count} file#{plural_s(changed_files_count)} (.#{
        @erlang_source_extension
      })"
    )

    debug_log("Compiling files: #{inspect(erl_file_paths)}", opts[:debug])

    # TODO: Improve error handling
    debug_measure(
      fn ->
        erl_file_paths
        |> Enum.map(&erl_to_beam(&1, ebin_dir))
      end,
      ":compile.noenv_file/2",
      opts[:debug]
    )

    {:ok, generated_erl_modules_hashes}
  end

  defp erl_to_beam(erl_file_path, output_dir) do
    {:ok, _module_name} =
      :compile.noenv_file(:erlang.binary_to_list(erl_file_path), [
        {:outdir, :erlang.binary_to_list(output_dir)}
      ])
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

  def entrypoint_valid?(idris_ipkg_file) do
    String.ends_with?(idris_ipkg_file, ".ipkg")
  end

  defp delete_erl_module(ebin_dir, erl_module) do
    beam_path = Path.join(ebin_dir, "#{erl_module}.beam")
    File.rm!(beam_path)
  end

  defp annotate_entrypoint(
         idris_ipkg_file,
         idris_source_dir,
         exts
       ) do
    files =
      Mix.Utils.extract_files(
        [Path.join(idris_root_dir(idris_ipkg_file), idris_source_dir)],
        exts
      )

    files_with_mtime = source_files_with_mtime(files)

    %AnnotatedEntrypoint{
      idris_ipkg_file: idris_ipkg_file,
      idris_source_dir: idris_source_dir,
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
    Path.join(idris_tmp_dir, "#{erl_module}.#{@erlang_source_extension}")
  end

  defp idris_root_dir(idris_ipkg_file) do
    Path.dirname(idris_ipkg_file)
  end

  defp get_ipkg_source_dir(idris_ipkg_file) do
    File.read!(idris_ipkg_file)
    |> parse_ipkg_source_dir()
  end

  defp parse_ipkg_source_dir(contents) do
    # If sourcedir is not found, default to current directory
    if matched = Regex.run(@ipkg_sourcedir_field, contents) do
      Enum.at(matched, 1)
    else
      "."
    end
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

  defp debug_measure(action, msg, debug) do
    if debug do
      {time, value} = :timer.tc(action)
      formatted_time = :io_lib.format('~.3f', [time / 1_000_000])
      IO.puts("[timing] #{msg}: #{formatted_time}s")
      value
    else
      action.()
    end
  end
end
