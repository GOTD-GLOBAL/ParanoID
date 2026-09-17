// realtime-probe: the shipped `RealtimeTransport` against a hostile fake edge.
//
// `clients/ios/test_realtime_transport.py` compiles this file together with
// `ParanoidKit/Sources/ParanoidKit/Net` and `.../Tls` (nothing else: the
// transport needs neither the core xcframework nor any other part of the
// package), starts `clients/ios/test/fake_server.py` on loopback and runs this
// tool against it. Each scenario is one rule of `RealtimeTransport.java` or of
// `docs/protocol/realtime-v1.md:135-151`, exercised through the real
// `URLSession` stack and a real pinned TLS handshake.
//
// The plan arrives as one JSON object on stdin:
//
//     {"url":"https://127.0.0.1:54321","pin":"<64 hex>"}
//
// and one JSON object goes to stdout; the exit status is 0 when every
// scenario did what it was supposed to do, 1 when one did not and 2 when the
// tool could not run at all. The Python side checks the same outcomes again
// from the server's side, where "the request never arrived" and "the socket
// was reset" can actually be seen.
//
// Nothing here prints a body, a certificate or the pin: only names, statuses,
// error codes, byte counts and milliseconds.
import Foundation

// MARK: - Plan

private struct Plan: Decodable {
    let url: String
    let pin: String
}

// MARK: - Naming the outcomes

/// One finished call, flattened into what the report prints.
private struct Outcome: Sendable {
    var kind: String
    var status: Int?
    var code: String?
    var bytes: Int?
    var truncated: Bool?
    var error: String?
    var milliseconds: Int

    var fields: [String: Sendable] {
        var value: [String: Sendable] = ["kind": kind, "ms": milliseconds]
        if let status { value["status"] = status }
        if let code { value["code"] = code }
        if let bytes { value["bytes"] = bytes }
        if let truncated { value["truncated"] = truncated }
        if let error { value["error"] = error }
        return value
    }
}

private func name(_ error: TransportError) -> String {
    switch error {
    case .invalidPath: return "invalid_path"
    case .invalidMethod: return "invalid_method"
    case .bodyOnGet: return "body_on_get"
    case .requestLimit: return "request_limit"
    case .responseLimit: return "response_limit"
    case .closed: return "closed"
    case .invalidRealm: return "invalid_realm"
    case .invalidAuthorization: return "invalid_authorization"
    case .invalidReply: return "invalid_reply"
    case .protocolMismatch: return "protocol_mismatch"
    }
}

private func name(_ code: URLError.Code) -> String {
    switch code {
    case .timedOut: return "timed_out"
    case .networkConnectionLost: return "network_connection_lost"
    case .cannotConnectToHost: return "cannot_connect_to_host"
    case .cannotParseResponse: return "cannot_parse_response"
    case .cancelled: return "cancelled"
    case .secureConnectionFailed: return "secure_connection_failed"
    case .serverCertificateUntrusted: return "server_certificate_untrusted"
    default: return "url_error_\(code.rawValue)"
    }
}

/// Runs one call and turns whatever happened into an `Outcome`.
private func attempt(_ body: () async throws -> RealtimeTransport.Reply) async -> Outcome {
    let started = ContinuousClock.now
    func elapsed() -> Int { Int(((ContinuousClock.now - started) / .milliseconds(1)).rounded()) }
    do {
        let reply = try await body()
        return Outcome(kind: "ok", bytes: reply.bytes, milliseconds: elapsed())
    } catch let rejected as Rejected {
        return Outcome(kind: "rejected", status: rejected.status, code: rejected.code,
                       bytes: rejected.bytes, truncated: rejected.truncated,
                       milliseconds: elapsed())
    } catch let refused as TransportError {
        var size: Int?
        if case .requestLimit(let count) = refused { size = count }
        return Outcome(kind: "refused", bytes: size, error: name(refused), milliseconds: elapsed())
    } catch let failure as URLError {
        return Outcome(kind: "failed", error: name(failure.code), milliseconds: elapsed())
    } catch {
        return Outcome(kind: "failed", error: "other", milliseconds: elapsed())
    }
}

// MARK: - Scenarios

/// The synthetic credential every signed lane sends; the fake server counts
/// the header, never its value (`TlsSmoke.java:29` does the same).
private func credential(_ scenario: String) -> String {
    "ParanoidSessionV2 probe-\(scenario)"
}

private struct Scenario: Sendable {
    let name: String
    let passed: Bool
    let fields: [String: Sendable]
}

private struct Slot: Sendable {
    let name: String
    let started: Int
    let finished: Int
    let kind: String
}

private struct Probe {
    let plan: Plan

    func transport(_ lane: RealtimeTransport.Lane = .pooled) throws -> RealtimeTransport {
        try RealtimeTransport(realm: plan.url, pin: plan.pin, lane: lane)
    }

