// A tool the updater runs (hdiutil) can never hang it: past its deadline it is stopped, then killed, and a tool that
// still has not exited is reported failed without being waited on (2026-10-28: an attach waited 28 minutes on the
// disk-image service while Time Machine was busy).
import Foundation
import Testing
@testable import VitrineUpdate

@Suite struct ProcessRunnerTests {
    @Test func aToolThatIgnoresTheStopRequestIsKilledAndTheRunEnds() async {
        let started = ContinuousClock.now
        // `trap '' TERM` makes the shell ignore SIGTERM, as a tool blocked elsewhere would; only SIGKILL ends it.
        let run = await ProcessRunner.run(URL(filePath: "/bin/sh"), ["-c", "trap '' TERM; sleep 30"],
                                          timeout: .milliseconds(300), grace: .milliseconds(500))
        let elapsed = ContinuousClock.now - started
        #expect(run.status == -1, "a run that had to be stopped is reported failed")
        #expect(elapsed < .seconds(5), "the run ended at the deadline plus the grace, not when the tool chose to")
    }

    @Test func aToolThatFinishesInTimeReportsItsStatusAndOutput() async {
        let run = await ProcessRunner.run(URL(filePath: "/bin/echo"), ["ready"], timeout: .seconds(10))
        #expect(run.status == 0)
        #expect(String(decoding: run.output, as: UTF8.self) == "ready\n")
    }
}
