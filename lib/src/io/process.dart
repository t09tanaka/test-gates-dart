import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Waits for SIGINT (Ctrl-C), SIGTERM or SIGHUP (the terminal was closed)
/// instead of letting them end the process, so that the caller can put files back first.
///
/// While this is active the signal no longer terminates the process: the
/// caller has to return when [received] completes.
class SignalWatch {
  SignalWatch() {
    for (final signal in [
      ProcessSignal.sigint,
      // Windows only delivers SIGINT.
      if (!Platform.isWindows) ...[ProcessSignal.sigterm, ProcessSignal.sighup],
    ]) {
      _subscriptions.add(
        signal.watch().listen((signal) {
          if (!_received.isCompleted) {
            this.signal = signal;
            _received.complete(signal);
          }
        }),
      );
    }
  }

  final _received = Completer<ProcessSignal>();
  final _subscriptions = <StreamSubscription<ProcessSignal>>[];

  /// The first signal that arrived, if any.
  ProcessSignal? signal;

  /// Completes with the first signal.
  Future<ProcessSignal> get received => _received.future;

  /// Gives the signals back to their default handling.
  Future<void> cancel() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }
}

/// The exit code of a process ended by [signal], as a shell reports it.
int signalExitCode(ProcessSignal signal) => switch (signal) {
  ProcessSignal.sigint => 130,
  ProcessSignal.sighup => 129,
  _ => 143,
};

class CommandResult {
  const CommandResult({
    this.exitCode,
    this.output = '',
    this.startError,
    this.signal,
    this.timedOut = false,
    this.killed = false,
  });

  /// `null` when the command could not be started or was interrupted.
  final int? exitCode;

  /// stdout and stderr, when captured.
  final String output;

  /// Why the command could not be started.
  final String? startError;

  /// The signal that interrupted the run.
  final ProcessSignal? signal;

  /// True when the command was ended because it ran longer than its limit.
  final bool timedOut;

  /// True when the command was handed a signal, did not end within its
  /// grace, and was killed: it may not have put back what it changed.
  final bool killed;
}

/// The processes that descend from [root], as `ps` lists them now. Empty on
/// Windows and when `ps` cannot be run.
List<int> descendantsOf(int root) {
  if (Platform.isWindows) {
    return const [];
  }
  final ProcessResult listed;
  try {
    listed = Process.runSync('ps', const ['-A', '-o', 'pid=,ppid=']);
  } on ProcessException {
    return const [];
  }
  if (listed.exitCode != 0) {
    return const [];
  }
  final children = <int, List<int>>{};
  for (final line in (listed.stdout as String).split('\n')) {
    final fields = line.trim().split(RegExp(r'\s+'));
    final pid = fields.length == 2 ? int.tryParse(fields[0]) : null;
    final parent = fields.length == 2 ? int.tryParse(fields[1]) : null;
    if (pid != null && parent != null) {
      children.putIfAbsent(parent, () => []).add(pid);
    }
  }
  final found = <int>[];
  final queue = [root];
  while (queue.isNotEmpty) {
    for (final child in children[queue.removeLast()] ?? const <int>[]) {
      found.add(child);
      queue.add(child);
    }
  }
  return found;
}

/// Ends [process] and what it started: SIGTERM first, so that it can clean
/// up, then SIGKILL for whatever is left after [grace]. A test runner that is
/// killed alone can leave the process that runs the tests behind, spinning
/// in the very loop that made it time out.
Future<void> _endTree(Process process, Duration grace) async {
  final descendants = descendantsOf(process.pid);
  process.kill();
  await process.exitCode.timeout(
    grace,
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return process.exitCode;
    },
  );
  for (final pid in descendants) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}

/// The processes of [pids] that are still there, as `ps` lists them now.
/// Empty on Windows and when `ps` cannot be run.
List<int> _stillThere(List<int> pids) {
  if (Platform.isWindows || pids.isEmpty) {
    return const [];
  }
  final ProcessResult listed;
  try {
    listed = Process.runSync('ps', ['-o', 'pid=', '-p', pids.join(',')]);
  } on ProcessException {
    return const [];
  }
  return [
    for (final line in (listed.stdout as String).split('\n'))
      ?int.tryParse(line.trim()),
  ];
}

/// Hands [signal] to [process] and to what it started, and waits until all
/// of them have ended. For a tool that puts files back itself when it is
/// interrupted: ending it the hard way would keep it from doing so, and the
/// program that was started is often only a launcher (a shell script, or
/// `dart pub global run`) that does not pass a signal on.
///
/// [seen] are the processes that descended from it a moment ago. A launcher
/// that has ended already has no descendants any more, and the tool it
/// started is still at work.
///
/// What is still there after [grace] is killed; the result is then `true`.
Future<bool> _handOver(
  Process process,
  ProcessSignal? signal,
  Duration grace,
  List<int> seen,
  List<int> Function(int root) listDescendants,
) async {
  var descendants = {...seen, ...listDescendants(process.pid)}.toList();
  if (signal != null) {
    process.kill(signal);
    for (final pid in descendants) {
      Process.killPid(pid, signal);
    }
  }
  var exited = false;
  unawaited(process.exitCode.then((_) => exited = true));
  final waited = Stopwatch()..start();
  while (waited.elapsed < grace) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // A process that has ended is not looked for again: its number can be
    // given to another process, which is not ours to end.
    descendants = _stillThere(descendants);
    if (exited && descendants.isEmpty) {
      return false;
    }
  }
  // Once more: what ended in the last moment was not killed.
  descendants = _stillThere(descendants);
  if (exited && descendants.isEmpty) {
    return false;
  }
  if (!exited) {
    process.kill(ProcessSignal.sigkill);
  }
  for (final pid in descendants) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
  return true;
}