    // 1. A 302 is an answer, never a hop (`RealtimeTransport.java:35`).
    func redirect() async throws -> Scenario {
        let lane = try transport()
        let outcome = await attempt {
            try await lane.call(method: "GET", path: "/v2/redirect?op=redirect",
                                authorization: credential("redirect"))
        }
        await lane.close()
        return Scenario(name: "redirect",
                        passed: outcome.kind == "rejected" && outcome.status == 302,
                        fields: ["outcome": outcome.fields])
    }

    // 2. A POST above 65536 bytes never reaches a socket
    //    (`RealtimeTransport.java:41`).
    func requestLimit() async throws -> Scenario {
        let lane = try transport()
        let body = "{\"filler\":\"" + String(repeating: "a", count: 70_000) + "\"}"
        let outcome = await attempt {
            try await lane.call(method: "POST", path: "/v2/sink?op=sink", body: body,
                                authorization: credential("sink"))
        }
        // The same lane still works afterwards: the refusal cost no capacity.
        let after = await attempt {
            try await lane.call(method: "POST", path: "/v2/echo?op=sink_after", body: "{}",
                                authorization: credential("sink"))
        }
        await lane.close()
        return Scenario(name: "request_limit",
                        passed: outcome.kind == "refused" && outcome.error == "request_limit"
                            && outcome.bytes == body.utf8.count && after.kind == "ok",
                        fields: ["outcome": outcome.fields,
                                 "next_call": after.fields,
                                 "body_bytes": body.utf8.count])
    }

    // 3. A 200 body above 2 MiB is abandoned (`RealtimeTransport.java:50-51`).
    func responseLimit() async throws -> Scenario {
        let lane = try transport()
        let outcome = await attempt {
            try await lane.call(method: "GET", path: "/v2/huge?op=huge&bytes=3145728",
                                authorization: credential("huge"))
        }
        await lane.close()
        return Scenario(name: "response_limit",
                        passed: outcome.kind == "refused" && outcome.error == "response_limit",
                        fields: ["outcome": outcome.fields,
                                 "limit": RealtimeTransport.responseLimit])
    }

    // 4. Eight seconds everywhere, thirty on `/v2/events?…`
    //    (`RealtimeTransport.java:36`).
    func timeouts() async throws -> Scenario {
        let lane = try transport()
        let short = await attempt {
            try await lane.call(method: "GET", path: "/v2/sleep?op=sleep&seconds=15",
                                authorization: credential("sleep"))
        }
        let poll = await attempt {
            try await lane.call(method: "GET", path: "/v2/events?op=poll&hold=10&after=0",
                                authorization: credential("poll"))
        }
        await lane.close()
        let timedOut = short.kind == "failed" && short.error == "timed_out"
            && short.milliseconds >= 7_000 && short.milliseconds < 12_000
        let waited = poll.kind == "ok" && poll.milliseconds >= 9_000
        return Scenario(name: "read_timeout",
                        passed: timedOut && waited,
                        fields: ["bounded": short.fields,
                                 "long_poll": poll.fields,
                                 "read_timeout_s": Int(RealtimeTransport.readTimeout),
                                 "events_read_timeout_s": Int(RealtimeTransport.eventsReadTimeout)])
    }

    // 5. An error body is read up to 4096 bytes and the status survives
    //    (`RealtimeTransport.java:50-56`).
    func errorBody() async throws -> Scenario {
        let lane = try transport()
        let small = await attempt {
            try await lane.call(method: "GET",
                                path: "/v2/error?op=err_small&status=404&bytes=0&code=turn_disabled",
                                authorization: credential("err_small"))
        }
        let large = await attempt {
            try await lane.call(method: "GET",
                                path: "/v2/error?op=err_large&status=429&bytes=5000&code=waiter_busy",
                                authorization: credential("err_large"))
        }
        await lane.close()
        let parsed = small.kind == "rejected" && small.status == 404 && small.code == "turn_disabled"
        let cut = large.kind == "rejected" && large.status == 429
            && large.bytes == RealtimeTransport.errorLimit && large.truncated == true
            && large.code == ""
        return Scenario(name: "error_body",
                        passed: parsed && cut,
                        fields: ["small": small.fields,
                                 "large": large.fields,
                                 "error_limit": RealtimeTransport.errorLimit])
    }

