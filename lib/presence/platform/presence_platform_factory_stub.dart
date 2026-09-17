/// Fallback factory for targets without `dart:io` (web, embedded). Never
/// throws; reports `supported=false` with a reason.
library;

import '../presence_platform.dart';

PresencePlatform createPresencePlatform() =>
    unsupportedPresencePlatform('no presence mechanism on this platform');
