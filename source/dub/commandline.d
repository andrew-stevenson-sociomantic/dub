/**
	Defines the behavior of the DUB command line client.

	Copyright: © 2012-2013 Matthias Dondorff, Copyright © 2012-2016 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Matthias Dondorff, Sönke Ludwig
*/
module dub.commandline;

import dub.compilers.compiler;
import dub.dependency;
import dub.dub;
import dub.generators.generator;
import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.data.json;
import dub.internal.vibecompat.inet.url;
import dub.package_;
import dub.packagemanager;
import dub.packagesuppliers;
import dub.project;
import dub.internal.utils : getDUBVersion, getClosestMatch, getTempFile;

import std.algorithm;
import std.array;
import std.conv;
import std.encoding;
import std.exception;
import std.file;
import std.getopt;
import std.process;
import std.stdio;
import std.string;
import std.typecons : Tuple, tuple;
import std.variant;
import std.path: setExtension;

/** Retrieves a list of all available commands.

	Commands are grouped by category.
*/
CommandGroup[] getCommands()
{
	return [
		CommandGroup("Package creation",
			new InitCommand
		),
		CommandGroup("Build, test and run",
			new RunCommand,
			new BuildCommand,
			new TestCommand,
			new GenerateCommand,
			new DescribeCommand,
			new CleanCommand,
			new DustmiteCommand
		),
		CommandGroup("Package management",
			new FetchCommand,
			new InstallCommand,
			new AddCommand,
			new RemoveCommand,
			new UninstallCommand,
			new UpgradeCommand,
			new AddPathCommand,
			new RemovePathCommand,
			new AddLocalCommand,
			new RemoveLocalCommand,
			new ListCommand,
			new SearchCommand,
			new AddOverrideCommand,
			new RemoveOverrideCommand,
			new ListOverridesCommand,
			new CleanCachesCommand,
			new ConvertCommand,
		)
	];
}


/** Processes the given command line and executes the appropriate actions.

	Params:
		args = This command line argument array as received in `main`. The first
			entry is considered to be the name of the binary invoked.

	Returns:
		Returns the exit code that is supposed to be returned to the system.
*/
int runDubCommandLine(string[] args)
{
	logDiagnostic("DUB version %s", getDUBVersion());

	version(Windows){
		// rdmd uses $TEMP to compute a temporary path. since cygwin substitutes backslashes
		// with slashes, this causes OPTLINK to fail (it thinks path segments are options)
		// we substitute the other way around here to fix this.
		environment["TEMP"] = environment["TEMP"].replace("/", "\\");
	}

	// special stdin syntax
	if (args.length >= 2 && args[1] == "-")
	{
		auto path = getTempFile("app", ".d");
		stdin.byChunk(4096).joiner.toFile(path.toNativeString());
		args = args[0] ~ [path.toNativeString()] ~ args[2..$];
	}

	// create the list of all supported commands
	CommandGroup[] commands = getCommands();
	string[] commandNames = commands.map!(g => g.commands.map!(c => c.name).array).join.array;

	// Shebang syntax support for files without .d extension
	if (args.length >= 2 && !args[1].endsWith(".d") && !args[1].startsWith("-") && !commandNames.canFind(args[1])) {
		if (exists(args[1])) {
			auto path = getTempFile("app", ".d");
			copy(args[1], path.toNativeString());
			args[1] = path.toNativeString();
		} else if (exists(args[1].setExtension(".d"))) {
			args[1] = args[1].setExtension(".d");
		}
	}

	// special single-file package shebang syntax
	if (args.length >= 2 && args[1].endsWith(".d")) {
		args = args[0] ~ ["run", "-q", "--temp-build", "--single", args[1], "--"] ~ args[2 ..$];
	}

	// split application arguments from DUB arguments
	string[] app_args;
	auto app_args_idx = args.countUntil("--");
	if (app_args_idx >= 0) {
		app_args = args[app_args_idx+1 .. $];
		args = args[0 .. app_args_idx];
	}
	args = args[1 .. $]; // strip the application name

	// handle direct dub options
	if (args.length) switch (args[0])
	{
	case "--version":
		showVersion();
		return 0;

	default:
		break;
	}

	// parse general options
	CommonOptions options;
	LogLevel loglevel = LogLevel.info;

	auto common_args = new CommandArgs(args);
	try {
		options.prepare(common_args);

		if (options.vverbose) loglevel = LogLevel.debug_;
		else if (options.verbose) loglevel = LogLevel.diagnostic;
		else if (options.vquiet) loglevel = LogLevel.none;
		else if (options.quiet) loglevel = LogLevel.warn;
		else if (options.verror) loglevel = LogLevel.error;
		setLogLevel(loglevel);
	} catch (Throwable e) {
		logError("Error processing arguments: %s", e.msg);
		logDiagnostic("Full exception: %s", e.toString().sanitize);
		logInfo("Run 'dub help' for usage information.");
		return 1;
	}

	if (options.root_path.empty)
		options.root_path = getcwd();
	else
	{
		import std.path : absolutePath, buildNormalizedPath;

		options.root_path = options.root_path.absolutePath.buildNormalizedPath;
	}

	// extract the command
	string cmdname;
	args = common_args.extractRemainingArgs();
	if (args.length >= 1 && !args[0].startsWith("-")) {
		cmdname = args[0];
		args = args[1 .. $];
	} else {
		if (options.help) {
			showHelp(commands, common_args);
			return 0;
		}
		cmdname = "run";
	}
	auto command_args = new CommandArgs(args);

	if (cmdname == "help") {
		showHelp(commands, common_args);
		return 0;
	}

	// find the selected command
	Command cmd;
	foreach (grp; commands)
		foreach (c; grp.commands)
			if (c.name == cmdname) {
				cmd = c;
				break;
			}

	if (!cmd) {
		logError("Unknown command: %s", cmdname);
		writeln();
		showHelp(commands, common_args);
		return 1;
	}

	// process command line options for the selected command
	try {
		cmd.prepare(command_args);
		enforceUsage(cmd.acceptsAppArgs || app_args.length == 0, cmd.name ~ " doesn't accept application arguments.");
	} catch (Throwable e) {
		logError("Error processing arguments: %s", e.msg);
		logDiagnostic("Full exception: %s", e.toString().sanitize);
		logInfo("Run 'dub help' for usage information.");
		return 1;
	}

	if (options.help) {
		showCommandHelp(cmd, command_args, common_args);
		return 0;
	}

	auto remaining_args = command_args.extractRemainingArgs();
	if (remaining_args.any!(a => a.startsWith("-"))) {
		logError("Unknown command line flags: %s", remaining_args.filter!(a => a.startsWith("-")).array.join(" "));
		logError(`Type "dub %s -h" to get a list of all supported flags.`, cmdname);
		return 1;
	}

	Dub dub;

	// initialize the root package
	if (!cmd.skipDubInitialization) {
		if (options.bare) {
			dub = new Dub(NativePath(getcwd()));
			dub.rootPath = NativePath(options.root_path);
			dub.defaultPlacementLocation = options.placementLocation;
		} else {
			// initialize DUB
			auto package_suppliers = options.registry_urls
				.map!((url) {
					// Allow to specify fallback mirrors as space separated urls. Undocumented as we
					// should simply retry over all registries instead of using a special
					// FallbackPackageSupplier.
					auto urls = url.splitter(' ');
					PackageSupplier ps = getRegistryPackageSupplier(urls.front);
					urls.popFront;
					if (!urls.empty)
						ps = new FallbackPackageSupplier(ps ~ urls.map!getRegistryPackageSupplier.array);
					return ps;
				})
				.array;
			dub = new Dub(options.root_path, package_suppliers, options.skipRegistry);
			dub.dryRun = options.annotate;
			dub.defaultPlacementLocation = options.placementLocation;

			// make the CWD package available so that for example sub packages can reference their
			// parent package.
			try dub.packageManager.getOrLoadPackage(NativePath(options.root_path));
			catch (Exception e) { logDiagnostic("No valid package found in current working directory: %s", e.msg); }
		}
	}

	// execute the command
	try return cmd.execute(dub, remaining_args, app_args);
	catch (UsageException e) {
		logError("%s", e.msg);
		logDebug("Full exception: %s", e.toString().sanitize);
		logInfo(`Run "dub %s -h" for more information about the "%s" command.`, cmdname, cmdname);
		return 1;
	}
	catch (Throwable e) {
		logError("%s", e.msg);
		logDebug("Full exception: %s", e.toString().sanitize);
		return 2;
	}
}


/** Contains and parses options common to all commands.
*/
struct CommonOptions {
	bool verbose, vverbose, quiet, vquiet, verror;
	bool help, annotate, bare;
	string[] registry_urls;
	string root_path;
	SkipPackageSuppliers skipRegistry = SkipPackageSuppliers.none;
	PlacementLocation placementLocation = PlacementLocation.user;

