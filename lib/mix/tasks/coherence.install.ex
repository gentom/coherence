defmodule Mix.Tasks.Coherence.Install do
  use Mix.Task

  import Macro, only: [camelize: 1, underscore: 1]
  import Mix.Generator
  import Mix.Ecto
  import Coherence.Mix.Utils

  @shortdoc "Configure the Coherence Package"

  @moduledoc """
  Configure the Coherence User Model for your Phoenix application. Coherence
  is composed of a number of modules that can be enabled with this installer.

  This installer will normally do the following unless given an option not to do so:

  * Append the :coherence configuration to your `config/config.exs` file.
  * Generate appropriate migration files.
  * Generate appropriate view files.
  * Generate appropriate template files.
  * Generate a `web/coherence_web.ex` file.
  * Generate a `web/models/user.ex` file if one does not already exist.

  ## Examples

      # Install with only the `authenticatable` option
      mix coherence.install

      # Install all the options except `confirmable` and `invitable`
      mix coherence.install --full

      # Install all the options except `invitable`
      mix coherence.install --full-confirmable

      # Install all the options except `confirmable`
      mix coherence.install --full-invitable

      # Install the `full` options except `lockable` and `trackable`
      mix coherence.install --full --no-lockable --no-trackable

  ## Option list

  A Coherence configuration will be appended to your `config/config.exs` file unless
  the `--no-config` option is given.

  A `--model="SomeModule tablename"` option can be given to override the default User module.

  A `--repo=CustomRepo` option can be given to override the default Repo module

  A `--default` option will include only `authenticatable`

  A `--full` option will include options `authenticatable`, `recoverable`, `lockable`, `trackable`, `unlockable_with_token`, `registerable`

  A `--full-confirmable` option will include the `--full` options in addition to the `--confirmable` option

  A `--full-invitable` option will include the `--full` options in addition to the `--invitable` option

  An `--authenticatable` option provides authentication support to your User model.

  A `--recoverable` option provides the ability to request a password reset email.

  A `--lockable` option provides login locking after too many failed login attempts.

  An `--unlockable-with-token` option provides the ability to request an unlock email.

  A `--trackable` option provides login count, current login timestamp, current login ip, last login timestamp, last login ip in your User model.

  A `--confirmable` option provides support for confirmation email before the account can be logged in.

  An `--invitable` option provides support for invitation emails, allowing the new user to create their account including password creation.

  A `--registerable` option provide support for new users to register for an account`

  A `--rememberable` option provide a remember me? check box for persistent logins`

  A `--migration-path` option to set the migration path

  A `--controllers` option to generate controllers boilerplate (not default)

  A `--module` option to override the module

  ## Disable Options

  * `--no-config` -- Don't append to your `config/config.exs` file.
  * `--no-web` -- Don't create the `coherence_web.ex` file.
  * `--no-views` -- Don't create the `web/views/coherence/` files.
  * `--no-migrations` -- Don't create the migration files.
  * `--no-templates` -- Don't create the `web/templates/coherence` files.
  * `--no-boilerplate` -- Don't create any of the boilerplate files.
  * `--no-models` -- Don't generate the model file.

  """

  # :rememberable not supported yet
  @all_options       ~w(authenticatable recoverable lockable trackable rememberable) ++
                       ~w(unlockable_with_token confirmable invitable registerable)
  @all_options_atoms Enum.map(@all_options, &(String.to_atom(&1)))

  @default_options   ~w(authenticatable)
  @full_options      @all_options -- ~w(confirmable invitable rememberable)
  @full_confirmable  @all_options -- ~w(invitable rememberable)
  @full_invitable    @all_options -- ~w(confirmable rememberable)

  # the options that default to true, and can be disabled with --no-option
  @default_booleans  ~w(config web views migrations templates models emails boilerplate)

  # all boolean_options
  @boolean_options   @default_booleans ++ ~w(default full full_confirmable full_invitable) ++ @all_options

  # options that will set use_email? to true
  @email_options     Enum.map(~w(recoverable unlockable_with_token confirmable invitable), &(String.to_atom(&1)))

  @config_file "config/config.exs"

  @config_marker_start "%% Coherence Configuration %%"
  @config_marker_end   "%% End Coherence Configuration %%"


  @switches [user: :string, repo: :string, migration_path: :string, model: :string, log_only: :boolean,
     controllers: :boolean, module: :string] ++ Enum.map(@boolean_options, &({String.to_atom(&1), :boolean}))

  @switch_names Enum.map(@switches, &(elem(&1, 0)))

  @new_user_migration_fields ["add :name, :string", "add :email, :string"]
  @new_user_constraints      ["create unique_index(:users, [:email])"]

  def run(args) do
    {opts, parsed, unknown} = OptionParser.parse(args, switches: @switches)

    verify_args!(parsed, unknown)

    {bin_opts, opts} = parse_options(opts)

    do_config(opts, bin_opts)
    |> do_run
  end

  defp do_run(config) do
    config
    |> check_for_model
    |> gen_coherence_config
    |> gen_migration
    |> gen_model
    |> gen_invitable_migration
    |> gen_rememberable_migration
    |> gen_coherence_web
    |> gen_coherence_views
    |> gen_coherence_templates
    |> gen_coherence_mailer
    |> gen_coherence_controllers
    |> touch_config                # work around for config file not getting recompiled
    |> print_instructions
  end

  defp gen_coherence_config(config) do
    from_email = if config[:use_email?] do
      ~s|  email_from: {"Your Name", "yourname@example.com"},\n|
    else
      ""
    end

    """
# #{@config_marker_start}   Don't remove this line
config :coherence,
  user_schema: #{config[:user_schema]},
  repo: #{config[:repo]},
  module: #{config[:base]},
  logged_out_url: "/",
""" <> from_email <>
    "  opts: #{inspect config[:opts]}\n"
    |> swoosh_config(config)
    |> add_end_marker
    |> write_config(config)
    |> log_config
  end

  defp swoosh_config(string, %{base: base, use_email?: true}) do
    string <> "\n" <> """
config :coherence, #{base}.Coherence.Mailer,
  adapter: Swoosh.Adapters.Sendgrid,
  api_key: "your api key here"
"""
  end
  defp swoosh_config(string, _), do: string

  defp add_end_marker(string) do
    string <> "# #{@config_marker_end}\n"
  end

  defp write_config(string, %{config: true} = config) do
    log_config? = if File.exists? @config_file do
      source = File.read!(@config_file)
      log_config? = if String.contains? source, @config_marker_start do
        Mix.shell.yes? "Your config file already contains Coherence configuration. Are you sure you add another?"
      else
        true
      end
      |> if do
        File.write!(@config_file, source <> "\n" <> string)
        Mix.shell.info "Your config/config.exs file was updated."
        false
      else
        Mix.shell.info "Configuration was not added!"
        true
      end
    else
      Mix.shell.error "Could not find #{@config_file}. Configuration was not added!"
      true
    end
    Enum.into [config_string: string, log_config?: log_config?], config
  end
  defp write_config(string, config), do: Enum.into([log_config?: true, config_string: string], config)

  defp log_config(%{log_config?: false} = config) do
    save_instructions config, ""
  end
  defp log_config(%{config_string: string} = config) do
    verb = if config[:log_config] == :appended, do: "has been", else: "should be"
    instructions = """

    The following #{verb} added to your #{@config_file} file.

    """ <> string

    save_instructions config, instructions
  end

  defp touch_config(config) do
    File.touch @config_file
    config
  end

  defp module_to_string(module) when is_atom(module) do
    Module.split(module)
    |> Enum.reverse
    |> hd
    |> to_string
  end
  defp module_to_string(module) when is_binary(module) do
    String.split(module, ".")
    |> Enum.reverse
    |> hd
  end

  ################
  # Models

  defp check_for_model(%{user_schema: user_schema} = config) do
    user_schema = Module.concat user_schema, nil
    Map.put(config, :model_found?, Code.ensure_compiled?(user_schema) or model_exists?(user_schema, "web/models"))
  end
  defp check_for_model(config), do: config

  defp gen_model(%{user_schema: user_schema, boilerplate: true, models: true, model_found?: false} = config) do
    name = module_to_string(user_schema)
    |> String.downcase
    binding = binding ++ [base: config[:base], user_table_name: config[:user_table_name]]
    Mix.Phoenix.copy_from paths(),
      "priv/templates/coherence.install/models/coherence", "", binding, [
        {:eex, "user.ex", "web/models/coherence/#{name}.ex"}
      ]
    config
  end
  defp gen_model(config), do: config

  ################
  # Migrations

  defp create_or_alter_model(config, name) do
    table_name = config[:user_table_name]
    # user_schema = Module.concat user_schema, nil
    if  config[:model_found?] do
      {:alter, "add_coherence_to_#{name}", [], []}
    else
      fields = Enum.map @new_user_migration_fields, &(String.replace(&1, ":users", ":#{table_name}"))
      constraints = Enum.map @new_user_constraints, &(String.replace(&1, ":users", ":#{table_name}"))
      {:create, "create_coherence_#{name}", fields, constraints}
    end
  end

  defp model_exists?(model, path) when is_binary(model) do
    model_exists? Module.concat(model, nil), path
  end
  defp model_exists?(model, path) do
    case File.ls path do
      {:ok, files} ->
        Enum.any? files, fn fname ->
          case File.read Path.join(path, fname) do
            {:ok, contents} ->
              contents =~ ~r/defmodule\s*#{inspect model}/
            {:error, _} -> false
          end
        end
      {:error, _} -> false
    end
  end

  defp add_timestamp(acc, %{model_found?: false}), do: acc ++ ["", "timestamps()"]
  defp add_timestamp(acc, _), do: acc

  defp gen_migration(%{migrations: true, boilerplate: true} = config) do
    table_name = config[:user_table_name]
    name = config[:user_schema]
    |> module_to_string
    |> String.downcase
    {verb, migration_name, initial_fields, constraints} = create_or_alter_model(config, name)
    do_gen_migration config, migration_name, fn repo, _path, file, name ->
      adds =
        Enum.reduce(config[:opts], initial_fields, fn opt, acc ->
          case Coherence.Schema.schema_fields[opt] do
            nil -> acc
            list -> acc ++ list
          end
        end)
        |> add_timestamp(config)
        |> Enum.map(&("      " <> &1))
        |> Enum.join("\n")

      constraints =
        constraints
        |> Enum.map(&("    " <> &1))
        |> Enum.join("\n")

      change = """
          #{verb} table(:#{table_name}) do
      #{adds}
          end
      #{constraints}
      """
      assigns = [mod: Module.concat([repo, Migrations, camelize(name)]),
                       change: change]
      create_file file, migration_template(assigns)
    end
  end
  defp gen_migration(config), do: config

  defp gen_invitable_migration(%{invitable: true, migrations: true, boilerplate: true} = config) do
    do_gen_migration config, "create_coherence_invitable", fn repo, _path, file, name ->
      change = """
          create table(:invitations) do
            add :name, :string
            add :email, :string
            add :token, :string
            timestamps
          end
          create unique_index(:invitations, [:email])
          create index(:invitations, [:token])
      """
      assigns = [mod: Module.concat([repo, Migrations, camelize(name)]),
                       change: change]
      create_file file, migration_template(assigns)
    end
  end
  defp gen_invitable_migration(config), do: config

  defp gen_rememberable_migration(%{rememberable: true, migrations: true, boilerplate: true} = config) do
    table_name = config[:user_table_name]
    do_gen_migration config, "create_coherence_rememberable", fn repo, _path, file, name ->
      change = """
          create table(:rememberables) do
            add :series_hash, :string
            add :token_hash, :string
            add :token_created_at, :datetime
            add :user_id, references(:#{table_name}, on_delete: :delete_all)

            timestamps
          end
          create index(:rememberables, [:user_id])
          create index(:rememberables, [:series_hash])
          create index(:rememberables, [:token_hash])
          create unique_index(:rememberables, [:user_id, :series_hash, :token_hash])
      """
      assigns = [mod: Module.concat([repo, Migrations, camelize(name)]),
                       change: change]
      create_file file, migration_template(assigns)
    end
  end
  defp gen_rememberable_migration(config), do: config


  defp do_gen_migration(%{timestamp: timestamp} = config, name, fun) do
    repo = config[:repo]
    |> String.split(".")
    |> Module.concat
    ensure_repo(repo, [])
    path = case config[:migration_path] do
      path when is_binary(path) -> path
      _ ->
        Path.relative_to(migrations_path(repo), Mix.Project.app_path)
    end
    file = Path.join(path, "#{timestamp}_#{underscore(name)}.exs")
    fun.(repo, path, file, name)
    Map.put(config, :timestamp, timestamp + 1)
  end

  ################
  # Web

  defp gen_coherence_web(%{web: true, boilerplate: true, binding: binding} = config) do
    Mix.Phoenix.copy_from paths(),
      "priv/templates/coherence.install", "", binding, [
        {:eex, "coherence_web.ex", "web/coherence_web.ex"},
      ]
    config
  end
  defp gen_coherence_web(config), do: config

  ################
  # Views

  @view_files [
    all: "coherence_view.ex",
    confirmable: "confirmation_view.ex",
    use_email?: "email_view.ex",
    invitable: "invitation_view.ex",
    all: "layout_view.ex",
    all: "coherence_view_helpers.ex",
    recoverable: "password_view.ex",
    registerable: "registration_view.ex",
    authenticatable: "session_view.ex",
    unlockable_with_token: "unlock_view.ex"
  ]

  def gen_coherence_views(%{views: true, boilerplate: true, binding: binding} = config) do
    files = Enum.filter_map(@view_files, &(validate_option(config, elem(&1,0))), &(elem(&1, 1)))
    |> Enum.map(&({:eex, &1, "web/views/coherence/#{&1}"}))

    Mix.Phoenix.copy_from paths(), "priv/templates/coherence.install/views/coherence", "", binding, files
    config
  end
  def gen_coherence_views(config), do: config

  @template_files [
    email: {:use_email?, ~w(confirmation invitation password unlock)},
    invitation: {:invitable, ~w(edit new)},
    layout: {:all, ~w(app email)},
    password: {:recoverable, ~w(edit new)},
    registration: {:registerable, ~w(new)},
    session: {:authenticatable, ~w(new)},
    unlock: {:unlockable_with_token, ~w(new)}
  ]

  defp validate_option(_, :all), do: true
  defp validate_option(%{use_email?: true}, :use_email?), do: true
  defp validate_option(%{opts: opts}, opt) do
    if opt in opts, do: true, else: false
  end

  ################
  # Templates

  def gen_coherence_templates(%{templates: true, boilerplate: true, binding: binding} = config) do
    for {name, {opt, files}} <- @template_files do
      if validate_option(config, opt), do: copy_templates(binding, name, files)
    end
    config
  end
  def gen_coherence_templates(config), do: config

  defp copy_templates(binding, name, file_list) do
    files = for fname <- file_list do
      fname = "#{fname}.html.eex"
      {:eex, fname, "web/templates/coherence/#{name}/#{fname}"}
    end

    Mix.Phoenix.copy_from paths(),
      "priv/templates/coherence.install/templates/coherence/#{name}", "", binding, files
  end

  ################
  # Mailer

  defp gen_coherence_mailer(%{binding: binding, use_email?: true, boilerplate: true} = config) do
    Mix.Phoenix.copy_from paths(),
      "priv/templates/coherence.install/emails/coherence", "", binding, [
        {:eex, "coherence_mailer.ex", "web/emails/coherence/coherence_mailer.ex"},
        {:eex, "user_email.ex", "web/emails/coherence/user_email.ex"},
      ]
    config
  end
  defp gen_coherence_mailer(config), do: config

  ################
  # Controllers

  @controller_files [
    confirmable: "confirmation_controller.ex",
    invitable: "invitation_controller.ex",
    recoverable: "password_controller.ex",
    registerable: "registration_controller.ex",
    authenticatable: "session_controller.ex",
    unlockable_with_token: "unlock_controller.ex"
  ]

  defp gen_coherence_controllers(%{controllers: true, boilerplate: true, binding: binding} = config) do
    files = Enum.filter_map(@controller_files, &(validate_option(config, elem(&1,0))), &(elem(&1, 1)))
    |> Enum.map(&({:eex, &1, "web/controllers/coherence/#{&1}"}))

    Mix.Phoenix.copy_from paths(), "priv/templates/coherence.install/controllers/coherence", "", binding, files
    config
  end
  defp gen_coherence_controllers(config), do: config

  ################
  # Instructions

  defp seeds_instructions(%{repo: repo, user_schema: user_schema, authenticatable: true}) do
    user_schema = to_string user_schema
    repo = to_string repo
    """
    You might want to add the following to your priv/repo/seeds.exs file.

    #{repo}.delete_all #{user_schema}

    #{user_schema}.changeset(%#{user_schema}{}, %{name: "Test User", email: "testuser@example.com", password: "secret", password_confirmation: "secret"})
    |> #{repo}.insert!
    """
  end
  defp seeds_instructions(_config), do: ""

  defp schema_instructions(%{base: base, found_model?: false}), do: """
    Add the following items to your User model (Phoenix v1.2).

    defmodule #{base}.User do
      use #{base}.Web, :model
      use Coherence.Schema     # Add this

      schema "users" do
        field :name, :string
        field :email, :string
        coherence_schema       # Add this

        timestamps
      end

      def changeset(model, params \\ %{}) do
        model
        |> cast(params, [:name, :email] ++ coherence_fields)
        |> validate_required([:name, :email])
        |> unique_constraint(:email)
        |> validate_coherence(params)             # Add this
      end
    end
    """
  defp schema_instructions(_), do: ""

  defp router_instructions(%{base: base, controllers: controllers}) do
    namespace = if controllers, do: ", #{base}", else: ""
    """
    Add the following to your router.ex file.

    defmodule #{base}.Router do
      use #{base}.Web, :router
      use Coherence.Router         # Add this

      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
        plug :fetch_flash
        plug :protect_from_forgery
        plug :put_secure_browser_headers
        plug Coherence.Authentication.Session, login: true  # Add this
      end

      pipeline :public do
        plug :accepts, ["html"]
        plug :fetch_session
        plug :fetch_flash
        plug :protect_from_forgery
        plug :put_secure_browser_headers
        plug Coherence.Authentication.Session               # Add this
      end

      # Add this block
      scope "/"#{namespace} do
        pipe_through :public
        coherence_routes :public
      end

      # Add this block
      scope "/"#{namespace} do
        pipe_through :browser
        coherence_routes :private
      end

      scope "/", #{base} do
        pipe_through :public
        get "/", PageController, :index
      end

      scope "/", #{base} do
        pipe_through :browser
        # Add your protected routes here
      end
    end
    """
  end

  defp migrate_instructions(%{migrations: true, boilerplate: true}) do
    """
    Don't forget to run the new migrations and seeds with:
        $ mix ecto.setup
    """
  end
  defp migrate_instructions(_), do: ""

  defp print_instructions(%{instructions: instructions} = config) do
    Mix.shell.info instructions
    Mix.shell.info router_instructions(config)
    Mix.shell.info schema_instructions(config)
    Mix.shell.info seeds_instructions(config)
    Mix.shell.info migrate_instructions(config)

    config
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  embed_template :migration, """
  defmodule <%= inspect @mod %> do
    use Ecto.Migration
    def change do
  <%= @change %>
    end
  end
  """

  ################
  # Utilities

  defp pad(i) when i < 10, do: << ?0, ?0 + i >>
  defp pad(i), do: to_string(i)

  defp do_default_config(config, opts) do
    list_to_atoms(@default_booleans)
    |> Enum.reduce( config, fn opt, acc ->
      Map.put acc, opt, Keyword.get(opts, opt, true)
    end)
  end

  defp list_to_atoms(list), do: Enum.map(list, &(String.to_atom(&1)))

  defp paths do
    [".", :coherence]
  end

  defp save_instructions(config, instructions) do
    update_in config, [:instructions], &(&1 <> instructions)
  end

  ################
  # Installer Configuration

  defp do_config(opts, []) do
    do_config(opts, list_to_atoms(@default_options))
  end
  defp do_config(opts, bin_opts) do
    binding = Mix.Project.config
    |> Keyword.fetch!(:app)
    |> Atom.to_string
    |> Mix.Phoenix.inflect

    # IO.puts "binding: #{inspect binding}"

    base = opts[:module] || binding[:base]
    opts = Keyword.put(opts, :base, base)
    repo = (opts[:repo] || "#{base}.Repo")

    binding = Keyword.put binding ,:base, base

    {user_schema, user_table_name} = parse_model(opts[:model], base, opts)

    bin_opts
    |> Enum.map(&({&1, true}))
    |> Enum.into(%{})
    |> Map.put(:instructions, "")
    |> Map.put(:base, base)
    |> Map.put(:use_email?, Enum.any?(bin_opts, &(&1 in @email_options)))
    |> Map.put(:user_schema, user_schema)
    |> Map.put(:user_table_name, user_table_name)
    |> Map.put(:repo, repo)
    |> Map.put(:opts, bin_opts)
    |> Map.put(:binding, binding)
    |> Map.put(:log_only, opts[:log_only])
    |> Map.put(:controllers, opts[:controllers])
    |> Map.put(:migration_path, opts[:migration_path])
    |> Map.put(:module, opts[:module])
    |> Map.put(:timestamp, timestamp() |> String.to_integer)
    |> do_default_config(opts)
  end

  defp parse_model(model, _base, opts) when is_binary(model) do
    case String.split(model, " ", trim: true) do
      [model, table] ->
        {prefix_model(model, opts), String.to_atom(table)}
      [_] ->
        Mix.raise """
        The mix coherence.install --model option expects both singular and plural names. For example:

            mix coherence.install --model="Account accounts"
        """
    end
  end
  defp parse_model(_, base, _) do
    {"#{base}.User", :users}
  end

  defp prefix_model(model, opts) do
    module = opts[:module] || opts[:base]
    if String.starts_with? model, module do
      model
    else
      module <> "." <>  model
    end
  end

  defp parse_options(opts) do
    {opts_bin, opts} = Enum.reduce opts, {[], []}, fn
      {:default, true}, {acc_bin, acc} ->
        {list_to_atoms(@default_options) ++ acc_bin, acc}
      {:full, true}, {acc_bin, acc} ->
        {list_to_atoms(@full_options) ++ acc_bin, acc}
      {:full_confirmable, true}, {acc_bin, acc} ->
        {list_to_atoms(@full_confirmable) ++ acc_bin, acc}
      {:full_invitable, true}, {acc_bin, acc} ->
        {list_to_atoms(@full_invitable) ++ acc_bin, acc}
      {name, true}, {acc_bin, acc} when name in @all_options_atoms ->
        {[name | acc_bin], acc}
      {name, false}, {acc_bin, acc} when name in @all_options_atoms ->
        {acc_bin -- [name], acc}
      opt, {acc_bin, acc} ->
        {acc_bin, [opt | acc]}
    end
    opts_bin = Enum.uniq(opts_bin)
    opts_names = Enum.map opts, &(elem(&1, 0))
    with  [] <- Enum.filter(opts_bin, &(not &1 in @switch_names)),
          [] <- Enum.filter(opts_names, &(not &1 in @switch_names)) do
            {opts_bin, opts}
    else
      list -> raise_option_errors(list)
    end
  end

  # TODO: Remove this later if we never use it
  #
  # defp prompt_yes(default, yes_prompt, prompt) do
  #   unless Mix.shell.yes? yes_prompt do
  #     Mix.shell.prompt prompt
  #   else
  #     default
  #   end
  # end
  # defp schema_exists?(module) do
  #   :erlang.function_exported(module, :__schema__, 1)
  # end

end
