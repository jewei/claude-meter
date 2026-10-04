import Testing

/// The parent of every Claude suite. Tests run one at a time because `BlockingIO` admits only
/// 16 operations at once in the whole test process, and parallel provider tests exceed that.
/// The time limit stops a test that waits forever on a latch.
@Suite(.timeLimit(.minutes(1))) struct ClaudeTests {}