	/// Parses all common options and stores the result in the struct instance.
	void prepare(CommandArgs args)
	{
		args.getopt("h|help", &help, ["Display general or command specific help"]);
		args.getopt("root", &root_path, ["Path to operate in instead of the current working dir"]);
		args.getopt("registry", &registry_urls, [
			"Search the given registry URL first when resolving dependencies. Can be specified multiple times. Available registry types:",
			"  DUB: URL to DUB registry (default)",
			"  Maven: URL to Maven repository + group id containing dub packages as artifacts. E.g. mvn+http://localhost:8040/maven/libs-release/dubpackages",
			]);
		args.getopt("skip-registry", &skipRegistry, [
			"Sets a mode for skipping the search on certain package registry types:",
			"  none: Search all configured or default registries (default)",
			"  standard: Don't search the main registry (e.g. "~defaultRegistryURLs[0]~")",
			"  configured: Skip all default and user configured registries",
			"  all: Only search registries specified with --registry",
			]);
		args.getopt("annotate", &annotate, ["Do not perform any action, just print what would be done"]);
		args.getopt("bare", &bare, ["Read only packages contained in the current directory"]);
		args.getopt("v|verbose", &verbose, ["Print diagnostic output"]);
		args.getopt("vverbose", &vverbose, ["Print debug output"]);
		args.getopt("q|quiet", &quiet, ["Only print warnings and errors"]);
		args.getopt("verror", &verror, ["Only print errors"]);
		args.getopt("vquiet", &vquiet, ["Print no messages"]);
		args.getopt("cache", &placementLocation, ["Puts any fetched packages in the specified location [local|system|user]."]);
	}
}

/** Encapsulates a set of application arguments.

	This class serves two purposes. The first is to provide an API for parsing
	command line arguments (`getopt`). At the same time it records all calls
	to `getopt` and provides a list of all possible options using the
	`recognizedArgs` property.
*/
class CommandArgs {
	struct Arg {
		Variant defaultValue;
		Variant value;
		string names;
		string[] helpText;
	}
	private {
		string[] m_args;
		Arg[] m_recognizedArgs;
	}

	/** Initializes the list of source arguments.

		Note that all array entries are considered application arguments (i.e.
		no application name entry is present as the first entry)
	*/
	this(string[] args)
	{
		m_args = "dummy" ~ args;
	}

	/** Returns the list of all options recognized.

		This list is created by recording all calls to `getopt`.
	*/
	@property const(Arg)[] recognizedArgs() { return m_recognizedArgs; }

	void getopt(T)(string names, T* var, string[] help_text = null)
	{
		foreach (ref arg; m_recognizedArgs)
			if (names == arg.names) {
				assert(help_text is null);
				*var = arg.value.get!T;
				return;
			}
		assert(help_text.length > 0);
		Arg arg;
		arg.defaultValue = *var;
		arg.names = names;
		arg.helpText = help_text;
		m_args.getopt(config.passThrough, names, var);
		arg.value = *var;
		m_recognizedArgs ~= arg;
	}

	/** Resets the list of available source arguments.
	*/
	void dropAllArgs()
	{
		m_args = null;
	}

	/** Returns the list of unprocessed arguments and calls `dropAllArgs`.
	*/
	string[] extractRemainingArgs()
	{
		auto ret = m_args[1 .. $];
		m_args = null;
		return ret;
	}
}


/** Base class for all commands.

	This cass contains a high-level description of the command, including brief
	and full descriptions and a human readable command line pattern. On top of
	that it defines the two main entry functions for command execution.
*/
class Command {
	string name;
	string argumentsPattern;
	string description;
	string[] helpText;
	bool acceptsAppArgs;
	bool hidden = false; // used for deprecated commands
	bool skipDubInitialization = false;

	/** Parses all known command line options without executing any actions.

		This function will be called prior to execute, or may be called as
		the only method when collecting the list of recognized command line
		options.

		Only `args.getopt` should be called within this method.
	*/
	abstract void prepare(scope CommandArgs args);

	/** Executes the actual action.

		Note that `prepare` will be called before any call to `execute`.
	*/
	abstract int execute(Dub dub, string[] free_args, string[] app_args);

	private bool loadCwdPackage(Dub dub, bool warn_missing_package)
	{
		bool found = existsFile(dub.rootPath ~ "source/app.d");
		if (!found)
			foreach (f; packageInfoFiles)
				if (existsFile(dub.rootPath ~ f.filename)) {
					found = true;
					break;
				}

		if (!found) {
			if (warn_missing_package) {
				logInfo("");
				logInfo("Neither a package description file, nor source/app.d was found in");
				logInfo(dub.rootPath.toNativeString());
				logInfo("Please run DUB from the root directory of an existing package, or run");
				logInfo("\"dub init --help\" to get information on creating a new package.");
				logInfo("");
			}
			return false;
		}

		dub.loadPackage();

		return true;
	}
}


/** Encapsulates a group of commands that fit into a common category.
*/
struct CommandGroup {
	/// Caption of the command category
	string caption;

	/// List of commands contained inthis group
	Command[] commands;

	this(string caption, Command[] commands...)
	{
		this.caption = caption;
		this.commands = commands.dup;
	}
}


/******************************************************************************/
/* INIT                                                                       */
/******************************************************************************/

class InitCommand : Command {
	private{
		string m_templateType = "minimal";
		PackageFormat m_format = PackageFormat.json;
		bool m_nonInteractive;
	}
	this()
	{
		this.name = "init";
		this.argumentsPattern = "[<directory> [<dependency>...]]";
		this.description = "Initializes an empty package skeleton";
		this.helpText = [
			"Initializes an empty package of the specified type in the given directory. By default, the current working directory is used."
		];
		this.acceptsAppArgs = true;
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("t|type", &m_templateType, [
			"Set the type of project to generate. Available types:",
			"",
			"minimal - simple \"hello world\" project (default)",
			"vibe.d  - minimal HTTP server based on vibe.d",
			"deimos  - skeleton for C header bindings",
			"custom  - custom project provided by dub package",
		]);
		args.getopt("f|format", &m_format, [
			"Sets the format to use for the package description file. Possible values:",
			"  " ~ [__traits(allMembers, PackageFormat)].map!(f => f == m_format.init.to!string ? f ~ " (default)" : f).join(", ")
		]);
		args.getopt("n|non-interactive", &m_nonInteractive, ["Don't enter interactive mode."]);
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		string dir;
		if (free_args.length)
		{
			dir = free_args[0];
			free_args = free_args[1 .. $];
		}

		static string input(string caption, string default_value)
		{
			writef("%s [%s]: ", caption, default_value);
			auto inp = readln();
			return inp.length > 1 ? inp[0 .. $-1] : default_value;
		}

		void depCallback(ref PackageRecipe p, ref PackageFormat fmt) {
			import std.datetime: Clock;

			if (m_nonInteractive) return;

			while (true) {
				string rawfmt = input("Package recipe format (sdl/json)", fmt.to!string);
				if (!rawfmt.length) break;
				try {
					fmt = rawfmt.to!PackageFormat;
					break;
				} catch (Exception) {
					logError("Invalid format, \""~rawfmt~"\", enter either \"sdl\" or \"json\".");
				}
			}
			auto author = p.authors.join(", ");
			while (true) {
				// Tries getting the name until a valid one is given.
				import std.regex;
				auto nameRegex = regex(`^[a-z0-9\-_]+$`);
				string triedName = input("Name", p.name);
				if (triedName.matchFirst(nameRegex).empty) {
					logError("Invalid name, \""~triedName~"\", names should consist only of lowercase alphanumeric characters, - and _.");
				} else {
					p.name = triedName;
					break;
				}
			}
			p.description = input("Description", p.description);
			p.authors = input("Author name", author).split(",").map!(a => a.strip).array;
			p.license = input("License", p.license);
			string copyrightString = .format("Copyright © %s, %-(%s, %)", Clock.currTime().year, p.authors);
			p.copyright = input("Copyright string", copyrightString);

			while (true) {
				auto depspec = input("Add dependency (leave empty to skip)", null);
				if (!depspec.length) break;
				addDependency(dub, p, depspec);
			}
		}

		if (!["vibe.d", "deimos", "minimal"].canFind(m_templateType))
		{
			free_args ~= m_templateType;
		}
		dub.createEmptyPackage(NativePath(dir), free_args, m_templateType, m_format, &depCallback, app_args);

		logInfo("Package successfully created in %s", dir.length ? dir : ".");
		return 0;
	}
}


/******************************************************************************/
/* GENERATE / BUILD / RUN / TEST / DESCRIBE                                   */
/******************************************************************************/