    // 6. Two requests at a time; the third waits (`RealtimeTransport.java:18`,
    //    `docs/protocol/realtime-v1.md:150`).
    func capacity() async throws -> Scenario {
        let lane = try transport()
        let zero = ContinuousClock.now
        let slots = await withTaskGroup(of: Slot.self, returning: [Slot].self) { group in
            for index in 1...3 {
                group.addTask {
                    let started = Int(((ContinuousClock.now - zero) / .milliseconds(1)).rounded())
                    let outcome = await attempt {
                        try await lane.call(method: "GET",
                                            path: "/v2/slow?op=slow\(index)&seconds=1.2",
                                            authorization: credential("slow\(index)"))
                    }
                    let finished = Int(((ContinuousClock.now - zero) / .milliseconds(1)).rounded())
                    return Slot(name: "slow\(index)", started: started, finished: finished,
                                kind: outcome.kind)
                }
            }
            var collected: [Slot] = []
            for await slot in group { collected.append(slot) }
            return collected.sorted { $0.finished < $1.finished }
        }
        await lane.close()
        let served = slots.filter { $0.kind == "ok" }.count
        // The last call cannot have finished before a slot was freed by the
        // first one: waiting, not failing, is the rule under test.
        let queued = slots.count == 3 && slots[2].finished >= slots[0].finished + 900
        return Scenario(name: "capacity",
                        passed: served == 3 && queued,
                        fields: ["served": served,
                                 "capacity": RealtimeTransport.capacity,
                                 "slots": slots.map { slot -> [String: Sendable] in
                                     ["name": slot.name, "start_ms": slot.started,
                                      "end_ms": slot.finished, "kind": slot.kind]
                                 }])
    }

    // 7. An idle pooled socket is closed by the server after eight seconds and
    //    the next call still succeeds; a one-shot lane leaves nothing open
    //    (`docs/protocol/realtime-v1.md:147-151`).
    func idleClose(idleWait: Double) async throws -> Scenario {
        let lane = try transport()
        var first = Health(realtime: false)
        var firstFailed: String?
        do { first = try await lane.health() } catch { firstFailed = "\(type(of: error))" }
        try? await Task.sleep(nanoseconds: UInt64(idleWait * 1_000_000_000))
        let second = await attempt { try await lane.call(method: "GET", path: "/health") }
        await lane.close()

        let single = try transport(.oneShot)
        let once = await attempt {
            try await single.call(method: "GET", path: "/v2/echo?op=one_shot",
                                  authorization: credential("one_shot"))
        }
        await single.close()
        return Scenario(name: "idle_close",
                        passed: firstFailed == nil && first.realtime && second.kind == "ok"
                            && once.kind == "ok",
                        fields: ["health_realtime": first.realtime,
                                 "idle_wait_s": idleWait,
                                 "after_idle": second.fields,
                                 "one_shot": once.fields])
    }

    // 8. A connection lost mid-request repeats the identical operation once,
    //    and only once.
    func retryOnce() async throws -> Scenario {
        let post = try transport()
        let sent = await attempt {
            try await post.call(method: "POST", path: "/v2/flaky?op=retry_post",
                                body: "{\"id\":\"retry-post\"}",
                                authorization: credential("retry_post"))
        }
        await post.close()

        let poll = try transport()
        let polled = await attempt {
            try await poll.call(method: "GET",
                                path: "/v2/events?op=retry_poll&flaky=1&after=0&before_reset=0.4",
                                authorization: credential("retry_poll"))
        }
        await poll.close()

        let hopeless = try transport()
        let given = await attempt {
            try await hopeless.call(method: "POST", path: "/v2/broken?op=retry_broken",
                                    body: "{\"id\":\"retry-broken\"}",
                                    authorization: credential("retry_broken"))
        }
        await hopeless.close()
        return Scenario(name: "retry_once",
                        passed: sent.kind == "ok" && polled.kind == "ok" && given.kind == "failed",
                        fields: ["post": sent.fields,
                                 "long_poll": polled.fields,
                                 "never_answers": given.fields])
    }
}

// MARK: - Entry point

@main
struct RealtimeProbe {
    static func main() async {
        let input = (try? FileHandle.standardInput.readToEnd()) ?? Data()
        guard let plan = try? JSONDecoder().decode(Plan.self, from: input) else {
            FileHandle.standardError.write(Data("realtime-probe: unusable plan on stdin\n".utf8))
            exit(2)
        }
        let probe = Probe(plan: plan)
        var scenarios: [Scenario] = []
        do {
            scenarios.append(try await probe.redirect())
            scenarios.append(try await probe.requestLimit())
            scenarios.append(try await probe.responseLimit())
            scenarios.append(try await probe.errorBody())
            scenarios.append(try await probe.capacity())
            scenarios.append(try await probe.retryOnce())
            scenarios.append(try await probe.timeouts())
            scenarios.append(try await probe.idleClose(idleWait: 9.5))
        } catch {
            FileHandle.standardError.write(Data("realtime-probe: \(type(of: error))\n".utf8))
            exit(2)
        }
        let report: [String: Any] = [
            "ok": scenarios.allSatisfy(\.passed),
            "scenarios": scenarios.map { scenario -> [String: Any] in
                var fields: [String: Any] = scenario.fields
                fields["name"] = scenario.name
                fields["passed"] = scenario.passed
                return fields
            },
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: report,
                                                        options: [.sortedKeys, .prettyPrinted]) else {
            FileHandle.standardError.write(Data("realtime-probe: report is not encodable\n".utf8))
            exit(2)
        }
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(scenarios.allSatisfy(\.passed) ? 0 : 1)
    }
}
