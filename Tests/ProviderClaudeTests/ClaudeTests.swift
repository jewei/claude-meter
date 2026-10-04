import Testing

/// The parent of every Claude suite. The suites run in parallel. The time limit stops a test
/// that waits forever on a latch.
@Suite(.timeLimit(.minutes(1))) struct ClaudeTests {}