abstract class PackageBuildCommand : Command {
	protected {
		string m_buildType;
		BuildMode m_buildMode;
		string m_buildConfig;
		string m_compilerName;
		string m_arch;
		string[] m_debugVersions;
		string[] m_overrideConfigs;
		Compiler m_compiler;
		BuildPlatform m_buildPlatform;
		BuildSettings m_buildSettings;
		string m_defaultConfig;
		bool m_nodeps;
		bool m_forceRemove = false;
		bool m_single;
		bool m_filterVersions = false;
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("b|build", &m_buildType, [
			"Specifies the type of build to perform. Note that setting the DFLAGS environment variable will override the build type with custom flags.",
			"Possible names:",
			"  debug (default), plain, release, release-debug, release-nobounds, unittest, profile, profile-gc, docs, ddox, cov, unittest-cov, syntax and custom types"
		]);
		args.getopt("c|config", &m_buildConfig, [
			"Builds the specified configuration. Configurations can be defined in dub.json"
		]);
		args.getopt("override-config", &m_overrideConfigs, [
			"Uses the specified configuration for a certain dependency. Can be specified multiple times.",
			"Format: --override-config=<dependency>/<config>"
		]);
		args.getopt("compiler", &m_compilerName, [
			"Specifies the compiler binary to use (can be a path).",
			"Arbitrary pre- and suffixes to the identifiers below are recognized (e.g. ldc2 or dmd-2.063) and matched to the proper compiler type:",
			"  "~["dmd", "gdc", "ldc", "gdmd", "ldmd"].join(", ")
		]);
		args.getopt("a|arch", &m_arch, [
			"Force a different architecture (e.g. x86 or x86_64)"
		]);
		args.getopt("d|debug", &m_debugVersions, [
			"Define the specified debug version identifier when building - can be used multiple times"
		]);
		args.getopt("nodeps", &m_nodeps, [
			"Do not resolve missing dependencies before building"
		]);
		args.getopt("build-mode", &m_buildMode, [
			"Specifies the way the compiler and linker are invoked. Valid values:",
			"  separate (default), allAtOnce, singleFile"
		]);
		args.getopt("single", &m_single, [
			"Treats the package name as a filename. The file must contain a package recipe comment."
		]);
		args.getopt("force-remove", &m_forceRemove, [
			"Deprecated option that does nothing."
		]);
		args.getopt("filter-versions", &m_filterVersions, [
			"[Experimental] Filter version identifiers and debug version identifiers to improve build cache efficiency."
		]);
	}

	protected void setupPackage(Dub dub, string package_name, string default_build_type = "debug")
	{
		if (!m_compilerName.length) m_compilerName = dub.defaultCompiler;
		if (!m_arch.length) m_arch = dub.defaultArchitecture;
		m_compiler = getCompiler(m_compilerName);
		m_buildPlatform = m_compiler.determinePlatform(m_buildSettings, m_compilerName, m_arch);
		m_buildSettings.addDebugVersions(m_debugVersions);

		m_defaultConfig = null;
		enforce (loadSpecificPackage(dub, package_name), "Failed to load package.");

		if (m_buildConfig.length != 0 && !dub.configurations.canFind(m_buildConfig))
		{
			string msg = "Unknown build configuration: "~m_buildConfig;
			enum distance = 3;
			auto match = dub.configurations.getClosestMatch(m_buildConfig, distance);
			if (match !is null) msg ~= ". Did you mean '" ~ match ~ "'?";
			enforce(0, msg);
		}

		if (m_buildType.length == 0) {
			if (environment.get("DFLAGS") !is null) m_buildType = "$DFLAGS";
			else m_buildType = default_build_type;
		}

		if (!m_nodeps) {
			// retrieve missing packages
			dub.project.reinit();
			if (!dub.project.hasAllDependencies) {
				logDiagnostic("Checking for missing dependencies.");
				if (m_single) dub.upgrade(UpgradeOptions.select | UpgradeOptions.noSaveSelections);
				else dub.upgrade(UpgradeOptions.select);
			}
		}

		dub.project.validate();

		foreach (sc; m_overrideConfigs) {
			auto idx = sc.indexOf('/');
			enforceUsage(idx >= 0, "Expected \"<package>/<configuration>\" as argument to --override-config.");
			dub.project.overrideConfiguration(sc[0 .. idx], sc[idx+1 .. $]);
		}
	}

	private bool loadSpecificPackage(Dub dub, string package_name)
	{
		if (m_single) {
			enforce(package_name.length, "Missing file name of single-file package.");
			dub.loadSingleFilePackage(package_name);
			return true;
		}

		bool from_cwd = package_name.length == 0 || package_name.startsWith(":");
		// load package in root_path to enable searching for sub packages
		if (loadCwdPackage(dub, from_cwd)) {
			if (package_name.startsWith(":"))
			{
				auto pack = dub.packageManager.getSubPackage(dub.project.rootPackage, package_name[1 .. $], false);
				dub.loadPackage(pack);
				return true;
			}
			if (from_cwd) return true;
		}

		enforce(package_name.length, "No valid root package found - aborting.");

		auto pack = dub.packageManager.getFirstPackage(package_name);
		enforce(pack, "Failed to find a package named '"~package_name~"' locally.");
		logInfo("Building package %s in %s", pack.name, pack.path.toNativeString());
		dub.rootPath = pack.path;
		dub.loadPackage(pack);
		return true;
	}
}

class GenerateCommand : PackageBuildCommand {
	protected {
		string m_generator;
		bool m_rdmd = false;
		bool m_tempBuild = false;
		bool m_run = false;
		bool m_force = false;
		bool m_combined = false;
		bool m_parallel = false;
		bool m_printPlatform, m_printBuilds, m_printConfigs;
	}

	this()
	{
		this.name = "generate";
		this.argumentsPattern = "<generator> [<package>]";
		this.description = "Generates project files using the specified generator";
		this.helpText = [
			"Generates project files using one of the supported generators:",
			"",
			"visuald - VisualD project files",
			"sublimetext - SublimeText project file",
			"cmake - CMake build scripts",
			"build - Builds the package directly",
			"",
			"An optional package name can be given to generate a different package than the root/CWD package."
		];
	}

	override void prepare(scope CommandArgs args)
	{
		super.prepare(args);

		args.getopt("combined", &m_combined, [
			"Tries to build the whole project in a single compiler run."
		]);

		args.getopt("print-builds", &m_printBuilds, [
			"Prints the list of available build types"
		]);
		args.getopt("print-configs", &m_printConfigs, [
			"Prints the list of available configurations"
		]);
		args.getopt("print-platform", &m_printPlatform, [
			"Prints the identifiers for the current build platform as used for the build fields in dub.json"
		]);
		args.getopt("parallel", &m_parallel, [
			"Runs multiple compiler instances in parallel, if possible."
		]);
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		string package_name;
		if (!m_generator.length) {
			enforceUsage(free_args.length >= 1 && free_args.length <= 2, "Expected one or two arguments.");
			m_generator = free_args[0];
			if (free_args.length >= 2) package_name = free_args[1];
		} else {
			enforceUsage(free_args.length <= 1, "Expected one or zero arguments.");
			if (free_args.length >= 1) package_name = free_args[0];
		}

		setupPackage(dub, package_name);

		if (m_printBuilds) { // FIXME: use actual package data
			logInfo("Available build types:");
			foreach (tp; ["debug", "release", "unittest", "profile"])
				logInfo("  %s", tp);
			logInfo("");
		}

		m_defaultConfig = dub.project.getDefaultConfiguration(m_buildPlatform);
		if (m_printConfigs) {
			logInfo("Available configurations:");
			foreach (tp; dub.configurations)
				logInfo("  %s%s", tp, tp == m_defaultConfig ? " [default]" : null);
			logInfo("");
		}

		GeneratorSettings gensettings;
		gensettings.platform = m_buildPlatform;
		gensettings.config = m_buildConfig.length ? m_buildConfig : m_defaultConfig;
		gensettings.buildType = m_buildType;
		gensettings.buildMode = m_buildMode;
		gensettings.compiler = m_compiler;
		gensettings.buildSettings = m_buildSettings;
		gensettings.combined = m_combined;
		gensettings.filterVersions = m_filterVersions;
		gensettings.run = m_run;
		gensettings.runArgs = app_args;
		gensettings.force = m_force;
		gensettings.rdmd = m_rdmd;
		gensettings.tempBuild = m_tempBuild;
		gensettings.parallelBuild = m_parallel;

		logDiagnostic("Generating using %s", m_generator);
		dub.generateProject(m_generator, gensettings);
		if (m_buildType == "ddox") dub.runDdox(gensettings.run, app_args);
		return 0;
	}
}

