# mix_idris2

`mix_idris2` adds the ability to compile [Idris 2](https://github.com/idris-lang/Idris2) code in a Mix project. The Idris 2 code is compiled to `.beam` files using the [Erlang code generator for Idris 2](https://github.com/chrrasmussen/Idris2-Erlang).

The Erlang code generator for Idris 2 include functions and types to allow interoperability between Idris 2 and Erlang/Elixir. Learn more from its [documentation](https://github.com/chrrasmussen/Idris2-Erlang#documentation).


## Installation

Steps:
1. Add Idris package file
2. Add Idris module
3. Add `mix_idris2` as a dependency
4. Update project configuration


### 1. Add Idris package file

Create a file named `hello.ipkg` in the same directory as your `mix.exs` file.

Example package description:

```idris
package hello

modules =
  Main

sourcedir = "lib/idris"
builddir = "_build/idris"

library = hello
```

The `modules` field should list all Idris modules that are not imported by any other Idris modules. Let's call these for root modules. Root modules commonly include code to export Erlang functions (See example in next section). All Idris modules that are (transitively) imported by a root module will be compiled/generated.

- [Documentation about package descriptions](https://idris2.readthedocs.io/en/latest/reference/packages.html)


### 2. Add Idris module

Create a file named `Main.idr` in the directory `lib/idris` (same as `sourcedir` in `hello.ipkg`).

Example Idris module:

```idris
module Main

import Erlang

%cg erlang export exports


hello : String
hello = "Hello from Idris"

exports : ErlExport
exports = Fun "hello" (MkFun0 hello)
```

This will export the function `hello/0` in a module named `Elixir.Idris.Main`. Note that `mix_idris2` will prefix the Idris module names with `Elixir.Idris.`, making them easier to access from Elixir.


### 3. Add `mix_idris2` as a dependency

In your `mix.exs`, add `:mix_idris2` to your list of dependencies:

```elixir
def deps do
  [
    {:mix_idris2, "~> 0.1.0"}
  ]
end
```


### 4. Update project configuration

In your `mix.exs`, add the keys `:idris_ipkg` and `:compilers` to your `:project` definition.

`:idris_options` is a keyword list containing the options described in the [`mix_idris2` options](#mix_idris2-options) section. The key `:idris_options` is optional.

Example configuration:

```elixir
def project do
  [
    idris_ipkg: "hello.ipkg",
    idris_options: [],
    compilers: [:idris] ++ Mix.compilers()
  ]
end
```

If you are including `mix_idris2` in a Phoenix project, the list of compilers should be something like: `[:idris, :phoenix, :gettext] ++ Mix.compilers()`


## Usage

After completing the installation steps, you should be able to call `Idris.Main.hello()` from an Elixir module. The function call should return the binary: `"Hello from Idris"`

Learn how to interoperate with Erlang/Elixir from Idris code in the [documentation for the Erlang code generator](https://github.com/chrrasmussen/Idris2-Erlang#documentation).


## `mix_idris2` options

The key `:idris_options` in the `:project` definition supports the following options:


| Option             | Default       | Description                                                                                                                                   |
| ------------------ | ------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `:executable_path` | `"idris2erl"` | The path to the `idris2` executable.                                                                                                          |
| `:incremental`     | `false`       | Enable to only generate code for changed Idris modules. See also: [Incremental code generation gotchas](#incremental-code-generation-gotchas) |
| `:debug`           | `false`       | Enable to output additional information in the output.                                                                                        |

Example configuration:

```elixir
def project do
  [
    idris_ipkg: "hello.ipkg",
    idris_options: [executable_path: "idris2erl", incremental: true, debug: true],
    compilers: [:idris] ++ Mix.compilers()
  ]
end
```


### Incremental code generation gotchas

If you want to use the incremental code generation option, you should be aware that `mix_idris2` does not currently generate code for all Idris modules that belong to the Idris packages (`prelude`, `base`, `erlang` etc.), only the Idris modules that are referenced in your source code. This means that if you import an Idris module from `base` that you did not previously reference, the newly imported Idris module will not be generated.

As a workaround you can always run `mix compile --force` to recompile all the referenced Idris modules.

I want to remove this limitation in the future.


## License

`mix_idris2` is released under the [3-clause BSD license](idris2/LICENSE).
