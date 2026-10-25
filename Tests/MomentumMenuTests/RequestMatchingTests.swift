import XCTest
@testable import M4Core

/// Which answer each caller gets when requests overlap.
///
/// GAIA replies name the command, not the request. The regression rows are the
/// same-command ones: a second request used to fail the first as "timed out"
/// and then take the first one's reply as its own.
@MainActor
final class RequestMatchingTests: XCTestCase {

    private enum Outcome: Equatable {
        case reply([UInt8])
        case rejected
        case timedOut
    }

    /// One caller. The fake device echoes `tag` back, so a reply shows which
    /// request it answered.
    private struct Call {
        let command: UInt16
        let tag: UInt8
        var timeout: Duration = .milliseconds(200)
    }

    private struct Row {
        let name: String
        let calls: [Call]
        /// Tags the device answers with an error instead of an echo.
        var rejectTags: Set<UInt8> = []
        /// Tags the device never answers.
        var silentTags: Set<UInt8> = []
        /// Tags the device answers only after this long.
        var lateTags: [UInt8: Duration] = [:]
        /// Tags whose reply arrives inside `send`, which then fails anyway.
        var replyDuringFailedSendTags: Set<UInt8> = []
        /// Frames the device sends just before answering the first call.
        var strays: [GaiaFrame] = []
        let expected: [Outcome]
    }

    // Reads that take a one-byte argument, so the tag passes the allow-list.
    // Tags stay under 16, the highest band index it accepts.
    private static func frequency(_ tag: UInt8) -> Call { Call(command: Cmd.getBandFrequency, tag: tag) }
    private static func gain(_ tag: UInt8) -> Call { Call(command: Cmd.getBandGain, tag: tag) }

    private static let rows: [Row] = [
        Row(name: "one request",
            calls: [frequency(1)], expected: [.reply([1])]),
        Row(name: "two different commands",
            calls: [frequency(1), gain(2)], expected: [.reply([1]), .reply([2])]),
        Row(name: "two of the same command",
            calls: [frequency(1), frequency(2)], expected: [.reply([1]), .reply([2])]),
        Row(name: "three of the same command",
            calls: [frequency(1), frequency(2), frequency(3)],
            expected: [.reply([1]), .reply([2]), .reply([3])]),
        Row(name: "same command interleaved with another",
            calls: [frequency(1), gain(2), frequency(3), gain(4)],
            expected: [.reply([1]), .reply([2]), .reply([3]), .reply([4])]),
        Row(name: "same command, first rejected",
            calls: [frequency(1), frequency(2)], rejectTags: [1],
            expected: [.rejected, .reply([2])]),
        Row(name: "same command, first unanswered",
            calls: [frequency(1), frequency(2)], silentTags: [1],
            expected: [.timedOut, .reply([2])]),
        Row(name: "a reply to another command is ignored while waiting",
            calls: [frequency(1)], strays: [Reply.ok(Cmd.getNoiseLevel, [9])],
            expected: [.reply([1])]),
        Row(name: "a rejection of another command is ignored while waiting",
            calls: [frequency(1)], strays: [Reply.rejected(Cmd.getNoiseLevel)],
            expected: [.reply([1])]),
        Row(name: "a notification for the same command is not the reply",
            calls: [frequency(1)], strays: [Reply.notification(Cmd.getBandFrequency, [77])],
            expected: [.reply([1])]),
        // The first request's timer fires at 100 ms, while the second still waits.
        Row(name: "a finished request's timer spares the next one",
            calls: [Call(command: Cmd.getBandFrequency, tag: 1, timeout: .milliseconds(100)),
                    Call(command: Cmd.getBandFrequency, tag: 2, timeout: .seconds(1))],
            lateTags: [2: .milliseconds(250)],
            expected: [.reply([1]), .reply([2])]),
        // Regression: the send-failure path resumed the caller a second time.
        Row(name: "a reply during a send that then fails",
            calls: [frequency(1), frequency(2)], replyDuringFailedSendTags: [1],
            expected: [.reply([1]), .reply([2])]),
        // Deliberately unsupported: with no request id on the wire, a reply that
        // arrives after its own timeout answers the next same-command caller.
        Row(name: "known limit: a late reply answers the next same-command caller",
            calls: [Call(command: Cmd.getBandFrequency, tag: 1, timeout: .milliseconds(100)),
                    Call(command: Cmd.getBandFrequency, tag: 2, timeout: .seconds(1))],
            lateTags: [1: .milliseconds(150), 2: .milliseconds(400)],
            expected: [.timedOut, .reply([1])]),
    ]

