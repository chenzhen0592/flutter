// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import '../application_package.dart';
import '../asset.dart';
import '../base/common.dart';
import '../base/context.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/platform.dart';
import '../base/process_manager.dart';
import '../build_info.dart';
import '../bundle.dart';
import '../device.dart';
import '../globals.dart';
import '../project.dart';
import '../version.dart';
import '../web/compile.dart';

ChromeLauncher get chromeLauncher => context.get<ChromeLauncher>();

/// Only launch or display web devices if `FLUTTER_WEB`
/// environment variable is set to true.
bool get flutterWebEnabled {
  _flutterWebEnabled = platform.environment['FLUTTER_WEB']?.toLowerCase() == 'true';
  return _flutterWebEnabled && !FlutterVersion.instance.isStable;
}
bool _flutterWebEnabled;


class WebApplicationPackage extends ApplicationPackage {
  WebApplicationPackage(this._flutterProject) : super(id: _flutterProject.manifest.appName);

  final FlutterProject _flutterProject;

  @override
  String get name => _flutterProject.manifest.appName;

  /// The location of the web source assets.
  Directory get webSourcePath => _flutterProject.directory.childDirectory('web');
}


class WebDevice extends Device {
  WebDevice() : super('web');

  HttpServer _server;
  WebApplicationPackage _package;

  @override
  bool get supportsHotReload => true;

  @override
  bool get supportsHotRestart => true;

  @override
  bool get supportsStartPaused => true;

  @override
  bool get supportsStopApp => true;

  @override
  bool get supportsScreenshot => false;

  @override
  void clearLogs() { }

  @override
  DeviceLogReader getLogReader({ApplicationPackage app}) {
    return NoOpDeviceLogReader(app.name);
  }

  @override
  Future<bool> installApp(ApplicationPackage app) async => true;

  @override
  Future<bool> isAppInstalled(ApplicationPackage app) async => true;

  @override
  Future<bool> isLatestBuildInstalled(ApplicationPackage app) async => true;

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  bool isSupported() => flutterWebEnabled;

  @override
  String get name => 'web';

  @override
  DevicePortForwarder get portForwarder => const NoOpDevicePortForwarder();

  @override
  Future<String> get sdkNameAndVersion async => 'web';

  @override
  Future<LaunchResult> startApp(
    covariant WebApplicationPackage package, {
    String mainPath,
    String route,
    DebuggingOptions debuggingOptions,
    Map<String, Object> platformArgs,
    bool prebuiltApplication = false,
    bool usesTerminalUi = true,
    bool ipv6 = false,
  }) async {
    final Status status = logger.startProgress('Compiling ${package.name} to JavaScript...', timeout: null);
    final int result = await webCompiler.compileDart2js(target: mainPath, minify: false, enabledAssertions: true);
    status.stop();
    if (result != 0) {
      printError('Failed to compile ${package.name} to JavaScript');
      return LaunchResult.failed();
    }
    final AssetBundle assetBundle = AssetBundleFactory.instance.createBundle();
    final int build = await assetBundle.build();
    if (build != 0) {
      throwToolExit('Error: Failed to build asset bundle');
    }
    await writeBundle(fs.directory(getAssetBuildDirectory()), assetBundle.entries);

    _package = package;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_basicAssetServer);
    printStatus('Serving assets from http:localhost:${_server.port}');
    await chromeLauncher.launch('http://localhost:${_server.port}');
    return LaunchResult.succeeded(observatoryUri: null);
  }

  // Note: we don't currently have a way to track which chrome processes
  // belong to the flutter tool, so we'll err on the side of caution by
  // keeping these open.
  @override
  Future<bool> stopApp(ApplicationPackage app) async {
    await _server?.close();
    _server = null;
    return true;
  }

  @override
  Future<TargetPlatform> get targetPlatform async => TargetPlatform.web;

  @override
  Future<bool> uninstallApp(ApplicationPackage app) async => true;

  Future<void> _basicAssetServer(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }
    // Resolve all get requests to the build/web/ or build/flutter_assets directory.
    final Uri uri = request.uri;
    File file;
    String contentType;
    if (uri.path == '/') {
      file = _package.webSourcePath.childFile('index.html');
      contentType = 'text/html';
    } else if (uri.path == '/main.dart.js') {
      file = fs.file(fs.path.join(getWebBuildDirectory(), 'main.dart.js'));
      contentType = 'text/javascript';
    } else {
      file = fs.file(fs.path.join(getAssetBuildDirectory(), uri.path.replaceFirst('/assets/', '')));
    }

    if (!file.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    if (contentType != null) {
      request.response.headers.add(HttpHeaders.contentTypeHeader, contentType);
    }
    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  @override
  bool isSupportedForProject(FlutterProject flutterProject) {
    return flutterProject.web.existsSync();
  }
}

class WebDevices extends PollingDeviceDiscovery {
  WebDevices() : super('web');

  final WebDevice _webDevice = WebDevice();

  @override
  bool get canListAnything => flutterWebEnabled;

  @override
  Future<List<Device>> pollingGetDevices() async {
    return <Device>[
      _webDevice,
    ];
  }

  @override
  bool get supportsPlatform => flutterWebEnabled;
}

const String _klinuxExecutable = 'google-chrome';
const String _kMacOSExecutable = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const String _kWindowsExecutable = r'Google\Chrome\Application\chrome.exe';
final List<String> _kWindowsPrefixes = <String>[
  platform.environment['LOCALAPPDATA'],
  platform.environment['PROGRAMFILES'],
  platform.environment['PROGRAMFILES(X86)'],
];

// Responsible for launching chrome with devtools configured.
class ChromeLauncher {
  const ChromeLauncher();

  /// Launch the chrome browser to a particular `host` page.
  Future<Process> launch(String host) async {
    String executable;
    if (platform.isMacOS) {
      executable = _kMacOSExecutable;
    } else if (platform.isLinux) {
      executable = _klinuxExecutable;
    } else if (platform.isWindows) {
      final String filePath = _kWindowsPrefixes.firstWhere((String prefix) {
        if (prefix == null) {
          return false;
        }
        final String path = fs.path.join(prefix, _kWindowsExecutable);
        return fs.file(path).existsSync();
      }, orElse: () => '.');
      executable = filePath;
    } else {
      throwToolExit('Platform ${platform.operatingSystem} is not supported.');
    }
    if (!fs.file(executable).existsSync()) {
      throwToolExit('Chrome executable not found at $executable');
    }
    return processManager.start(<String>[
      executable,
      host,
    ], mode: ProcessStartMode.detached);
  }
}