class BuildCommand : GenerateCommand {
	protected {
		bool m_yes; // automatic yes to prompts;
		bool m_nonInteractive;
	}
	this()
	{
		this.name = "build";
		this.argumentsPattern = "[<package>]";
		this.description = "Builds a package (uses the main package in the current working directory by default)";
		this.helpText = [
			"Builds a package (uses the main package in the current working directory by default)"
		];
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("rdmd", &m_rdmd, [
			"Use rdmd instead of directly invoking the compiler"
		]);

		args.getopt("f|force", &m_force, [
			"Forces a recompilation even if the target is up to date"
		]);
		args.getopt("y|yes", &m_yes, [
			`Automatic yes to prompts. Assume "yes" as answer to all interactive prompts.`
		]);
		args.getopt("n|non-interactive", &m_nonInteractive, [
			"Don't enter interactive mode."
		]);
		super.prepare(args);
		m_generator = "build";
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		// single package files don't need to be downloaded, they are on the disk.
		if (free_args.length < 1 || m_single)
			return super.execute(dub, free_args, app_args);

		if (!m_nonInteractive)
		{
			const packageParts = splitPackageName(free_args[0]);
			if (auto rc = fetchMissingPackages(dub, packageParts))
				return rc;
			free_args[0] = packageParts.name;
		}
		return super.execute(dub, free_args, app_args);
	}

	private int fetchMissingPackages(Dub dub, in PackageAndVersion packageParts)
	{

		static bool input(string caption, bool default_value = true) {
			writef("%s [%s]: ", caption, default_value ? "Y/n" : "y/N");
			auto inp = readln();
			string userInput = "y";
			if (inp.length > 1)
				userInput = inp[0 .. $ - 1].toLower;

			switch (userInput) {
				case "no", "n", "0":
					return false;
				case "yes", "y", "1":
				default:
					return true;
			}
		}

		Dependency dep;

		if (packageParts.version_.length > 0) {
			// the user provided a version manually
			dep = Dependency(packageParts.version_);
		} else {
			if (packageParts.name.startsWith(":") ||
				dub.packageManager.getFirstPackage(packageParts.name))
				// found locally
				return 0;

			// search for the package and filter versions for exact matches
			auto basePackageName = getBasePackageName(packageParts.name);
			auto search = dub.searchPackages(basePackageName)
				.map!(tup => tup[1].find!(p => p.name == basePackageName))
				.filter!(ps => !ps.empty);
			if (search.empty) {
				logWarn("Package '%s' was neither found locally nor online.", packageParts.name);
				return 2;
			}

			const p = search.front.front;
			logInfo("Package '%s' was not found locally but is available online:", packageParts.name);
			logInfo("---");
			logInfo("Description: %s", p.description);
			logInfo("Version: %s", p.version_);
			logInfo("---");

			const answer = m_yes ? true : input("Do you want to fetch '%s' now?".format(packageParts.name));
			if (!answer)
				return 0;
			dep = Dependency(p.version_);
		}

		dub.fetch(packageParts.name, dep, dub.defaultPlacementLocation, FetchOptions.none);
		return 0;
	}
}

class RunCommand : BuildCommand {
	this()
	{
		this.name = "run";
		this.argumentsPattern = "[<package>]";
		this.description = "Builds and runs a package (default command)";
		this.helpText = [
			"Builds and runs a package (uses the main package in the current working directory by default)"
		];
		this.acceptsAppArgs = true;
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("temp-build", &m_tempBuild, [
			"Builds the project in the temp folder if possible."
		]);

		super.prepare(args);
		m_run = true;
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		return super.execute(dub, free_args, app_args);
	}
}

class TestCommand : PackageBuildCommand {
	private {
		string m_mainFile;
		bool m_combined = false;
		bool m_parallel = false;
		bool m_force = false;
	}

	this()
	{
		this.name = "test";
		this.argumentsPattern = "[<package>]";
		this.description = "Executes the tests of the selected package";
		this.helpText = [
			`Builds the package and executes all contained unit tests.`,
			``,
			`If no explicit configuration is given, an existing "unittest" ` ~
			`configuration will be preferred for testing. If none exists, the ` ~
			`first library type configuration will be used, and if that doesn't ` ~
			`exist either, the first executable configuration is chosen.`,
			``,
			`When a custom main file (--main-file) is specified, only library ` ~
			`configurations can be used. Otherwise, depending on the type of ` ~
			`the selected configuration, either an existing main file will be ` ~
			`used (and needs to be properly adjusted to just run the unit ` ~
			`tests for 'version(unittest)'), or DUB will generate one for ` ~
			`library type configurations.`,
			``,
			`Finally, if the package contains a dependency to the "tested" ` ~
			`package, the automatically generated main file will use it to ` ~
			`run the unit tests.`
		];
		this.acceptsAppArgs = true;
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("main-file", &m_mainFile, [
			"Specifies a custom file containing the main() function to use for running the tests."
		]);
		args.getopt("combined", &m_combined, [
			"Tries to build the whole project in a single compiler run."
		]);
		args.getopt("parallel", &m_parallel, [
			"Runs multiple compiler instances in parallel, if possible."
		]);
		args.getopt("f|force", &m_force, [
			"Forces a recompilation even if the target is up to date"
		]);
		bool coverage = false;
		args.getopt("coverage", &coverage, [
			"Enables code coverage statistics to be generated."
		]);
		if (coverage) m_buildType = "unittest-cov";

		super.prepare(args);
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		string package_name;
		enforceUsage(free_args.length <= 1, "Expected one or zero arguments.");
		if (free_args.length >= 1) package_name = free_args[0];

		setupPackage(dub, package_name, "unittest");

		GeneratorSettings settings;
		settings.platform = m_buildPlatform;
		settings.compiler = getCompiler(m_buildPlatform.compilerBinary);
		settings.buildType = m_buildType;
		settings.buildMode = m_buildMode;
		settings.buildSettings = m_buildSettings;
		settings.combined = m_combined;
		settings.filterVersions = m_filterVersions;
		settings.parallelBuild = m_parallel;
		settings.force = m_force;
		settings.tempBuild = m_single;
		settings.run = true;
		settings.runArgs = app_args;

		dub.testProject(settings, m_buildConfig, NativePath(m_mainFile));
		return 0;
	}
}

class DescribeCommand : PackageBuildCommand {
	private {
		bool m_importPaths = false;
		bool m_stringImportPaths = false;
		bool m_dataList = false;
		bool m_dataNullDelim = false;
		string[] m_data;
	}

	this()
	{
		this.name = "describe";
		this.argumentsPattern = "[<package>]";
		this.description = "Prints a JSON description of the project and its dependencies";
		this.helpText = [
			"Prints a JSON build description for the root package an all of " ~
			"their dependencies in a format similar to a JSON package " ~
			"description file. This is useful mostly for IDEs.",
			"",
			"All usual options that are also used for build/run/generate apply.",
			"",
			"When --data=VALUE is supplied, specific build settings for a project " ~
			"will be printed instead (by default, formatted for the current compiler).",
			"",
			"The --data=VALUE option can be specified multiple times to retrieve " ~
			"several pieces of information at once. A comma-separated list is " ~
			"also acceptable (ex: --data=dflags,libs). The data will be output in " ~
			"the same order requested on the command line.",
			"",
			"The accepted values for --data=VALUE are:",
			"",
			"main-source-file, dflags, lflags, libs, linker-files, " ~
			"source-files, versions, debug-versions, import-paths, " ~
			"string-import-paths, import-files, options",
			"",
			"The following are also accepted by --data if --data-list is used:",
			"",
			"target-type, target-path, target-name, working-directory, " ~
			"copy-files, string-import-files, pre-generate-commands, " ~
			"post-generate-commands, pre-build-commands, post-build-commands, " ~
			"requirements",
		];
	}

