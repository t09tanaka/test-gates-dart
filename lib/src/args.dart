/// The commands this version implements.
const commands = [
  'lcov',
  'check',
  'test',
  'selfcheck',
  'timezones',
  'mutation',
  'mutation-result',
  'all',
];

class ParsedArgs {
  String? command;
  bool help = false;
  bool version = false;
  String dir = '.';

  /// `--file` (lcov, test, selfcheck).
  String? file;

  /// `--all` / `--first` (selfcheck). `--all` (timezones): every gate, also
  /// one that does not name `DateTime`.
  String? mode;

  /// `--zone` (timezones), once per zone: the zones to run the tests in.
  /// Empty means the built-in ones.
  List<String> zones = const [];

  /// `--report` (mutation, mutation-result).
  String? report;

  /// `--force` (mutation): handed to `dart_mutant run`, which then reuses no
  /// result of an earlier run.
  bool force = false;

  /// `--selfcheck` (test): the run of the tests is also the negative
  /// control, with a probe in every gate.
  bool selfcheck = false;

  /// `--no-mutation` (all): the mutation test is left out.
  bool noMutation = false;

  /// `--not-evaluable` (mutation, mutation-result): the mutants that could
  /// not be evaluated are listed, not only counted.
  bool notEvaluable = false;

  /// `--gate` (mutation, mutation-result), once per gate: only these gates
  /// are run and judged. Empty means every gate.
  List<String> gates = const [];

  /// What follows `--`. test, selfcheck: the command to run instead of
  /// `settings.gateCommand`. mutation: what is handed to `dart_mutant run`.
  List<String> rest = const [];
}

class UsageError implements Exception {
  UsageError(this.message);

  final String message;

  @override
  String toString() => message;
}

const _valueOptions = ['--dir', '--file', '--report', '--gate', '--zone'];

const _optionsByCommand = {
  'lcov': ['--dir', '--file'],
  'check': ['--dir'],
  'test': ['--dir', '--file', '--selfcheck'],
  'selfcheck': ['--dir', '--file', '--all', '--first'],
  'timezones': ['--dir', '--all', '--zone'],
  'mutation': ['--dir', '--report', '--force', '--gate', '--not-evaluable'],
  'mutation-result': ['--dir', '--report', '--gate', '--not-evaluable'],
  'all': ['--dir', '--selfcheck', '--force', '--no-mutation'],
};

/// The commands that take something after `--`: a command to run, or (for
/// mutation) the options that are handed to `dart_mutant run`.
const _commandsWithRest = ['test', 'selfcheck', 'timezones', 'mutation'];

/// Reads the argument at [index] (and its value, when it is given
/// separately) into [parsed]. Returns the index of the next argument to read.
int _consume(
  ParsedArgs parsed,
  List<String> argv,
  int index,
  List<String> allowed,
) {
  final arg = argv[index];
  index++;
  if (arg == '--') {
    if (!_commandsWithRest.contains(parsed.command)) {
      throw UsageError(
        '"--" is only accepted by the test, selfcheck, timezones and '
        'mutation commands',
      );
    }
    parsed.rest = argv.sublist(index);
    if (parsed.rest.isEmpty) {
      throw UsageError(
        parsed.command == 'mutation'
            ? '"--" must be followed by the options for dart_mutant run'
            : '"--" must be followed by the command to run',
      );
    }
    return argv.length;
  }
  if (arg == '--help' || arg == '-h') {
    parsed.help = true;
    return index;
  }
  if (arg == '--version' || arg == '-v') {
    parsed.version = true;
    return index;
  }
  final equals = arg.indexOf('=');
  final name = equals == -1 ? arg : arg.substring(0, equals);
  if (!allowed.contains(name)) {
    throw UsageError(
      parsed.command == null
          ? 'unknown argument: $arg'
          : 'unknown argument for ${parsed.command}: $arg',
    );
  }
  if (!_valueOptions.contains(name)) {
    if (equals != -1) {
      throw UsageError('$name does not take a value');
    }
    if (name == '--force') {
      parsed.force = true;
      return index;
    }
    if (name == '--not-evaluable') {
      parsed.notEvaluable = true;
      return index;
    }
    if (name == '--selfcheck') {
      parsed.selfcheck = true;
      return index;
    }
    if (name == '--no-mutation') {
      parsed.noMutation = true;
      return index;
    }
    final mode = name == '--all' ? 'all' : 'first';
    if (parsed.mode != null && parsed.mode != mode) {
      throw UsageError('--all and --first cannot be combined');
    }
    parsed.mode = mode;
    return index;
  }
  final String? value;
  if (equals != -1) {
    value = arg.substring(equals + 1);
  } else {
    value = index < argv.length ? argv[index] : null;
    index++;
  }
  if (value == null || value.isEmpty) {
    throw UsageError('$name needs a value');
  }
  if (name == '--dir') {
    parsed.dir = value;
  } else if (name == '--report') {
    parsed.report = value;
  } else if (name == '--gate') {
    parsed.gates = [...parsed.gates, value];
  } else if (name == '--zone') {
    parsed.zones = [...parsed.zones, value];
  } else {
    parsed.file = value;
  }
  return index;
}

/// Parses the command line (without the executable).
///
/// Same shape as upstream: the command comes first, a value is given as
/// `--name value` or `--name=value`, and anything unknown is an error.
ParsedArgs parseArgs(List<String> argv) {
  final parsed = ParsedArgs();
  var index = 0;
  if (argv.isNotEmpty && !argv.first.startsWith('-')) {
    final first = argv.first;
    if (!commands.contains(first)) {
      throw UsageError('unknown command: $first');
    }
    parsed.command = first;
    index = 1;
  }
  final allowed = _optionsByCommand[parsed.command] ?? const <String>[];
  while (index < argv.length) {
    index = _consume(parsed, argv, index, allowed);
  }
  return parsed;
}

/// The checks `all` runs, in this order, each as the command line it would
/// have by itself (without the executable): `check`, `test`, `timezones`
/// and `mutation`, in the package of [args].
///
/// `--selfcheck` is handed to `test` and `--force` to `mutation`;
/// `--no-mutation` leaves `mutation` out. Each check then is the command of
/// that name, with its own output and its own exit code.
List<List<String>> stepsOfAll(ParsedArgs args) => [
  ['check', '--dir', args.dir],
  ['test', if (args.selfcheck) '--selfcheck', '--dir', args.dir],
  ['timezones', '--dir', args.dir],
  if (!args.noMutation)
    ['mutation', if (args.force) '--force', '--dir', args.dir],
];