    func testEachCallerGetsItsOwnAnswer() async {
        for row in Self.rows {
            let fake = FakeTransport()
            fake.isOpen = true
            func answer(_ frame: GaiaFrame) -> GaiaFrame {
                row.rejectTags.contains(frame.payload.first ?? 0)
                    ? Reply.rejected(frame.command)
                    : Reply.ok(frame.command, frame.payload)
            }
            fake.duringSend = { [weak fake] frame in
                guard row.replyDuringFailedSendTags.contains(frame.payload.first ?? 0) else { return }
                fake?.push(answer(frame))
                throw TransportError.notConnected
            }
            fake.respond = { [weak fake] frame in
                let tag = frame.payload.first ?? 0
                if row.silentTags.contains(tag) { return [] }
                if let delay = row.lateTags[tag] {
                    Task { @MainActor in
                        try? await Task.sleep(for: delay)
                        fake?.push(answer(frame))
                    }
                    return []
                }
                let lead = tag == row.calls.first?.tag ? row.strays : []
                return lead + [answer(frame)]
            }
            let controller = HeadphoneController(transport: fake)

            let tasks = row.calls.map { call in
                Task { () -> Outcome in
                    do {
                        return .reply(try await controller.request(
                            call.command, payload: [call.tag], timeout: call.timeout))
                    } catch let error as TransportError {
                        switch error {
                        case .deviceRejected: return .rejected
                        case .timedOut: return .timedOut
                        default:
                            XCTFail("\(row.name): unexpected \(error)")
                            return .timedOut
                        }
                    } catch {
                        XCTFail("\(row.name): unexpected \(error)")
                        return .timedOut
                    }
                }
            }
            let outcomes = await results(of: tasks, within: .seconds(5))
            XCTAssertEqual(outcomes, row.expected, row.name)
        }
    }

    // MARK: - Waiting

    private struct WaitRow {
        let name: String
        let calls: [Call]
        /// Tags the device never answers; their callers wait out the timeout.
        let silentTags: Set<UInt8>
        /// Tags whose callers should finish without waiting on anyone.
        let prompt: Set<UInt8>
    }

    /// Regression rows: one global queue made an ANC click wait behind every
    /// unanswered refresh read, up to 2 s each.
    private static let waitRows: [WaitRow] = [
        WaitRow(name: "nothing silent",
                calls: [frequency(1), gain(2)], silentTags: [], prompt: [1, 2]),
        WaitRow(name: "another command is not held up by a silent one",
                calls: [Call(command: Cmd.getBandFrequency, tag: 1, timeout: .milliseconds(500)), gain(2)],
                silentTags: [1], prompt: [2]),
        WaitRow(name: "two other commands are not held up",
                calls: [Call(command: Cmd.getBandFrequency, tag: 1, timeout: .milliseconds(500)),
                        gain(2), Call(command: Cmd.getAllGains, tag: 3)],
                silentTags: [1], prompt: [2, 3]),
        // The tag doubles as the ANC value, so it must be 0 or 1 to pass the allow-list.
        WaitRow(name: "an ANC write is not held up by a silent read",
                calls: [Call(command: Cmd.getAllGains, tag: 2, timeout: .milliseconds(500)),
                        Call(command: Cmd.setAncEnabled, tag: 1)],
                silentTags: [2], prompt: [1]),
        WaitRow(name: "the same command still waits its turn",
                calls: [Call(command: Cmd.getBandFrequency, tag: 1, timeout: .milliseconds(300)), frequency(2)],
                silentTags: [1], prompt: []),
    ]

    func testOnlyTheSameCommandWaits() async {
        for row in Self.waitRows {
            let fake = FakeTransport()
            fake.isOpen = true
            fake.respond = { frame in
                row.silentTags.contains(frame.payload.first ?? 0)
                    ? [] : [Reply.ok(frame.command, frame.payload)]
            }
            let controller = HeadphoneController(transport: fake)

            let started = ContinuousClock.now
            let tasks = row.calls.map { call in
                Task { () -> (tag: UInt8, answered: Bool, waited: Duration) in
                    let reply = try? await controller.request(call.command, payload: [call.tag], timeout: call.timeout)
                    return (call.tag, reply != nil, ContinuousClock.now - started)
                }
            }
            // A hang must fail the row, not read as "nobody was prompt".
            guard let finished = await results(of: tasks, within: .seconds(5)) else {
                XCTFail("\(row.name): did not finish")
                continue
            }
            // Answered, and well under the shortest silent timeout. A request
            // refused before sending must not count as prompt.
            let prompt = Set(finished.filter { $0.answered && $0.waited < .milliseconds(150) }.map(\.tag))
            XCTAssertEqual(prompt, row.prompt, row.name)
        }
    }
}
