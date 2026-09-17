/// Compile-time platform factory for the presence layer.
///
/// The conditional export keeps platform-specific code out of every other
/// build: on `dart.library.io` targets (macOS, Windows, Linux, Android) the
/// real dispatcher is compiled in; everywhere else a stub reports
/// `supported=false`. The dispatcher itself keeps `win32` behind a deferred
/// import (see `platform/presence_platform_factory_io.dart`) because that
/// package loads its DLLs at import time.
library;

export 'platform/presence_platform_factory_stub.dart'
    if (dart.library.io) 'platform/presence_platform_factory_io.dart'
    show createPresencePlatform;