/// How long a tool that was handed a signal gets to put things back. It
/// ends its own test runs first, each with a grace of its own.
const handOverGrace = Duration(seconds: 60);

/// How long a child gets to end after SIGTERM before it is killed.
const _killGrace = Duration(seconds: 10);

/// The same for a child that ran into its time limit: it is not expected to
/// answer at all.
const _limitGrace = Duration(seconds: 3);

class _LimitReached {
  const _LimitReached();
}

/// How long the output of a child that has ended is waited for. A process it
/// left behind can keep the pipes open for good.
const _drainGrace = Duration(seconds: 5);

/// How long a signal is waited for after a child failed. Ctrl-C reaches the
/// child as well, and the child can end before the signal is seen here.
const _signalGrace = Duration(milliseconds: 250);

/// Runs [command] (program first) in [workingDirectory] without a shell, so
/// that no argument is interpreted. On Windows a shell is used, because
/// `flutter` and `dart` are batch files there.
///
/// On a signal, and at the time limit, the process is ended together with
/// the processes that descend from it (found with `ps`; on Windows, and where
/// there is no `ps`, only the process itself).
///
/// [environment] is added to the environment of this process for the
/// command.
///
/// With [capture] the output is collected; otherwise it goes to the terminal.
/// When [signals] reports a signal, the child is ended and the result carries
/// the signal. When the command runs longer than [timeout], it is ended with
/// everything it started and the result says so.
///
/// With [handOver] a signal is not answered by ending the command: the
/// signal is passed on to it and to every process that descends from it, and
/// they are waited for, because the command puts files back itself. What is
/// still there after [grace] is killed, and the result says so.
///
/// [listDescendants] lists what descends from a process; a test passes its own
/// to decide what a listing sees.
Future<CommandResult> runCommand(
  List<String> command, {
  required String workingDirectory,
  required bool capture,
  required SignalWatch signals,
  Duration? timeout,
  bool handOver = false,
  Duration grace = handOverGrace,
  Map<String, String>? environment,
  List<int> Function(int root) listDescendants = descendantsOf,
}) async {
  final Process process;
  try {
    process = await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: Platform.isWindows,
      mode: capture ? ProcessStartMode.normal : ProcessStartMode.inheritStdio,
    );
  } on ProcessException catch (error) {
    return CommandResult(startError: error.message);
  }

  final output = StringBuffer();
  final drained = <Future<void>>[];
  if (capture) {
    for (final stream in [process.stdout, process.stderr]) {
      drained.add(
        stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .forEach(output.write),
      );
    }
  }

  // For [handOver]: what descends from the command, as of a moment ago. A
  // process whose parent has ended is no longer listed under the command: a
  // listing taken after a launcher ended, and before that end is seen here,
  // is empty. It does not replace the last one, which has the tool behind
  // the launcher in it.
  var seen = const <int>[];
  final watch = handOver
      ? Timer.periodic(const Duration(milliseconds: 500), (_) {
          final listed = listDescendants(process.pid);
          if (listed.isNotEmpty) {
            seen = listed;
          }
        })
      : null;

  final limit = Completer<_LimitReached>();
  final timer = timeout == null
      ? null
      : Timer(timeout, () => limit.complete(const _LimitReached()));
  final ended = await Future.any<Object>([
    process.exitCode,
    signals.received,
    limit.future,
  ]);
  timer?.cancel();
  watch?.cancel();
  if (ended is ProcessSignal) {
    var killed = false;
    if (handOver) {
      killed = await _handOver(process, ended, grace, seen, listDescendants);
    } else {
      await _endTree(process, _killGrace);
    }
    return CommandResult(
      output: output.toString(),
      signal: ended,
      killed: killed,
    );
  }
  if (ended is _LimitReached) {
    await _endTree(process, _limitGrace);
    return CommandResult(output: output.toString(), timedOut: true);
  }
  await Future.any<Object?>([
    Future.wait(drained).timeout(_drainGrace, onTimeout: () => const []),
    signals.received,
  ]);
  if (ended != 0 && signals.signal == null) {
    await Future.any<Object?>([
      Future<void>.delayed(_signalGrace),
      signals.received,
    ]);
  }
  var killed = false;
  if (handOver && signals.signal != null) {
    // The signal reached the command before it was seen here (Ctrl-C goes
    // to both), and what was started has ended: a launcher, perhaps. The
    // tool behind it has the signal as well, and is waited for.
    killed = await _handOver(process, null, grace, seen, listDescendants);
  }
  return CommandResult(
    exitCode: signals.signal == null ? ended as int : null,
    output: output.toString(),
    signal: signals.signal,
    killed: killed,
  );
}
