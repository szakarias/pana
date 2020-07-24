// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:pana/src/create_report.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';

import 'code_problem.dart';
import 'download_utils.dart';
import 'library_scanner.dart';
import 'license.dart';
import 'logging.dart';
import 'maintenance.dart';
import 'messages.dart' as messages;
import 'model.dart';
import 'pkg_resolution.dart';
import 'pubspec.dart';
import 'sdk_env.dart';
import 'tag_detection.dart';
import 'utils.dart';

enum Verbosity {
  compact,
  normal,
  verbose,
}

class InspectOptions {
  final Verbosity verbosity;
  final String pubHostedUrl;
  final String dartdocOutputDir;
  final int dartdocRetry;
  final Duration dartdocTimeout;
  final bool isInternal;
  final int lineLength;
  final String analysisOptionsUri;

  InspectOptions({
    this.verbosity = Verbosity.normal,
    this.pubHostedUrl,
    this.dartdocOutputDir,
    this.dartdocRetry = 0,
    this.dartdocTimeout,
    this.isInternal = false,
    this.lineLength,
    this.analysisOptionsUri,
  });
}

class PackageAnalyzer {
  final ToolEnvironment _toolEnv;
  final UrlChecker _urlChecker;

  PackageAnalyzer(this._toolEnv, {UrlChecker urlChecker})
      : _urlChecker = urlChecker ?? UrlChecker();

  static Future<PackageAnalyzer> create(
      {String sdkDir, String flutterDir, String pubCacheDir}) async {
    return PackageAnalyzer(await ToolEnvironment.create(
        dartSdkDir: sdkDir,
        flutterSdkDir: flutterDir,
        pubCacheDir: pubCacheDir));
  }

  Future<Summary> inspectPackage(
    String package, {
    String version,
    InspectOptions options,
    Logger logger,
  }) async {
    options ??= InspectOptions();
    return withLogger(() async {
      log.info('Downloading package $package ${version ?? 'latest'}');
      return withTempDir((tempDir) async {
        await downloadPackage(package, version,
            destination: tempDir, pubHostedUrl: options.pubHostedUrl);
        return await _inspect(tempDir, options);
      });
    }, logger: logger);
  }

  Future<Summary> inspectDir(String packageDir, {InspectOptions options}) {
    options ??= InspectOptions();
    return _inspect(packageDir, options);
  }

