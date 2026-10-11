import 'dart:convert';

import 'package:test/test.dart';
import 'package:test_gates/src/mutation_result.dart';
import 'package:test_gates/src/mutation_run.dart';
import 'package:test_gates/src/mutators.dart';
import 'package:test_gates/src/version.dart';

void main() {
  group('the test command', () {
    test('a pubspec with a dependency from the Flutter SDK needs flutter '
        'test', () {
      expect(
        usesFlutter('name: a\ndependencies:\n  flutter:\n    sdk: flutter\n'),
        isTrue,
      );
      expect(
        usesFlutter(
          'name: a\r\ndev_dependencies:\r\n  flutter_test:\r\n'
          '    sdk: flutter # tests\r\n',
        ),
        isTrue,
      );
      expect(
        usesFlutter(
          'name: flutter\nenvironment:\n  sdk: ^3.9.0\n'
          'dependencies:\n  flutter_lints: ^6.0.0\n',
        ),
        isFalse,
      );
    });

    test('flutter test --no-pub, dart test, or what was given', () {
      expect(testCommandFor(flutter: true), ['flutter', 'test', '--no-pub']);
      expect(testCommandFor(flutter: false), ['dart', 'test']);
      expect(
        testCommandFor(flutter: true, override: ['fvm', 'flutter', 'test']),
        ['fvm', 'flutter', 'test'],
      );
    });

    test('a mutant is run with fail-fast, the limit of a test, and the '
        'tests of the gate', () {
      expect(mutantCommand(['dart', 'test'], ['test/a_test.dart']), [
        'dart',
        'test',
        '--fail-fast',
        '--timeout',
        '10s',
        'test/a_test.dart',
      ]);
    });
  });

  test('the process limit is three times the run without a mutant plus 20 '
      'seconds', () {
    expect(processLimit(Duration.zero), const Duration(seconds: 20));
    expect(
      processLimit(const Duration(milliseconds: 1500)),
      const Duration(milliseconds: 24500),
    );
  });

  group('classifyRun', () {
    String classify(int? exitCode, String output, {bool timedOut = false}) =>
        classifyRun(exitCode: exitCode, output: output, timedOut: timedOut);

    test('the limit was reached: Timeout, whatever was printed', () {
      expect(classify(null, 'a.dart:1:1: Error: x', timedOut: true), 'Timeout');
    });

    test('the tests passed: Survived', () {
      expect(classify(0, 'All tests passed!'), 'Survived');
      // A test that prints the word is not a compile error.
      expect(classify(0, 'Compilation failed'), 'Survived');
    });

    test('a test failed: Killed', () {
      expect(classify(1, 'Expected: 1\n  Actual: 2'), 'Killed');
      expect(classify(79, ''), 'Killed');
      expect(classify(1, 'Error: Bad state at a.dart 12:3'), 'Killed');
    });

    test('the code did not compile: CompileError', () {
      expect(
        classify(
          1,
          "lib/a.dart:12:3: Error: A value of type 'int' can't be returned.",
        ),
        'CompileError',
      );
      expect(
        classify(1, 'Failed to load "a_test.dart": Compilation failed for x'),
        'CompileError',
      );
    });
  });

  group('positionOf', () {
    test('1-based line and column', () {
      const source = 'ab\ncd\n\nef';
      expect(positionOf(source, 0), (line: 1, column: 1));
      expect(positionOf(source, 1), (line: 1, column: 2));
      // The line break itself is the last column of its line.
      expect(positionOf(source, 2), (line: 1, column: 3));
      expect(positionOf(source, 3), (line: 2, column: 1));
      expect(positionOf(source, 6), (line: 3, column: 1));
      expect(positionOf(source, 7), (line: 4, column: 1));
      expect(positionOf(source, 9), (line: 4, column: 3));
    });

    test('a \\r before the line break belongs to the line', () {
      expect(positionOf('ab\r\ncd', 4), (line: 2, column: 1));
      expect(positionOf('ab\r\ncd', 2), (line: 1, column: 3));
    });
  });

  group('buildReport', () {
    GateRun runOf(String source) {
      final mutants = findMutants(source).mutants;
      return GateRun(
        source: source,
        mutants: mutants,
        statuses: List.filled(mutants.length, 'Killed'),
        milliseconds: List.filled(mutants.length, 7),
      );
    }

    test('the schema of mutation-testing-elements', () {
      const source = 'int f(int a) => a + 1;\n';
      final report = buildReport({'lib/a.dart': runOf(source)});
      expect(report, {
        'schemaVersion': '2',
        'thresholds': {'high': 100, 'low': 100},
        'framework': {'name': 'test_gates', 'version': packageVersion},
        'files': {
          'lib/a.dart': {
            'language': 'dart',
            'source': source,
            'mutants': [
              {
                'id': 'lib/a.dart#0',
                'mutatorName': 'ArithmeticOperator',
                'replacement': '-',
                'status': 'Killed',
                'duration': 7,
                'location': {
                  'start': {'line': 1, 'column': 19},
                  'end': {'line': 1, 'column': 20},
                },
              },
            ],
          },
        },
      });
    });

    test('the files of an earlier report that the run left out come '
        'first, as they were', () {
      final report = buildReport(
        {'lib/b.dart': runOf('int f(int a) => a + 1;\n')},
        others: {
          'lib/a.dart': {'source': 'x', 'mutants': <Object?>[]},
        },
      );
      final files = report['files']! as Map<String, Object?>;
      expect(files.keys, ['lib/a.dart', 'lib/b.dart']);
      expect(files['lib/a.dart'], {'source': 'x', 'mutants': <Object?>[]});
    });

    for (final (name, lineBreak) in [('LF', '\n'), ('CRLF', '\r\n')]) {
      test('every location cuts the text the mutant replaces ($name), also '
          'over several lines and after non-ASCII text', () {
        final source = [
          '// 割引後の金額 😀',
          'int f(int a, bool b) {',
          '  if (b) {',
          "    return a + 'é😀'.length;",
          '  }',
          '  return a;',
          '}',
          '',
        ].join(lineBreak);
        final run = runOf(source);
        expect(
          run.mutants.map((mutant) => mutant.mutator),
          containsAll(['BlockStatement', 'StringLiteral']),
        );
        final parsed = parseMutationReport(
          jsonEncode(buildReport({'lib/a.dart': run})),
        );
        final file = parsed.files['lib/a.dart']!;
        expect(file.source, source);
        for (final (index, mutant) in file.mutants.indexed) {
          final expected = source
              .substring(run.mutants[index].offset, run.mutants[index].end)
              .replaceAll('\r\n', '\n');
          expect(
            sliceByLocation(
              source.replaceAll('\r\n', '\n'),
              mutant.start,
              mutant.end,
            ),
            expected,
            reason: '${mutant.mutatorName} → ${mutant.replacement}',
          );
        }
      });
    }
  });

  group('selectGates (--gate)', () {
    const gates = ['lib/a.dart', 'lib/b.dart', 'lib/c.dart'];
    List<List<String>> select(List<String> requested) {
      final selection = selectGates(gates, requested);
      return [selection.selected, selection.unknown];
    }

    test('no request is every gate', () {
      expect(select(const []), [gates, <String>[]]);
    });

    test('the requested gates, in the order of the list and each once', () {
      expect(select(const ['lib/c.dart', 'lib/a.dart', 'lib/c.dart']), [
        ['lib/a.dart', 'lib/c.dart'],
        <String>[],
      ]);
    });

    test('a path that is not a gate is named, once', () {
      expect(select(const ['lib/x.dart', 'lib/b.dart', 'lib/x.dart']), [
        ['lib/b.dart'],
        ['lib/x.dart'],
      ]);
      // The path as it is written in test-gates.json, nothing else.
      expect(select(const ['./lib/a.dart', 'lib/A.dart']), [
        <String>[],
        ['./lib/a.dart', 'lib/A.dart'],
      ]);
    });
  });

  group('carriedResults', () {
    const saved = <String, Object?>{'lib/a.dart': 1, 'lib/b.dart': 2};

    test('without --force everything is carried', () {
      expect(carriedResults(saved, force: false, selected: null), saved);
      expect(
        carriedResults(saved, force: false, selected: const ['lib/a.dart']),
        saved,
      );
    });

    test('--force forgets the gates of the run, and only those', () {
      expect(carriedResults(saved, force: true, selected: null), isEmpty);
      expect(
        carriedResults(saved, force: true, selected: const ['lib/a.dart']),
        {'lib/b.dart': 2},
      );
      expect(carriedResults(saved, force: true, selected: const []), saved);
    });
  });

  group('otherReportFiles (--gate)', () {
    final existing = jsonEncode({
      'schemaVersion': '2',
      'files': {
        'lib/a.dart': {'source': 'a', 'mutants': <Object?>[]},
        'lib/b.dart': {'source': 'b', 'mutants': <Object?>[]},
      },
    });

    test('keeps the files of the gates that are not run', () {
      expect(otherReportFiles(existing, const ['lib/b.dart']), {
        'lib/a.dart': {'source': 'a', 'mutants': <Object?>[]},
      });
      expect(
        otherReportFiles(existing, const ['lib/a.dart', 'lib/b.dart']),
        isEmpty,
      );
      expect(otherReportFiles(existing, const ['lib/c.dart']).keys, [
        'lib/a.dart',
        'lib/b.dart',
      ]);
    });

    test('a selected gate is not kept under another spelling of its '
        'path', () {
      final other = jsonEncode({
        'files': {
          './lib/a.dart': {'source': 'a'},
          r'lib\b.dart': {'source': 'b'},
          'lib/c.dart': {'source': 'c'},
        },
      });
      expect(otherReportFiles(other, const ['lib/a.dart', 'lib/b.dart']).keys, [
        'lib/c.dart',
      ]);
      expect(otherReportFiles(other, const ['./lib/c.dart']).keys, [
        './lib/a.dart',
        r'lib\b.dart',
      ]);
    });

    test('nothing is kept without a report, or of a file that is not '
        'one', () {
      expect(otherReportFiles(null, const ['lib/b.dart']), isEmpty);
      expect(otherReportFiles('not json', const ['lib/b.dart']), isEmpty);
      expect(otherReportFiles('[]', const ['lib/b.dart']), isEmpty);
      expect(otherReportFiles('{}', const ['lib/b.dart']), isEmpty);
      expect(otherReportFiles('{"files": 1}', const ['lib/b.dart']), isEmpty);
    });
  });

  group('results of an earlier run', () {
    const input = GateInput(
      source: 'int f(int a) => a + 1;\n',
      specs: {'lib/a_test.dart': 'test'},
      command: ['dart', 'test'],
    );
    Object? saved(List<String> statuses) =>
        jsonDecode(jsonEncode(incrementalEntry(input, statuses)));

    test('what is compared: the gate, its tests, the command, and the '
        'versions of the tool and of the mutators', () {
      expect(input.toJson(), {
        'toolVersion': packageVersion,
        'mutatorsVersion': mutatorsVersion,
        'command': ['dart', 'test'],
        'source': 'int f(int a) => a + 1;\n',
        'specs': {'lib/a_test.dart': 'test'},
      });
    });

    test('are reused for the same gate, tests, command and versions', () {
      expect(
        reusableStatuses(
          saved(['Killed', 'Survived', 'CompileError']),
          input,
          3,
        ),
        ['Killed', 'Survived', 'CompileError'],
      );
    });

    test('a Timeout is measured again', () {
      expect(reusableStatuses(saved(['Timeout', 'Killed']), input, 2), [
        null,
        'Killed',
      ]);
    });

    test('are not reused when anything that decides the result differs', () {
      final entry = saved(['Killed']);
      for (final (name, other) in [
        (
          'the gate',
          GateInput(
            source: '${input.source} ',
            specs: input.specs,
            command: input.command,
          ),
        ),
        (
          'a test',
          GateInput(
            source: input.source,
            specs: const {'lib/a_test.dart': 'test 2'},
            command: input.command,
          ),
        ),
        (
          'which tests',
          GateInput(
            source: input.source,
            specs: const {'test/a_test.dart': 'test'},
            command: input.command,
          ),
        ),
        (
          'one more test',
          GateInput(
            source: input.source,
            specs: const {'lib/a_test.dart': 'test', 'test/a_test.dart': ''},
            command: input.command,
          ),
        ),
        (
          'the command',
          GateInput(
            source: input.source,
            specs: input.specs,
            command: const ['flutter', 'test'],
          ),
        ),
      ]) {
        expect(reusableStatuses(entry, other, 1), isNull, reason: name);
      }
    });

    test('are not reused when the tool or the mutators changed', () {
      for (final key in ['toolVersion', 'mutatorsVersion']) {
        final entry = saved(['Killed'])! as Map<String, Object?>;
        (entry['input']! as Map<String, Object?>)[key] = 'other';
        expect(reusableStatuses(entry, input, 1), isNull, reason: key);
      }
      expect(
        (saved(['Killed'])! as Map<String, Object?>)['input'],
        containsPair('mutatorsVersion', mutatorsVersion),
      );
    });

    test('are not reused when the entry is not what this version wrote', () {
      expect(reusableStatuses(null, input, 1), isNull);
      expect(reusableStatuses('x', input, 1), isNull);
      expect(reusableStatuses(saved(['Killed']), input, 2), isNull);
      expect(
        reusableStatuses(
          {
            'input': input.toJson(),
            'statuses': [1],
          },
          input,
          1,
        ),
        isNull,
      );
      expect(reusableStatuses({'input': input.toJson()}, input, 1), isNull);
    });
  });

  group('isLeftoverOf', () {
    const original = 'int f(int a) => a + 1;\n';

    test('one of the mutants of the original is a leftover', () {
      expect(isLeftoverOf(original, 'int f(int a) => a - 1;\n'), isTrue);
    });

    test('the original, and anything else, is not', () {
      expect(isLeftoverOf(original, original), isFalse);
      expect(isLeftoverOf(original, 'int f(int a) => a * 1;\n'), isFalse);
      expect(isLeftoverOf(original, 'int f(int a) => a - 1;\n\n'), isFalse);
      expect(isLeftoverOf(original, ''), isFalse);
      expect(isLeftoverOf('not dart (', 'not dart'), isFalse);
    });
  });
}