	override void prepare(scope CommandArgs args)
	{
		super.prepare(args);

		args.getopt("import-paths", &m_importPaths, [
			"Shortcut for --data=import-paths --data-list"
		]);

		args.getopt("string-import-paths", &m_stringImportPaths, [
			"Shortcut for --data=string-import-paths --data-list"
		]);

		args.getopt("data", &m_data, [
			"Just list the values of a particular build setting, either for this "~
			"package alone or recursively including all dependencies. Accepts a "~
			"comma-separated list. See above for more details and accepted "~
			"possibilities for VALUE."
		]);

		args.getopt("data-list", &m_dataList, [
			"Output --data information in list format (line-by-line), instead "~
			"of formatting for a compiler command line.",
		]);

		args.getopt("data-0", &m_dataNullDelim, [
			"Output --data information using null-delimiters, rather than "~
			"spaces or newlines. Result is usable with, ex., xargs -0.",
		]);
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(
			!(m_importPaths && m_stringImportPaths),
			"--import-paths and --string-import-paths may not be used together."
		);

		enforceUsage(
			!(m_data && (m_importPaths || m_stringImportPaths)),
			"--data may not be used together with --import-paths or --string-import-paths."
		);

		// disable all log output to stdout and use "writeln" to output the JSON description
		auto ll = getLogLevel();
		setLogLevel(max(ll, LogLevel.warn));
		scope (exit) setLogLevel(ll);

		string package_name;
		enforceUsage(free_args.length <= 1, "Expected one or zero arguments.");
		if (free_args.length >= 1) package_name = free_args[0];
		setupPackage(dub, package_name);

		m_defaultConfig = dub.project.getDefaultConfiguration(m_buildPlatform);

		auto config = m_buildConfig.length ? m_buildConfig : m_defaultConfig;

		GeneratorSettings settings;
		settings.platform = m_buildPlatform;
		settings.config = config;
		settings.buildType = m_buildType;
		settings.compiler = m_compiler;
		settings.filterVersions = m_filterVersions;

		if (m_importPaths) { m_data = ["import-paths"]; m_dataList = true; }
		else if (m_stringImportPaths) { m_data = ["string-import-paths"]; m_dataList = true; }

		if (m_data.length) {
			ListBuildSettingsFormat lt;
			with (ListBuildSettingsFormat)
				lt = m_dataList ? (m_dataNullDelim ? listNul : list) : (m_dataNullDelim ? commandLineNul : commandLine);
			dub.listProjectData(settings, m_data, lt);
		} else {
			auto desc = dub.project.describe(settings);
			writeln(desc.serializeToPrettyJson());
		}

		return 0;
	}
}

class CleanCommand : Command {
	private {
		bool m_allPackages;
	}

	this()
	{
		this.name = "clean";
		this.argumentsPattern = "[<package>]";
		this.description = "Removes intermediate build files and cached build results";
		this.helpText = [
			"This command removes any cached build files of the given package(s). The final target file, as well as any copyFiles are currently not removed.",
			"Without arguments, the package in the current working directory will be cleaned."
		];
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("all-packages", &m_allPackages, [
			"Cleans up *all* known packages (dub list)"
		]);
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(free_args.length <= 1, "Expected one or zero arguments.");
		enforceUsage(app_args.length == 0, "Application arguments are not supported for the clean command.");
		enforceUsage(!m_allPackages || !free_args.length, "The --all-packages flag may not be used together with an explicit package name.");

		enforce(free_args.length == 0, "Cleaning a specific package isn't possible right now.");

		if (m_allPackages) {
			foreach (p; dub.packageManager.getPackageIterator())
				dub.cleanPackage(p.path);
		} else {
			dub.cleanPackage(dub.rootPath);
		}

		return 0;
	}
}


/******************************************************************************/
/* FETCH / ADD / REMOVE / UPGRADE                                             */
/******************************************************************************/

class AddCommand : Command {
	this()
	{
		this.name = "add";
		this.argumentsPattern = "<package>[@<version-spec>] [<packages...>]";
		this.description = "Adds dependencies to the package file.";
		this.helpText = [
			"Adds <packages> as dependencies.",
			"",
			"Running \"dub add <package>\" is the same as adding <package> to the \"dependencies\" section in dub.json/dub.sdl.",
			"If no version is specified for one of the packages, dub will query the registry for the latest version."
		];
	}

	override void prepare(scope CommandArgs args) {}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		import dub.recipe.io : readPackageRecipe, writePackageRecipe;
		import dub.internal.vibecompat.core.file : existsFile;
		enforceUsage(free_args.length != 0, "Expected one or more arguments.");
		enforceUsage(app_args.length == 0, "Unexpected application arguments.");

		if (!loadCwdPackage(dub, true)) return 1;
		auto recipe = dub.project.rootPackage.rawRecipe.clone;

		foreach (depspec; free_args) {
			if (!addDependency(dub, recipe, depspec))
				return 1;
		}
		writePackageRecipe(dub.project.rootPackage.recipePath, recipe);

		return 0;
	}
}

class UpgradeCommand : Command {
	private {
		bool m_prerelease = false;
		bool m_forceRemove = false;
		bool m_missingOnly = false;
		bool m_verify = false;
		bool m_dryRun = false;
	}

	this()
	{
		this.name = "upgrade";
		this.argumentsPattern = "[<packages...>]";
		this.description = "Forces an upgrade of the dependencies";
		this.helpText = [
			"Upgrades all dependencies of the package by querying the package registry(ies) for new versions.",
			"",
			"This will update the versions stored in the selections file ("~SelectedVersions.defaultFile~") accordingly.",
			"",
			"If one or more package names are specified, only those dependencies will be upgraded. Otherwise all direct and indirect dependencies of the root package will get upgraded."
		];
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("prerelease", &m_prerelease, [
			"Uses the latest pre-release version, even if release versions are available"
		]);
		args.getopt("verify", &m_verify, [
			"Updates the project and performs a build. If successful, rewrites the selected versions file <to be implemented>."
		]);
		args.getopt("dry-run", &m_dryRun, [
			"Only print what would be upgraded, but don't actually upgrade anything."
		]);
		args.getopt("missing-only", &m_missingOnly, [
			"Performs an upgrade only for dependencies that don't yet have a version selected. This is also done automatically before each build."
		]);
		args.getopt("force-remove", &m_forceRemove, [
			"Deprecated option that does nothing."
		]);
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(free_args.length <= 1, "Unexpected arguments.");
		enforceUsage(app_args.length == 0, "Unexpected application arguments.");
		enforceUsage(!m_verify, "--verify is not yet implemented.");
		dub.loadPackage();
		logInfo("Upgrading project in %s", dub.projectPath.toNativeString());
		auto options = UpgradeOptions.upgrade|UpgradeOptions.select;
		if (m_missingOnly) options &= ~UpgradeOptions.upgrade;
		if (m_prerelease) options |= UpgradeOptions.preRelease;
		if (m_dryRun) options |= UpgradeOptions.dryRun;
		dub.upgrade(options, free_args);
		return 0;
	}
}

class FetchRemoveCommand : Command {
	protected {
		string m_version;
		bool m_forceRemove = false;
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("version", &m_version, [
			"Use the specified version/branch instead of the latest available match",
			"The remove command also accepts \"*\" here as a wildcard to remove all versions of the package from the specified location"
		]);

		args.getopt("force-remove", &m_forceRemove, [
			"Deprecated option that does nothing"
		]);
	}

	abstract override int execute(Dub dub, string[] free_args, string[] app_args);
}

class FetchCommand : FetchRemoveCommand {
	this()
	{
		this.name = "fetch";
		this.argumentsPattern = "<name>[@<version-spec>]";
		this.description = "Manually retrieves and caches a package";
		this.helpText = [
			"Note: Use \"dub add <dependency>\" if you just want to use a certain package as a dependency, you don't have to explicitly fetch packages.",
			"",
			"Explicit retrieval/removal of packages is only needed when you want to put packages in a place where several applications can share them. If you just have a dependency to add, use the `add` command. Dub will do the rest for you.",
			"",
			"Without specified options, placement/removal will default to a user wide shared location.",
			"",
			"Complete applications can be retrieved and run easily by e.g.",
			"$ dub fetch vibelog --cache=local",
			"$ cd vibelog",
			"$ dub",
			"",
			"This will grab all needed dependencies and compile and run the application.",
			"",
			"Note: DUB does not do a system installation of packages. Packages are instead only registered within DUB's internal ecosystem. Generation of native system packages/installers may be added later as a separate feature."
		];
	}

	override void prepare(scope CommandArgs args)
	{
		super.prepare(args);
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(free_args.length == 1, "Expecting exactly one argument.");
		enforceUsage(app_args.length == 0, "Unexpected application arguments.");

		auto location = dub.defaultPlacementLocation;

		auto name = free_args[0];

		FetchOptions fetchOpts;
		fetchOpts |= FetchOptions.forceBranchUpgrade;
		if (m_version.length) dub.fetch(name, Dependency(m_version), location, fetchOpts);
		else if (name.canFind("@", "=")) {
			const parts = name.splitPackageName;
			dub.fetch(parts.name, Dependency(parts.version_), location, fetchOpts);
		} else {
			try {
				dub.fetch(name, Dependency(">=0.0.0"), location, fetchOpts);
				logInfo(
					"Please note that you need to use `dub run <pkgname>` " ~
					"or add it to dependencies of your package to actually use/run it. " ~
					"dub does not do actual installation of packages outside of its own ecosystem.");
			}
			catch(Exception e){
				logInfo("Getting a release version failed: %s", e.msg);
				logInfo("Retry with ~master...");
				dub.fetch(name, Dependency("~master"), location, fetchOpts);
			}
		}
		return 0;
	}
}

class InstallCommand : FetchCommand {
	this() { this.name = "install"; hidden = true; }
	override void prepare(scope CommandArgs args) { super.prepare(args); }
	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		warnRenamed("install", "fetch");
		return super.execute(dub, free_args, app_args);
	}
}

class RemoveCommand : FetchRemoveCommand {
	private {
		bool m_nonInteractive;
	}