  Future<Summary> _inspect(String pkgDir, InspectOptions options) async {
    final errors = <String>[];

    var dartFiles = await listFiles(
      pkgDir,
      endsWith: '.dart',
      deleteBadExtracted: true,
    )
        .where(
            (file) => path.isWithin('bin', file) || path.isWithin('lib', file))
        .toList();

    log.info('Parsing pubspec.yaml...');
    Pubspec pubspec;
    try {
      pubspec = Pubspec.parseFromDir(pkgDir);
    } catch (e, st) {
      log.info('Unable to read pubspec.yaml', e, st);
      return Summary(
        runtimeInfo: _toolEnv.runtimeInfo,
        packageName: null,
        packageVersion: null,
        pubspec: options.verbosity == Verbosity.compact ? null : pubspec,
        pkgResolution: null,
        dartFiles: null,
        licenses: null,
        tags: null,
        report: null,
        errorMessage: pubspecParseError(e),
      );
    }
    if (pubspec.hasUnknownSdks) {
      errors.add('The following unknown SDKs are in `pubspec.yaml`:\n'
          '  `${pubspec.unknownSdks}`.\n\n'
          '`pana` doesn’t recognize them; please remove the `sdk` entry or '
          '[report the issue](https://github.com/dart-lang/pana/issues).');
    }

    final package = pubspec.name;
    final usesFlutter = pubspec.usesFlutter;

    Set<String> unformattedFiles;
    try {
      unformattedFiles = SplayTreeSet<String>.from(
          await _toolEnv.filesNeedingFormat(pkgDir, usesFlutter,
              lineLength: options.lineLength));

      assert(unformattedFiles.every((f) => dartFiles.contains(f)),
          'dartfmt should only return Dart files');
    } on ToolException catch (e) {
      errors.add(messages.runningDartfmtFailed(usesFlutter, e.message));
    } catch (e, stack) {
      log.severe('`dartfmt` failed.\n$e', e, stack);
      errors.add(messages.runningDartfmtFailed(usesFlutter, e.toString()));
    }

    final upgrade = await _toolEnv.runUpgrade(pkgDir, usesFlutter);

    PkgResolution pkgResolution;
    if (upgrade.exitCode == 0) {
      try {
        pkgResolution = createPkgResolution(pubspec, upgrade.stdout as String,
            path: pkgDir);
      } catch (e, stack) {
        log.severe('Problem with pub upgrade', e, stack);
        //(TODO)kevmoo - should add a helper that handles logging exceptions
        //  and writing to issues in one go.

        // Note: calling `flutter pub pub` ensures we get the raw `pub` output.
        final cmd = usesFlutter ? 'flutter pub upgrade' : 'pub upgrade';
        errors.add('Running `$cmd` failed with the following output:\n\n'
            '```\n$e\n```\n');
      }
    } else {
      String message;
      if (upgrade.exitCode > 0) {
        message = PubEntry.parse(upgrade.stderr as String)
            .where((e) => e.header == 'ERR')
            .join('\n');
      } else {
        message = LineSplitter.split(upgrade.stderr as String).first;
      }

      // 1: Version constraint issue with direct or transitive dependencies.
      //
      // 2: Code in a git repository could change or disappear.
      final isUserProblem = message.contains('version solving failed') || // 1
          pubspec.hasGitDependency || // 2
          message.contains('Git error.'); // 2

      if (!isUserProblem) {
        log.severe('`pub upgrade` failed.\n$message'.trim());
      }

      // Note: calling `flutter pub pub` ensures we get the raw `pub` output.
      final cmd = usesFlutter ? 'flutter pub upgrade' : 'pub upgrade';
      errors.add(message.isEmpty
          ? 'Running `$cmd` failed.'
          : 'Running `$cmd` failed with the following output:\n\n'
              '```\n$message\n```\n');
    }

    Map<String, List<String>> allDirectLibs;
    Map<String, List<String>> allTransitiveLibs;
    Set<String> reachableLibs;

    LibraryScanner libraryScanner;

    List<CodeProblem> analyzerItems;

    if (pkgResolution != null && options.dartdocOutputDir != null) {
      for (var i = 0; i <= options.dartdocRetry; i++) {
        try {
          final r = await _toolEnv.dartdoc(
            pkgDir,
            options.dartdocOutputDir,
            validateLinks: i == 0,
            timeout: options.dartdocTimeout,
          );
          if (!r.wasTimeout) {
            break;
          }
        } catch (e, st) {
          log.severe('Could not run dartdoc.', e, st);
        }
      }
    }

    final tags = <String>[];
    if (pkgResolution != null) {
      try {
        var overrides = [
          LibraryOverride.webSafeIO('package:http/http.dart'),
          LibraryOverride.webSafeIO('package:http/browser_client.dart'),
          LibraryOverride.webSafeIO(
              'package:package_resolver/package_resolver.dart'),
        ];

        libraryScanner = LibraryScanner(_toolEnv.dartSdkDir, package, pkgDir,
            overrides: overrides);
        assert(libraryScanner.packageName == package);
      } catch (e, stack) {
        log.severe('Could not create LibraryScanner', e, stack);
        errors.add('LibraryScanner creation failed: `$e`.');
      }

      if (libraryScanner != null) {
        try {
          log.info('Scanning direct dependencies...');
          allDirectLibs = await libraryScanner.scanDirectLibs();
        } catch (e, st) {
          log.severe('Error scanning direct libraries', e, st);
          errors.add('Error scanning direct libraries: `$e`.');
        }
        try {
          log.info('Scanning transitive dependencies...');
          allTransitiveLibs = await libraryScanner.scanTransitiveLibs();
          reachableLibs = _reachableLibs(allTransitiveLibs);
        } catch (e, st) {
          log.severe('Error scanning transitive libraries', e, st);
          errors.add('Error scanning transitive libraries: `$e`.');
        }
      }

      if (dartFiles.isNotEmpty) {
        try {
          analyzerItems = await _pkgAnalyze(pkgDir, usesFlutter, options);
        } on ToolException catch (e) {
          errors
              .add(messages.runningDartanalyzerFailed(usesFlutter, e.message));
        }
      } else {
        analyzerItems = <CodeProblem>[];
      }

      if (analyzerItems != null && !analyzerItems.any((item) => item.isError)) {
        final tagger = Tagger(pkgDir);
        final explanations = <Explanation>[];
        tagger.sdkTags(tags, explanations);
        tagger.flutterPlatformTags(tags, explanations);
        tagger.runtimeTags(tags, explanations);
        if (_sdkSupportsNullSafety) {
          tagger.nullSafetyTags(tags, explanations);
        }
      }
    }
    String pkgPlatformConflict;

    final files = SplayTreeMap<String, DartFileSummary>();
    for (var dartFile in dartFiles) {
      final size = fileSize(pkgDir, dartFile);
      if (size == null) {
        log.warning('File deleted: $dartFile');
      }
      final isFormatted = unformattedFiles == null
          ? null
          : !unformattedFiles.contains(dartFile);
      final fileAnalyzerItems =
          analyzerItems?.where((item) => item.file == dartFile)?.toList();
      final codeErrors =
          fileAnalyzerItems?.where((cp) => cp.isError)?.toList() ?? const [];
      final platformBlockers =
          codeErrors.where((cp) => cp.isPlatformBlockingError).toList();
      var uri = toPackageUri(package, dartFile);
      final libPlatformBlocked = platformBlockers.isNotEmpty &&
          (reachableLibs == null || reachableLibs.contains(uri));
      var directLibs = allDirectLibs == null ? null : allDirectLibs[uri];
      var transitiveLibs =
          allTransitiveLibs == null ? null : allTransitiveLibs[uri];
      if (libPlatformBlocked) {
        pkgPlatformConflict ??=
            'Error(s) in $dartFile: ${platformBlockers.first.description}';
      }
      files[dartFile] = DartFileSummary(
        uri: uri,
        size: size,
        isFormatted: isFormatted,
        codeProblems: fileAnalyzerItems,
        directLibs: directLibs,
        transitiveLibs:
            options.verbosity == Verbosity.verbose ? transitiveLibs : null,
      );
    }

    if (analyzerItems != null) {
      final reportedFiles = analyzerItems.map((i) => i.file).toSet();
      final knownFiles = files.values.map((f) => f.path).toSet();
      final unattributedFiles = <String>{...reportedFiles}
        ..removeAll(knownFiles);
      if (unattributedFiles.isNotEmpty) {
        log.warning('Unattributed files from dartanalyzer: $unattributedFiles');
      }
    }

    var licenses = await detectLicensesInDir(pkgDir);
    licenses = await updateLicenseUrls(
        _urlChecker, pubspec.repository ?? pubspec.homepage, licenses);

    final errorMessage =
        errors.isEmpty ? null : errors.map((e) => e.trim()).join('\n\n');
    return Summary(
      runtimeInfo: _toolEnv.runtimeInfo,
      packageName: pubspec.name,
      packageVersion: pubspec.version,
      pubspec: options.verbosity == Verbosity.compact ? null : pubspec,
      pkgResolution:
          options.verbosity == Verbosity.compact ? null : pkgResolution,
      dartFiles: options.verbosity == Verbosity.compact ? null : files,
      licenses: licenses,
      tags: tags,
      report: await createReport(options, pkgDir, _toolEnv),
      errorMessage: errorMessage,
    );
  }

