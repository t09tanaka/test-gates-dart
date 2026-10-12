/// The commands this version implements.
const commands = [
  'lcov',
  'check',
  'test',
  'selfcheck',
  'mutation',
  'mutation-result',
];

class ParsedArgs {
  String? command;
  bool help = false;
  bool version = false;
  String dir = '.';

  /// `--file` (lcov, test, selfcheck).
  String? file;

  /// `--all` / `--first` (selfcheck).
  String? mode;

  /// `--report` (mutation, mutation-result).
  String? report;

  /// `--force` (mutation): handed to `dart_mutant run`, which then reuses no
  /// result of an earlier run.
  bool force = false;

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

const _valueOptions = ['--dir', '--file', '--report', '--gate'];

const _optionsByCommand = {
  'lcov': ['--dir', '--file'],
  'check': ['--dir'],
  'test': ['--dir', '--file'],
  'selfcheck': ['--dir', '--file', '--all', '--first'],
  'mutation': ['--dir', '--report', '--force', '--gate'],
  'mutation-result': ['--dir', '--report', '--gate'],
};

/// The commands that take something after `--`: a command to run, or (for
/// mutation) the options that are handed to `dart_mutant run`.
const _commandsWithRest = ['test', 'selfcheck', 'mutation'];

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
        '"--" is only accepted by the test, selfcheck and mutation commands',
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
