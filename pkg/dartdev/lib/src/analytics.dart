// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:telemetry/telemetry.dart' as telemetry show isRunningOnBot;
import 'package:usage/src/usage_impl.dart';
import 'package:usage/src/usage_impl_io.dart';
import 'package:usage/usage_io.dart';

const String analyticsNoticeOnFirstRunMessage = '''
  ╔════════════════════════════════════════════════════════════════════════════╗
  ║ The Dart tool uses Google Analytics to report feature usage statistics     ║
  ║ and to send basic crash reports. This data is used to help improve the     ║
  ║ Dart platform and tools over time.                                         ║
  ║                                                                            ║
  ║ To disable reporting of analytics, run:                                    ║
  ║                                                                            ║
  ║   dart --disable-analytics                                                 ║
  ║                                                                            ║
  ╚════════════════════════════════════════════════════════════════════════════╝
''';
const String analyticsDisabledNoticeMessage = '''
  ╔════════════════════════════════════════════════════════════════════════════╗
  ║ Analytics reporting disabled. In order to enable it, run:                  ║
  ║                                                                            ║
  ║   dart --enable-analytics                                                  ║
  ║                                                                            ║
  ╚════════════════════════════════════════════════════════════════════════════╝
''';
const String _appName = 'dartdev';
const String _settingsFileName = 'dartdev.json';
const String _trackingId = 'UA-26406144-37';
const String _readmeFileName = 'README.txt';
const String _readmeFileContents = '''
This directory contains user-level settings for the Dart programming language
(https://dart.dev).
''';
String _dartDirectoryName;
const String eventCategory = 'dartdev';
const String exitCodeParam = 'exitCode';

/// Disabled [Analytics], exposed for testing only
@visibleForTesting
Analytics get disabledAnalytics => DisabledAnalytics(_trackingId, _appName);

/// Create and return an [Analytics] instance.
Analytics createAnalyticsInstance(bool disableAnalytics) {
  if (Platform.environment['_DARTDEV_LOG_ANALYTICS'] != null) {
    // Used for testing what analytics messages are sent.
    return _LoggingAnalytics();
  }

  if (disableAnalytics) {
    // Dartdev tests pass a hidden 'no-analytics' flag which is
    // handled here.
    //
    // Also, stdout.hasTerminal is checked; if there is no terminal we infer
    // that a machine is running dartdev so we return that analytics shouldn't
    // be set enabled.
    return DisabledAnalytics(_trackingId, _appName);
  }

  final settingsDir = getDartStorageDirectory();
  if (settingsDir == null) {
    // Some systems don't support user home directories; for those, fail
    // gracefully by returning a disabled analytics object.
    return DisabledAnalytics(_trackingId, _appName);
  }

  if (!settingsDir.existsSync()) {
    try {
      settingsDir.createSync();
    } catch (e) {
      // If we can't create the directory for the analytics settings, fail
      // gracefully by returning a disabled analytics object.
      return DisabledAnalytics(_trackingId, _appName);
    }
  }

  final readmeFile =
      File('${settingsDir.absolute.path}${path.separator}$_readmeFileName');
  if (!readmeFile.existsSync()) {
    readmeFile.createSync();
    readmeFile.writeAsStringSync(_readmeFileContents);
  }

  final settingsFile = File(path.join(settingsDir.path, _settingsFileName));
  return DartdevAnalytics(_trackingId, settingsFile, _appName);
}

/// Return the user's home directory for the current platform.
Directory? get homeDir {
  var dir = Directory(userHomeDir());
  return dir.existsSync() ? dir : null;
}

/// The directory used to store the analytics settings file.
///
/// Typically, the directory is `~/.config/dart/` (and the settings file is
/// `dartdev.json`).
///
/// This can return null under some conditions, including when the user's home
/// directory does not exist.
Directory? getDartStorageDirectory() {
  var dir = homeDir;
  if (dir == null) {
    return null;
  } else {
    if (Platform.environment.containsKey('DART_CONFIG_DIR')) {
      return Platform.environment['DART_CONFIG_DIR'];
    } else {
      if (Platform.isLinux) {
        var xdgConfigHome = Platform.environment['XDG_CONFIG_HOME'];
        if (xdgConfigHome != null) {
          return '$xdgConfigHome/dart';
        } else {
          return '${Platform.environment['HOME']}/.config/dart';
        }
      } else if (Platform.isMacOS) {
        return '${Platform.environment['HOME']}/Library/Application Support/dart';
      } else if (Platform.isWindows) {
        return '${Platform.environment['APPDATA']}/dart';
      }
    }
  }
}

/// The method used by dartdev to determine if this machine is a bot such as a
/// CI machine.
bool isBot() => telemetry.isRunningOnBot();

class DartdevAnalytics extends AnalyticsImpl {
  DartdevAnalytics(String trackingId, File settingsFile, String appName)
      : super(
          trackingId,
          IOPersistentProperties.fromFile(settingsFile),
          IOPostHandler(),
          applicationName: appName,
          applicationVersion: getDartVersion(),
          batchingDelay: Duration(),
        );

  @override
  bool get enabled {
    // Don't enable if the user hasn't been shown the disclosure or if this
    // machine is bot.
    if (!disclosureShownOnTerminal || isBot()) {
      return false;
    }

    // If there's no explicit setting (enabled or disabled) then we don't send.
    return (properties['enabled'] as bool?) ?? false;
  }

  bool get disclosureShownOnTerminal =>
      (properties['disclosureShown'] as bool?) ?? false;

  set disclosureShownOnTerminal(bool value) {
    properties['disclosureShown'] = value;
  }
}

@visibleForTesting
class DisabledAnalytics extends AnalyticsMock {
  @override
  final String trackingId;
  @override
  final String applicationName;

  DisabledAnalytics(this.trackingId, this.applicationName);

  @override
  bool get enabled => false;

  @override
  bool get firstRun => false;
}

class _LoggingAnalytics extends AnalyticsMock {
  _LoggingAnalytics() {
    onSend.listen((event) {
      stderr.writeln('[analytics]${json.encode(event)}');
    });
  }

  @override
  bool get firstRun => false;

  @override
  Future sendScreenView(String viewName, {Map<String, String>? parameters}) {
    parameters ??= <String, String>{};
    parameters['viewName'] = viewName;
    return _log('screenView', parameters);
  }

  @override
  Future sendEvent(String category, String action,
      {String? label, int? value, Map<String, String>? parameters}) {
    parameters ??= <String, String>{};
    return _log(
        'event',
        {'category': category, 'action': action, 'label': label, 'value': value}
          ..addAll(parameters));
  }

  @override
  Future sendSocial(String network, String action, String target) =>
      _log('social', {'network': network, 'action': action, 'target': target});

  @override
  Future sendTiming(String variableName, int time,
      {String? category, String? label}) {
    return _log('timing', {
      'variableName': variableName,
      'time': time,
      'category': category,
      'label': label
    });
  }

  Future<void> _log(String hitType, Map message) async {
    final encoded = json.encode({'hitType': hitType, 'message': message});
    stderr.writeln('[analytics]: $encoded');
  }
}
