final _drive = RegExp('^[A-Za-z]:');

/// True for a path written the way test-gates.json wants it: relative to the
/// package, with "/" and without "." / ".." / empty segments.
///
/// An absolute path (`/lib/a.dart`) starts with an empty segment.
bool isPlainRelativePath(String path) =>
    !_drive.hasMatch(path) &&
    !path.contains(r'\') &&
    !path
        .split('/')
        .any((segment) => segment == '..' || segment == '.' || segment.isEmpty);
