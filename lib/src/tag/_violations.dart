// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/session.dart';

import '../sdk_env.dart' show ToolException;
import '_common.dart';
import '_graphs.dart';
import '_specs.dart';

/// Detects forbidden imports given a runtime.
PathFinder<Uri> runtimeViolationFinder(
    LibraryGraph libraryGraph, Runtime runtime, Explainer<Uri> explainer) {
  return PathFinder<Uri>(libraryGraph, (Uri uri) {
    final uriString = uri.toString();
    if (uriString.startsWith('dart:') &&
        !runtime.enabledLibs.contains(uriString.substring(5))) {
      return explainer;
    }
    return null;
  });
}

class DeclaredFlutterPlatformDetector {
  final PubspecCache _pubspecCache;
  final _declaredPlatformCache = <String, Set<FlutterPlatform>?>{};

  DeclaredFlutterPlatformDetector(this._pubspecCache);

  bool isFlutterPlugin(Uri uri) =>
      uri.scheme != 'package' ||
      _declaredFlutterPlatforms(_pubspecCache.packageName(uri)) != null;

  /// Returns the declared Flutter platforms if [packageName] is a plugin, and
  /// `null` otherwise.
  Set<FlutterPlatform>? _declaredFlutterPlatforms(String packageName) {
    return _declaredPlatformCache.putIfAbsent(packageName, () {
      final result = <FlutterPlatform>{};
      final fields = _pubspecCache.pubspecOfPackage(packageName).toJson();
      if (fields['flutter'] is! Map || fields['flutter']['plugin'] is! Map) {
        // If a package doesn't declare support for any platforms, it is
        // not a plugin, and can work on any platforms compatible with
        // imported constraints.
        return null;
      }
      final pluginMap = fields['flutter']['plugin'] as Map;
      final declaredPlatforms = pluginMap['platforms'];
      if (declaredPlatforms is Map) {
        for (final platform in FlutterPlatform.recognizedPlatforms) {
          if (declaredPlatforms.containsKey(platform.name.toLowerCase())) {
            result.add(platform);
          }
        }
      } else {
        // Legacy style plugin:
        if (pluginMap['pluginClass'] is String ||
            pluginMap['androidPackage'] is String ||
            pluginMap['iosPrefix'] is String) {
          result.add(FlutterPlatform.android);
          result.add(FlutterPlatform.ios);
        }
      }
      return result;
    });
  }
}

class PlatformViolationFinder {
  final FlutterPlatform platform;
  final PathFinder<String> _packageDeclaredFinder;
  final PathFinder<Uri> _libraryDeclaredFinder;
  final PathFinder<Uri> _runtimeSupport;
  final DeclaredFlutterPlatformDetector platformDetector;

  PlatformViolationFinder(
    this.platform,
    LibraryGraph libraryGraph,
    this.platformDetector,
    PubspecCache pubspecCache,
    this._runtimeSupport,
  )   : _packageDeclaredFinder =
            PathFinder(PackageGraph(pubspecCache), (package) {
          final detectedPlatforms =
              platformDetector._declaredFlutterPlatforms(package);
          if (detectedPlatforms != null &&
              !detectedPlatforms.contains(platform)) {
            return (path) => Explanation(
                  'Package does not support Flutter platform `${platform.name}`.',
                  'Because:\n${PackageGraph.formatPath(path)} that declares support for '
                      'platforms: ${detectedPlatforms.map((e) => '`${e.name}`').join(', ')}.',
                  tag: platform.tag,
                );
          }
          return null;
        }),
        _libraryDeclaredFinder = PathFinder(libraryGraph, (uri) {
          if (uri.scheme == 'package') {
            final detectedPlatforms = platformDetector
                ._declaredFlutterPlatforms(pubspecCache.packageName(uri));
            if (detectedPlatforms != null &&
                !detectedPlatforms.contains(platform)) {
              return (path) => Explanation(
                    'Package does not support Flutter platform `${platform.name}`.',
                    'Because:\n${LibraryGraph.formatPath(path)} that declares support for '
                        'platforms: ${detectedPlatforms.map((e) => '`${e.name}`').join(', ')}.',
                    tag: platform.tag,
                  );
            }
          }
          return null;
        });

  /// Returns the first platform violation using the transitive dependencies of
  /// [topLibraries] or, if no such library is present, using the declared
  /// platforms from the [package]'s `pubspec.yaml`.
  Explanation? firstViolation(String package, List<Uri> topLibraries) {
    if (topLibraries.isEmpty) {
      return _packageDeclaredFinder.findViolation(package);
    } else {
      for (final uri in topLibraries) {
        final e = _findPlatformViolation(uri);
        if (e != null) return e;
      }
    }
    return null;
  }

  Explanation? _findPlatformViolation(Uri root) {
    try {
      final declaredPlatformResult = _libraryDeclaredFinder.findViolation(root);
      return declaredPlatformResult ?? _runtimeSupport.findViolation(root);
    } on ToolException catch (e) {
      return Explanation('Unable to verify', '$e', tag: platform.tag);
    }
  }
}

class SdkViolationFinder {
  final PathFinder<String> _declaredSdkViolationFinder;
  final Sdk sdk;
  final AnalysisSession _session;

  SdkViolationFinder(PackageGraph packageGraph, this.sdk,
      PubspecCache pubspecCache, this._session)
      : _declaredSdkViolationFinder = PathFinder(
          packageGraph,
          (String packageDir) {
            final declaredSdks = {
              ...pubspecCache.pubspecOfPackage(packageDir).dependentSdks,
              'dart'
            };
            final nonAllowedSdks =
                declaredSdks.difference(sdk.allowedSdks.toSet());
            return nonAllowedSdks.isEmpty
                ? null
                : (path) => Explanation(
                      'Package is not compatible with the ${sdk.formattedName} SDK.',
                      'Because:\n${PackageGraph.formatPath(path)} that is a package requiring'
                          ' ${nonAllowedSdks.map((e) => null).join(', ')}.',
                      tag: sdk.tag,
                    );
          },
        );

  Explanation? findSdkViolation(String packageName, List<Uri> topLibraries) {
    final declaredSdkResult =
        _declaredSdkViolationFinder.findViolation(packageName);
    if (declaredSdkResult != null) return declaredSdkResult;

    final explanations = <Explanation>[];
    for (final runtime in sdk.allowedRuntimes) {
      final violationFinder = runtimeViolationFinder(
          LibraryGraph(_session, runtime.declaredVariables),
          runtime,
          (path) => Explanation(
                'Package is not compatible with ${sdk.formattedName} SDK using runtime `${runtime.name}`.',
                'Because:\n${LibraryGraph.formatPath(path)}',
                tag: sdk.tag,
              ));

      // check if all of the top libraries are supported
      var supports = true;
      for (final lib in topLibraries) {
        try {
          final runtimeResult = violationFinder.findViolation(lib);
          if (runtimeResult != null) {
            explanations.add(runtimeResult);
            supports = false;
            break;
          }
        } on ToolException catch (e) {
          return Explanation('Unable to verify `$lib`.', '$e', tag: sdk.tag);
        }
      }
      if (supports) return null;
    }
    return Explanation(
      'Package is not compatible with the ${sdk.formattedName} SDK.',
      'Because it is not compatible with any of the supported runtimes: '
          '${sdk.allowedRuntimes.map((r) => '`${r.name}`').join(', ')}.'
          '${explanations.map((e) => '\n\n${e.finding} ${e.explanation}').join()}',
      tag: sdk.tag,
    );
  }
}