  Future<List<CodeProblem>> _pkgAnalyze(
      String pkgPath, bool usesFlutter, InspectOptions inspectOptions) async {
    log.info('Analyzing package...');
    final dirs = await listFocusDirs(pkgPath);
    if (dirs.isEmpty) {
      return null;
    }
    final output = await _toolEnv.runAnalyzer(pkgPath, dirs, usesFlutter,
        inspectOptions: inspectOptions);
    final list = LineSplitter.split(output)
        .map((s) => parseCodeProblem(s, projectDir: pkgPath))
        .where((e) => e != null)
        .toSet()
        .toList();
    list.sort();
    return list;
  }

  Set<String> _reachableLibs(Map<String, List<String>> allTransitiveLibs) {
    final reached = <String>{};
    for (var lib in allTransitiveLibs.keys) {
      if (lib.startsWith('package:')) {
        final path = toRelativePath(lib);
        if (path.startsWith('lib/') && !path.startsWith('lib/src')) {
          reached.add(lib);
          reached.addAll(allTransitiveLibs[lib]);
        }
      }
    }
    return reached.intersection(allTransitiveLibs.keys.toSet());
  }
}

final _sdkVersion = Version.parse(Platform.version.split(' ').first);
final _sdkSupportsNullSafety = _sdkVersion >= Version.parse('2.10.0');
