// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:image/image.dart';
import 'package:path/path.dart' as p;

import 'environment.dart';
import 'goldens.dart';
import 'skia_client.dart';

/// Whether this code is running on LUCI.
bool _isLuci = Platform.environment.containsKey('SWARMING_TASK_ID') && Platform.environment.containsKey('GOLDCTL');
bool _isPreSubmit = _isLuci && Platform.environment.containsKey('GOLD_TRYJOB');
bool _isPostSubmit = _isLuci && !_isPreSubmit;


/// Compares a screenshot taken through a test with its golden.
///
/// Used by Flutter Web Engine unit tests and the integration tests.
///
/// Returns the results of the tests as `String`. When tests passes the result
/// is simply `OK`, however when they fail it contains a detailed explanation
/// on which files are compared, their absolute locations and an HTML page
/// that the developer can see the comparison.
Future<String> compareImage(
  Image screenshot,
  bool doUpdateScreenshotGoldens,
  String filename,
  PixelComparison pixelComparison,
  double maxDiffRateFailure,
  SkiaGoldClient? skiaClient, {
  // TODO(mdebbar): Remove these args with goldens repo.
  String goldensDirectory = '',
  String filenameSuffix = '',
  bool write = false,
}) async {
  if (_isLuci && skiaClient != null) {
    // This is temporary to get started by uploading existing screenshots to
    // Skia Gold. The next step would be to actually use Skia Gold for
    // comparison.

    // TODO(mdebbar): Use Skia Gold for comparison, not only for uploading.
    await _uploadToSkiaGold(skiaClient, screenshot, filename);
  }

  filename = filename.replaceAll('.png', '$filenameSuffix.png');

  final Environment environment = Environment();
  if (goldensDirectory.isEmpty) {
    goldensDirectory = p.join(
      environment.webUiGoldensRepositoryDirectory.path,
      'engine',
      'web',
    );
  }
  // Bail out fast if golden doesn't exist, and user doesn't want to create it.
  final File file = File(p.join(
    goldensDirectory,
    filename,
  ));
  if (!file.existsSync() && !write) {
    return '''
Golden file $filename does not exist.

To automatically create this file call matchGoldenFile('$filename', write: true).
''';
  }
  if (write) {
    // Don't even bother with the comparison, just write and return
    print('Updating screenshot golden: $file');
    file.writeAsBytesSync(encodePng(screenshot), flush: true);
    if (doUpdateScreenshotGoldens) {
      // Do not fail tests when bulk-updating screenshot goldens.
      return 'OK';
    } else {
      return 'Golden file $filename was updated. You can remove "write: true" '
          'in the call to matchGoldenFile.';
    }
  }

  final Image golden = decodeNamedImage(file.readAsBytesSync(), filename)!;

  // Compare screenshots.
  final ImageDiff diff = ImageDiff(
    golden: golden,
    other: screenshot,
    pixelComparison: pixelComparison,
  );

  if (diff.rate > 0) {
    final String testResultsPath = environment.webUiTestResultsDirectory.path;
    Directory(testResultsPath).createSync(recursive: true);
    final String basename = p.basenameWithoutExtension(file.path);

    final File actualFile =
        File(p.join(testResultsPath, '$basename.actual.png'));
    actualFile.writeAsBytesSync(encodePng(screenshot), flush: true);

    final File diffFile = File(p.join(testResultsPath, '$basename.diff.png'));
    diffFile.writeAsBytesSync(encodePng(diff.diff), flush: true);

    final File expectedFile =
        File(p.join(testResultsPath, '$basename.expected.png'));
    file.copySync(expectedFile.path);

    final File reportFile =
        File(p.join(testResultsPath, '$basename.report.html'));
    reportFile.writeAsStringSync('''
Golden file $filename did not match the image generated by the test.

<table>
  <tr>
    <th>Expected</th>
    <th>Diff</th>
    <th>Actual</th>
  </tr>
  <tr>
    <td>
      <img src="$basename.expected.png">
    </td>
    <td>
      <img src="$basename.diff.png">
    </td>
    <td>
      <img src="$basename.actual.png">
    </td>
  </tr>
</table>
''');

    final StringBuffer message = StringBuffer();
    message.writeln(
        'Golden file $filename did not match the image generated by the test.');
    message.writeln(getPrintableDiffFilesInfo(diff.rate, maxDiffRateFailure));
    message.writeln('You can view the test report in your browser by opening:');

    final String localReportPath = '$testResultsPath/$basename.report.html';
    message.writeln(localReportPath);

    message.writeln(
        'To update the golden file call matchGoldenFile(\'$filename\', write: '
        'true).');
    message.writeln('Golden file: ${expectedFile.path}');
    message.writeln('Actual file: ${actualFile.path}');

    if (diff.rate < maxDiffRateFailure) {
      // Issue a warning but do not fail the test.
      print('WARNING:');
      print(message);
      return 'OK';
    } else {
      // Fail test
      return '$message';
    }
  }
  return 'OK';
}

Future<void> _uploadToSkiaGold(
  SkiaGoldClient skiaClient,
  Image screenshot,
  String filename,
) async {
  // Can't upload to Gold Skia unless running in LUCI.
  assert(_isLuci);

  // Write the screenshot to the file system so it can be consumed by the
  // `goldctl` tool.
  final File goldenFile = File(p.join(environment.webUiSkiaGoldDirectory.path, filename));
  await goldenFile.writeAsBytes(encodePng(screenshot), flush: true);

  if (_isPreSubmit) {
    return _uploadInPreSubmit(skiaClient, filename, goldenFile);
  }
  if (_isPostSubmit) {
    return _uploadInPostSubmit(skiaClient, filename, goldenFile);
  }
}

Future<void> _uploadInPreSubmit(
  SkiaGoldClient skiaClient,
  String filename,
  File goldenFile,
) {
  assert(_isPreSubmit);
  return skiaClient.tryjobAdd(filename, goldenFile);
}

Future<void> _uploadInPostSubmit(
  SkiaGoldClient skiaClient,
  String filename,
  File goldenFile,
) {
  assert(_isPostSubmit);
  return skiaClient.imgtestAdd(filename, goldenFile);
}