	this()
	{
		this.name = "remove";
		this.argumentsPattern = "<name>";
		this.description = "Removes a cached package";
		this.helpText = [
			"Removes a package that is cached on the local system."
		];
	}

	override void prepare(scope CommandArgs args)
	{
		super.prepare(args);
		args.getopt("n|non-interactive", &m_nonInteractive, ["Don't enter interactive mode."]);
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(free_args.length == 1, "Expecting exactly one argument.");
		enforceUsage(app_args.length == 0, "Unexpected application arguments.");

		auto package_id = free_args[0];
		auto location = dub.defaultPlacementLocation;

		size_t resolveVersion(in Package[] packages) {
			// just remove only package version
			if (packages.length == 1)
				return 0;

			writeln("Select version of '", package_id, "' to remove from location '", location, "':");
			foreach (i, pack; packages)
				writefln("%s) %s", i + 1, pack.version_);
			writeln(packages.length + 1, ") ", "all versions");
			while (true) {
				writef("> ");
				auto inp = readln();
				if (!inp.length) // Ctrl+D
					return size_t.max;
				inp = inp.stripRight;
				if (!inp.length) // newline or space
					continue;
				try {
					immutable selection = inp.to!size_t - 1;
					if (selection <= packages.length)
						return selection;
				} catch (ConvException e) {
				}
				logError("Please enter a number between 1 and %s.", packages.length + 1);
			}
		}

		if (m_nonInteractive || !m_version.empty)
			dub.remove(package_id, m_version, location);
		else
			dub.remove(package_id, location, &resolveVersion);
		return 0;
	}
}

class UninstallCommand : RemoveCommand {
	this() { this.name = "uninstall"; hidden = true; }
	override void prepare(scope CommandArgs args) { super.prepare(args); }
	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		warnRenamed("uninstall", "remove");
		return super.execute(dub, free_args, app_args);
	}
}


/******************************************************************************/
/* ADD/REMOVE PATH/LOCAL                                                      */
/******************************************************************************/

abstract class RegistrationCommand : Command {
	private {
		bool m_system;
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("system", &m_system, [
			"Register system-wide instead of user-wide"
		]);
	}

	abstract override int execute(Dub dub, string[] free_args, string[] app_args);
}

class AddPathCommand : RegistrationCommand {
	this()
	{
		this.name = "add-path";
		this.argumentsPattern = "<path>";
		this.description = "Adds a default package search path";
		this.helpText = [
			"Adds a default package search path. All direct sub folders of this path will be searched for package descriptions and will be made available as packages. Using this command has the equivalent effect as calling 'dub add-local' on each of the sub folders manually.",
			"",
			"Any packages registered using add-path will be preferred over packages downloaded from the package registry when searching for dependencies during a build operation.",
			"",
			"The version of the packages will be determined by one of the following:",
			"  - For GIT working copies, the last tag (git describe) is used to determine the version",
			"  - If the package contains a \"version\" field in the package description, this is used",
			"  - If neither of those apply, \"~master\" is assumed"
		];
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(free_args.length == 1, "Missing search path.");
		dub.addSearchPath(free_args[0], m_system);
		return 0;
	}
}

class RemovePathCommand : RegistrationCommand {
	this()
	{
		this.name = "remove-path";
		this.argumentsPattern = "<path>";
		this.description = "Removes a package search path";
		this.helpText = ["Removes a package search path previously added with add-path."];
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(free_args.length == 1, "Expected one argument.");
		dub.removeSearchPath(free_args[0], m_system);
		return 0;
	}
}

class AddLocalCommand : RegistrationCommand {
	this()
	{
		this.name = "add-local";
		this.argumentsPattern = "<path> [<version>]";
		this.description = "Adds a local package directory (e.g. a git repository)";
		this.helpText = [
			"Adds a local package directory to be used during dependency resolution. This command is useful for registering local packages, such as GIT working copies, that are either not available in the package registry, or are supposed to be overwritten.",
			"",
			"The version of the package is either determined automatically (see the \"add-path\" command, or can be explicitly overwritten by passing a version on the command line.",
			"",
			"See 'dub add-path -h' for a way to register multiple local packages at once."
		];
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(free_args.length == 1 || free_args.length == 2, "Expecting one or two arguments.");
		string ver = free_args.length == 2 ? free_args[1] : null;
		dub.addLocalPackage(free_args[0], ver, m_system);
		return 0;
	}
}

class RemoveLocalCommand : RegistrationCommand {
	this()
	{
		this.name = "remove-local";
		this.argumentsPattern = "<path>";
		this.description = "Removes a local package directory";
		this.helpText = ["Removes a local package directory"];
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(free_args.length >= 1, "Missing package path argument.");
		enforceUsage(free_args.length <= 1, "Expected the package path to be the only argument.");
		dub.removeLocalPackage(free_args[0], m_system);
		return 0;
	}
}

class ListCommand : Command {
	this()
	{
		this.name = "list";
		this.argumentsPattern = "";
		this.description = "Prints a list of all local packages dub is aware of";
		this.helpText = [
			"Prints a list of all local packages. This includes all cached packages (user or system wide), all packages in the package search paths (\"dub add-path\") and all manually registered packages (\"dub add-local\")."
		];
	}
	override void prepare(scope CommandArgs args) {}
	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(free_args.length == 0, "Expecting no extra arguments.");
		enforceUsage(app_args.length == 0, "The list command supports no application arguments.");
		logInfo("Packages present in the system and known to dub:");
		foreach (p; dub.packageManager.getPackageIterator())
			logInfo("  %s %s: %s", p.name, p.version_, p.path.toNativeString());
		logInfo("");
		return 0;
	}
}

class SearchCommand : Command {
	this()
	{
		this.name = "search";
		this.argumentsPattern = "<query>";
		this.description = "Search for available packages.";
		this.helpText = [
			"Search all specified DUB registries for packages matching query."
		];
	}
	override void prepare(scope CommandArgs args) {}
	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforce(free_args.length == 1, "Expected one argument.");
		auto res = dub.searchPackages(free_args[0]);
		if (res.empty)
		{
			logError("No matches found.");
			return 1;
		}
		auto justify = res
			.map!((descNmatches) => descNmatches[1])
			.joiner
			.map!(m => m.name.length + m.version_.length)
			.reduce!max + " ()".length;
		justify += (~justify & 3) + 1; // round to next multiple of 4
		foreach (desc, matches; res)
		{
			logInfo("==== %s ====", desc);
			foreach (m; matches)
				logInfo("%s%s", leftJustify(m.name ~ " (" ~ m.version_ ~ ")", justify), m.description);
		}
		return 0;
	}
}


/******************************************************************************/
/* OVERRIDES                                                                  */
/******************************************************************************/

class AddOverrideCommand : Command {
	private {
		bool m_system = false;
	}

	this()
	{
		this.name = "add-override";
		this.argumentsPattern = "<package> <version-spec> <target-path/target-version>";
		this.description = "Adds a new package override.";
		this.helpText = [
		];
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("system", &m_system, [
			"Register system-wide instead of user-wide"
		]);
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(app_args.length == 0, "Unexpected application arguments.");
		enforceUsage(free_args.length == 3, "Expected three arguments, not "~free_args.length.to!string);
		auto scope_ = m_system ? LocalPackageType.system : LocalPackageType.user;
		auto pack = free_args[0];
		auto ver = Dependency(free_args[1]);
		if (existsFile(NativePath(free_args[2]))) {
			auto target = NativePath(free_args[2]);
			if (!target.absolute) target = NativePath(getcwd()) ~ target;
			dub.packageManager.addOverride(scope_, pack, ver, target);
			logInfo("Added override %s %s => %s", pack, ver, target);
		} else {
			auto target = Version(free_args[2]);
			dub.packageManager.addOverride(scope_, pack, ver, target);
			logInfo("Added override %s %s => %s", pack, ver, target);
		}
		return 0;
	}
}

class RemoveOverrideCommand : Command {
	private {
		bool m_system = false;
	}

	this()
	{
		this.name = "remove-override";
		this.argumentsPattern = "<package> <version-spec>";
		this.description = "Removes an existing package override.";
		this.helpText = [
		];
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("system", &m_system, [
			"Register system-wide instead of user-wide"
		]);
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(app_args.length == 0, "Unexpected application arguments.");
		enforceUsage(free_args.length == 2, "Expected two arguments, not "~free_args.length.to!string);
		auto scope_ = m_system ? LocalPackageType.system : LocalPackageType.user;
		dub.packageManager.removeOverride(scope_, free_args[0], Dependency(free_args[1]));
		return 0;
	}
}

