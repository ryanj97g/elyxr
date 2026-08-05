// This app's own build number, stamped in at compile time by elyxr.sh
// (--dart-define=ELYXR_BUILD=<git commit count>). It's the same monotonic
// number lymnal stamps into itself, so the client can compare its build to the
// server's: if the server's is higher, this device is behind and an update is
// offered. Zero when unset (a hand-run `flutter build` with no define), which
// means the "update available" prompt simply never fires.
const int appBuild = int.fromEnvironment('ELYXR_BUILD', defaultValue: 0);
const String appCommit = String.fromEnvironment('ELYXR_COMMIT', defaultValue: 'unknown');