class ListOverridesCommand : Command {
	this()
	{
		this.name = "list-overrides";
		this.argumentsPattern = "";
		this.description = "Prints a list of all local package overrides";
		this.helpText = [
			"Prints a list of all overridden packages added via \"dub add-override\"."
		];
	}
	override void prepare(scope CommandArgs args) {}
	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		void printList(in PackageOverride[] overrides, string caption)
		{
			if (overrides.length == 0) return;
			logInfo("# %s", caption);
			foreach (ovr; overrides) {
				if (!ovr.targetPath.empty) logInfo("%s %s => %s", ovr.package_, ovr.version_, ovr.targetPath);
				else logInfo("%s %s => %s", ovr.package_, ovr.version_, ovr.targetVersion);
			}
		}
		printList(dub.packageManager.getOverrides(LocalPackageType.user), "User wide overrides");
		printList(dub.packageManager.getOverrides(LocalPackageType.system), "System wide overrides");
		return 0;
	}
}

/******************************************************************************/
/* Cache cleanup                                                              */
/******************************************************************************/

class CleanCachesCommand : Command {
	this()
	{
		this.name = "clean-caches";
		this.argumentsPattern = "";
		this.description = "Removes cached metadata";
		this.helpText = [
			"This command removes any cached metadata like the list of available packages and their latest version."
		];
	}

	override void prepare(scope CommandArgs args) {}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		return 0;
	}
}

/******************************************************************************/
/* DUSTMITE                                                                   */
/******************************************************************************/

class DustmiteCommand : PackageBuildCommand {
	private {
		int m_compilerStatusCode = int.min;
		int m_linkerStatusCode = int.min;
		int m_programStatusCode = int.min;
		string m_compilerRegex;
		string m_linkerRegex;
		string m_programRegex;
		string m_testPackage;
		bool m_combined;
	}

	this()
	{
		this.name = "dustmite";
		this.argumentsPattern = "<destination-path>";
		this.acceptsAppArgs = true;
		this.description = "Create reduced test cases for build errors";
		this.helpText = [
			"This command uses the Dustmite utility to isolate the cause of build errors in a DUB project.",
			"",
			"It will create a copy of all involved packages and run dustmite on this copy, leaving a reduced test case.",
			"",
			"Determining the desired error condition is done by checking the compiler/linker status code, as well as their output (stdout and stderr combined). If --program-status or --program-regex is given and the generated binary is an executable, it will be executed and its output will also be incorporated into the final decision."
		];
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("compiler-status", &m_compilerStatusCode, ["The expected status code of the compiler run"]);
		args.getopt("compiler-regex", &m_compilerRegex, ["A regular expression used to match against the compiler output"]);
		args.getopt("linker-status", &m_linkerStatusCode, ["The expected status code of the linker run"]);
		args.getopt("linker-regex", &m_linkerRegex, ["A regular expression used to match against the linker output"]);
		args.getopt("program-status", &m_programStatusCode, ["The expected status code of the built executable"]);
		args.getopt("program-regex", &m_programRegex, ["A regular expression used to match against the program output"]);
		args.getopt("test-package", &m_testPackage, ["Perform a test run - usually only used internally"]);
		args.getopt("combined", &m_combined, ["Builds multiple packages with one compiler run"]);
		super.prepare(args);

		// speed up loading when in test mode
		if (m_testPackage.length) {
			skipDubInitialization = true;
			m_nodeps = true;
		}
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		import std.format : formattedWrite;

		if (m_testPackage.length) {
			dub = new Dub(NativePath(getcwd()));

			setupPackage(dub, m_testPackage);
			m_defaultConfig = dub.project.getDefaultConfiguration(m_buildPlatform);

			GeneratorSettings gensettings;
			gensettings.platform = m_buildPlatform;
			gensettings.config = m_buildConfig.length ? m_buildConfig : m_defaultConfig;
			gensettings.buildType = m_buildType;
			gensettings.compiler = m_compiler;
			gensettings.buildSettings = m_buildSettings;
			gensettings.combined = m_combined;
			gensettings.filterVersions = m_filterVersions;
			gensettings.run = m_programStatusCode != int.min || m_programRegex.length;
			gensettings.runArgs = app_args;
			gensettings.force = true;
			gensettings.compileCallback = check(m_compilerStatusCode, m_compilerRegex);
			gensettings.linkCallback = check(m_linkerStatusCode, m_linkerRegex);
			gensettings.runCallback = check(m_programStatusCode, m_programRegex);
			try dub.generateProject("build", gensettings);
			catch (DustmiteMismatchException) {
				logInfo("Dustmite test doesn't match.");
				return 3;
			}
			catch (DustmiteMatchException) {
				logInfo("Dustmite test matches.");
				return 0;
			}
		} else {
			enforceUsage(free_args.length == 1, "Expected destination path.");
			auto path = NativePath(free_args[0]);
			path.normalize();
			enforceUsage(!path.empty, "Destination path must not be empty.");
			if (!path.absolute) path = NativePath(getcwd()) ~ path;
			enforceUsage(!path.startsWith(dub.rootPath), "Destination path must not be a sub directory of the tested package!");

			setupPackage(dub, null);
			auto prj = dub.project;
			if (m_buildConfig.empty)
				m_buildConfig = prj.getDefaultConfiguration(m_buildPlatform);

			void copyFolderRec(NativePath folder, NativePath dstfolder)
			{
				mkdirRecurse(dstfolder.toNativeString());
				foreach (de; iterateDirectory(folder.toNativeString())) {
					if (de.name.startsWith(".")) continue;
					if (de.isDirectory) {
						copyFolderRec(folder ~ de.name, dstfolder ~ de.name);
					} else {
						if (de.name.endsWith(".o") || de.name.endsWith(".obj")) continue;
						if (de.name.endsWith(".exe")) continue;
						try copyFile(folder ~ de.name, dstfolder ~ de.name);
						catch (Exception e) {
							logWarn("Failed to copy file %s: %s", (folder ~ de.name).toNativeString(), e.msg);
						}
					}
				}
			}

			static void fixPathDependency(string pack, ref Dependency dep) {
				if (!dep.path.empty) {
					auto mainpack = getBasePackageName(pack);
					dep.path = NativePath("../") ~ mainpack;
				}
			}

			void fixPathDependencies(ref PackageRecipe recipe, NativePath base_path)
			{
				foreach (name, ref dep; recipe.buildSettings.dependencies)
					fixPathDependency(name, dep);

				foreach (ref cfg; recipe.configurations)
					foreach (name, ref dep; cfg.buildSettings.dependencies)
						fixPathDependency(name, dep);

				foreach (ref subp; recipe.subPackages)
					if (subp.path.length) {
						auto sub_path = base_path ~ NativePath(subp.path);
						auto pack = prj.packageManager.getOrLoadPackage(sub_path);
						fixPathDependencies(pack.recipe, sub_path);
						pack.storeInfo(sub_path);
					} else fixPathDependencies(subp.recipe, base_path);
			}

			bool[string] visited;
			foreach (pack_; prj.getTopologicalPackageList()) {
				auto pack = pack_.basePackage;
				if (pack.name in visited) continue;
				visited[pack.name] = true;
				auto dst_path = path ~ pack.name;
				logInfo("Copy package '%s' to destination folder...", pack.name);
				copyFolderRec(pack.path, dst_path);

				// adjust all path based dependencies
				fixPathDependencies(pack.recipe, dst_path);

				// overwrite package description file with additional version information
				pack.storeInfo(dst_path);
			}

			logInfo("Executing dustmite...");
			auto testcmd = appender!string();
			testcmd.formattedWrite("%s dustmite --vquiet --test-package=%s --build=%s --config=%s",
				thisExePath, prj.name, m_buildType, m_buildConfig);

			if (m_compilerName.length) testcmd.formattedWrite(" \"--compiler=%s\"", m_compilerName);
			if (m_arch.length) testcmd.formattedWrite(" --arch=%s", m_arch);
			if (m_compilerStatusCode != int.min) testcmd.formattedWrite(" --compiler-status=%s", m_compilerStatusCode);
			if (m_compilerRegex.length) testcmd.formattedWrite(" \"--compiler-regex=%s\"", m_compilerRegex);
			if (m_linkerStatusCode != int.min) testcmd.formattedWrite(" --linker-status=%s", m_linkerStatusCode);
			if (m_linkerRegex.length) testcmd.formattedWrite(" \"--linker-regex=%s\"", m_linkerRegex);
			if (m_programStatusCode != int.min) testcmd.formattedWrite(" --program-status=%s", m_programStatusCode);
			if (m_programRegex.length) testcmd.formattedWrite(" \"--program-regex=%s\"", m_programRegex);
			if (m_combined) testcmd ~= " --combined";
			// TODO: pass *all* original parameters
			logDiagnostic("Running dustmite: %s", testcmd);
			auto dmpid = spawnProcess(["dustmite", path.toNativeString(), testcmd.data]);
			return dmpid.wait();
		}
		return 0;
	}

	void delegate(int, string) check(int code_match, string regex_match)
	{
		return (code, output) {
			import std.encoding;
			import std.regex;

			logInfo("%s", output);

			if (code_match != int.min && code != code_match) {
				logInfo("Exit code %s doesn't match expected value %s", code, code_match);
				throw new DustmiteMismatchException;
			}

			if (regex_match.length > 0 && !match(output.sanitize, regex_match)) {
				logInfo("Output doesn't match regex:");
				logInfo("%s", output);
				throw new DustmiteMismatchException;
			}

			if (code != 0 && code_match != int.min || regex_match.length > 0) {
				logInfo("Tool failed, but matched either exit code or output - counting as match.");
				throw new DustmiteMatchException;
			}
		};
	}

	static class DustmiteMismatchException : Exception {
		this(string message = "", string file = __FILE__, int line = __LINE__, Throwable next = null)
		{
			super(message, file, line, next);
		}
	}

	static class DustmiteMatchException : Exception {
		this(string message = "", string file = __FILE__, int line = __LINE__, Throwable next = null)
		{
			super(message, file, line, next);
		}
	}
}


/******************************************************************************/
/* CONVERT command                                                               */
/******************************************************************************/

class ConvertCommand : Command {
	private {
		string m_format;
		bool m_stdout;
	}

	this()
	{
		this.name = "convert";
		this.argumentsPattern = "";
		this.description = "Converts the file format of the package recipe.";
		this.helpText = [
			"This command will convert between JSON and SDLang formatted package recipe files.",
			"",
			"Warning: Beware that any formatting and comments within the package recipe will get lost in the conversion process."
		];
	}

	override void prepare(scope CommandArgs args)
	{
		args.getopt("f|format", &m_format, ["Specifies the target package recipe format. Possible values:", "  json, sdl"]);
		args.getopt("s|stdout", &m_stdout, ["Outputs the converted package recipe to stdout instead of writing to disk."]);
	}

	override int execute(Dub dub, string[] free_args, string[] app_args)
	{
		enforceUsage(app_args.length == 0, "Unexpected application arguments.");
		enforceUsage(free_args.length == 0, "Unexpected arguments: "~free_args.join(" "));
		enforceUsage(m_format.length > 0, "Missing target format file extension (--format=...).");
		if (!loadCwdPackage(dub, true)) return 1;
		dub.convertRecipe(m_format, m_stdout);
		return 0;
	}
}


/******************************************************************************/
/* HELP                                                                       */
/******************************************************************************/

private {
	enum shortArgColumn = 2;
	enum longArgColumn = 6;
	enum descColumn = 24;
	enum lineWidth = 80 - 1;
}

private void showHelp(in CommandGroup[] commands, CommandArgs common_args)
{
	writeln(
`USAGE: dub [--version] [<command>] [<options...>] [-- [<application arguments...>]]

Manages the DUB project in the current directory. If the command is omitted,
DUB will default to "run". When running an application, "--" can be used to
separate DUB options from options passed to the application.

Run "dub <command> --help" to get help for a specific command.

You can use the "http_proxy" environment variable to configure a proxy server
to be used for fetching packages.


Available commands
==================`);

	foreach (grp; commands) {
		writeln();
		writeWS(shortArgColumn);
		writeln(grp.caption);
		writeWS(shortArgColumn);
		writerep!'-'(grp.caption.length);
		writeln();
		foreach (cmd; grp.commands) {
			if (cmd.hidden) continue;
			writeWS(shortArgColumn);
			writef("%s %s", cmd.name, cmd.argumentsPattern);
			auto chars_output = cmd.name.length + cmd.argumentsPattern.length + shortArgColumn + 1;
			if (chars_output < descColumn) {
				writeWS(descColumn - chars_output);
			} else {
				writeln();
				writeWS(descColumn);
			}
			writeWrapped(cmd.description, descColumn, descColumn);
		}
	}
	writeln();
	writeln();
	writeln(`Common options`);
	writeln(`==============`);
	writeln();
	writeOptions(common_args);
	writeln();
	showVersion();
}

private void showVersion()
{
	writefln("DUB version %s, built on %s", getDUBVersion(), __DATE__);
}

private void showCommandHelp(Command cmd, CommandArgs args, CommandArgs common_args)
{
	writefln(`USAGE: dub %s %s [<options...>]%s`, cmd.name, cmd.argumentsPattern, cmd.acceptsAppArgs ? " [-- <application arguments...>]": null);
	writeln();
	foreach (ln; cmd.helpText)
		ln.writeWrapped();

	if (args.recognizedArgs.length) {
		writeln();
		writeln();
		writeln("Command specific options");
		writeln("========================");
		writeln();
		writeOptions(args);
	}

	writeln();
	writeln();
	writeln("Common options");
	writeln("==============");
	writeln();
	writeOptions(common_args);
	writeln();
	writefln("DUB version %s, built on %s", getDUBVersion(), __DATE__);
}

private void writeOptions(CommandArgs args)
{
	foreach (arg; args.recognizedArgs) {
		auto names = arg.names.split("|");
		assert(names.length == 1 || names.length == 2);
		string sarg = names[0].length == 1 ? names[0] : null;
		string larg = names[0].length > 1 ? names[0] : names.length > 1 ? names[1] : null;
		if (sarg !is null) {
			writeWS(shortArgColumn);
			writef("-%s", sarg);
			writeWS(longArgColumn - shortArgColumn - 2);
		} else writeWS(longArgColumn);
		size_t col = longArgColumn;
		if (larg !is null) {
			if (arg.defaultValue.peek!bool) {
				writef("--%s", larg);
				col += larg.length + 2;
			} else {
				writef("--%s=VALUE", larg);
				col += larg.length + 8;
			}
		}
		if (col < descColumn) {
			writeWS(descColumn - col);
		} else {
			writeln();
			writeWS(descColumn);
		}
		foreach (i, ln; arg.helpText) {
			if (i > 0) writeWS(descColumn);
			ln.writeWrapped(descColumn, descColumn);
		}
	}
}

private void writeWrapped(string string, size_t indent = 0, size_t first_line_pos = 0)
{
	// handle pre-indented strings and bullet lists
	size_t first_line_indent = 0;
	while (string.startsWith(" ")) {
		string = string[1 .. $];
		indent++;
		first_line_indent++;
	}
	if (string.startsWith("- ")) indent += 2;

	auto wrapped = string.wrap(lineWidth, getRepString!' '(first_line_pos+first_line_indent), getRepString!' '(indent));
	wrapped = wrapped[first_line_pos .. $];
	foreach (ln; wrapped.splitLines())
		writeln(ln);
}

private void writeWS(size_t num) { writerep!' '(num); }
private void writerep(char ch)(size_t num) { write(getRepString!ch(num)); }

private string getRepString(char ch)(size_t len)
{
	static string buf;
	if (len > buf.length) buf ~= [ch].replicate(len-buf.length);
	return buf[0 .. len];
}

/***
*/


private void enforceUsage(bool cond, string text)
{
	if (!cond) throw new UsageException(text);
}

private class UsageException : Exception {
	this(string message, string file = __FILE__, int line = __LINE__, Throwable next = null)
	{
		super(message, file, line, next);
	}
}

private void warnRenamed(string prev, string curr)
{
	logWarn("The '%s' Command was renamed to '%s'. Please update your scripts.", prev, curr);
}

private bool addDependency(Dub dub, ref PackageRecipe recipe, string depspec)
{
	Dependency dep;
	const parts = splitPackageName(depspec);
	const depname = parts.name;
	if (parts.version_)
		dep = Dependency(parts.version_);
	else
	{
		try {
			const ver = dub.getLatestVersion(depname);
			dep = ver.isBranch ? Dependency(ver) : Dependency("~>" ~ ver.toString());
		} catch (Exception e) {
			logError("Could not find package '%s'.", depname);
			logDebug("Full error: %s", e.toString().sanitize);
			return false;
		}
	}
	recipe.buildSettings.dependencies[depname] = dep;
	logInfo("Adding dependency %s %s", depname, dep.versionSpec);
	return true;
}

private struct PackageAndVersion
{
	string name;
	string version_;
}

/* Split <package>=<version-specifier> and <package>@<version-specifier>
   into `name` and `version_`. */
private PackageAndVersion splitPackageName(string packageName)
{

	// split <package>=<version-specifier>
	auto parts = packageName.findSplit("=");
	if (parts[1].empty) {
		// support splitting <package>@<version-specified> too
		parts = packageName.findSplit("@");
	}

	PackageAndVersion p;
	p.name = parts[0];
	if (!parts[1].empty)
		p.version_ = parts[2];
	return p;
}

// https://github.com/dlang/dub/issues/1681
unittest
{
	auto pv = splitPackageName("");
	assert(pv.name == "");
	assert(pv.version_ is null);
}
