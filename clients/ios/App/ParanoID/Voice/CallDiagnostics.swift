import Foundation

/// What a live call's media is doing, for the two-simulator harness and for
/// nothing else.
///
/// `clients/ios/test_voice_sim.py` has to decide whether two applications
/// really carried RTP to each other, and neither the screen nor the server can
/// answer that: the screen shows «Соединение установлено» from the peer
/// connection's own state, and the server never sees the media at all. The one
/// place that knows is `RTCPeerConnection.statistics`
/// (``WebRtcAudioEngine/statistics(_:)``), so a Debug build samples it once a
/// second while a call is up and writes a summary where the harness can read
/// it.
///
/// Three rules hold here, and each of them is one line of code:
///
/// - **Debug only.** The whole file compiles to nothing in a Release build:
///   ``sink(arguments:)`` answers `nil` there without looking at the command
///   line, so a shipped application samples nothing, opens no file and carries
///   no diagnostic surface at all. It is `DebugFixture`'s rule for the same
///   reason.
/// - **Counters only.** The statistics report carries candidate addresses,
///   which is why ``WebRtcAudioEngine/statistics(_:)`` calls itself a debug
///   surface. Nothing of that kind crosses this type: it keeps packet and byte
///   counters, the transport state and the two candidate **types**
///   (`host`/`srflx`/`prflx`/`relay`), and drops every address, port and
///   identifier before anything is written. What it writes can go into a pull
///   request as it stands.
/// - **One file, rewritten.** The summary is the current state of one call,
///   written atomically over itself, so a reader never sees half a document
///   and never has to parse a growing log.
enum CallDiagnostics {
    #if DEBUG
    /// Where the summary is written, as an absolute path on the host running
    /// the simulator.
    static let pathArgument = "-paranoid-call-diagnostics"

    /// The sink this launch asks for, or `nil` when it asks for none.
    static func sink(arguments: [String] = ProcessInfo.processInfo.arguments) -> Sink? {
        guard let index = arguments.firstIndex(of: pathArgument) else { return nil }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex, !arguments[next].hasPrefix("-") else { return nil }
        return Sink(url: URL(fileURLWithPath: arguments[next]))
    }

    /// The open file, and the reduction that decides what reaches it.
    ///
    /// It owns a queue of its own because the samples arrive on the media
    /// engine's queue and the call state on the state owner's, and the file is
    /// written from neither.
    final class Sink: @unchecked Sendable {
        private let url: URL
        private let queue = DispatchQueue(label: "global.paranoid.call-diagnostics")
        private var samples = 0
        private var state = ""
        /// The highest counters seen. They are monotonic within one peer
        /// connection, but a call that ends takes its engine with it, so the
        /// peak is kept rather than the last reading.
        private var peak: [String: Int] = [:]
        private var kinds: [String: String] = [:]

        init(url: URL) {
            self.url = url
        }

        /// One sample: the call state the controller is publishing, and the
        /// statistics report as ``WebRtcAudioEngine/statistics(_:)`` wrote it.
        func record(state: String, statistics json: String) {
            queue.async { [self] in
                self.state = state
                reduce(json)
                samples += 1
                write()
            }
        }

        /// A call state with no media behind it — everything before the engine
        /// exists, and everything after it is gone.
        ///
        /// It is also where the summary is emptied, and that is the whole
        /// reason the two cases are separate: the counters of one peer
        /// connection say nothing about the next one's, and a run that places
        /// two calls would otherwise read the first call's peak back as the
        /// second call's traffic. Between any two calls there is at least one
        /// tick with no engine, so the reset always happens.
        func record(state: String) {
            queue.async { [self] in
                self.state = state
                samples = 0
                peak.removeAll()
                kinds.removeAll()
                write()
            }
        }

        // MARK: - The reduction

        private func reduce(_ json: String) {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = object["stats"] as? [[String: Any]] else { return }
            var candidates: [String: String] = [:]
            var locals = 0
            var remotes = 0
            var pairs: [String: Int] = [:]
            for entry in entries {
                guard let identifier = entry["id"] as? String,
                      let type = entry["type"] as? String else { continue }
                if type == "local-candidate" || type == "remote-candidate" {
                    candidates[identifier] = (entry["candidateType"] as? String) ?? ""
                    if type == "local-candidate" { locals += 1 } else { remotes += 1 }
                }
                if type == "candidate-pair" {
                    let state = (entry["state"] as? String) ?? "unknown"
                    pairs[state, default: 0] += 1
                }
                // How far the transport itself got. It is the one line that
                // separates "the peer never answered" from "the two of them
                // could not reach each other".
                if type == "transport" {
                    if let ice = entry["iceState"] as? String { kinds["ice_state"] = ice }
                    if let dtls = entry["dtlsState"] as? String { kinds["dtls_state"] = dtls }
                    if let role = entry["iceRole"] as? String { kinds["ice_role"] = role }
                }
            }
            raise("local_candidates", locals)
            raise("remote_candidates", remotes)
            if !pairs.isEmpty {
                kinds["candidate_pairs"] = pairs.keys.sorted()
                    .map { "\($0):\(pairs[$0] ?? 0)" }.joined(separator: ",")
            }
            for entry in entries {
                guard let type = entry["type"] as? String else { continue }
                let kind = (entry["kind"] as? String) ?? (entry["mediaType"] as? String) ?? ""
                switch type {
                case "inbound-rtp" where kind == "audio":
                    raise("audio_packets_received", entry["packetsReceived"])
                    raise("audio_bytes_received", entry["bytesReceived"])
                case "outbound-rtp" where kind == "audio":
                    raise("audio_packets_sent", entry["packetsSent"])
                    raise("audio_bytes_sent", entry["bytesSent"])
                case "candidate-pair":
                    // Only the pair that carries the call is interesting; a
                    // pair that never succeeded says nothing about the media.
                    guard (entry["state"] as? String) == "succeeded" else { continue }
                    raise("pair_packets_received", entry["packetsReceived"])
                    raise("pair_packets_sent", entry["packetsSent"])
                    kinds["pair_state"] = "succeeded"
                    if let local = entry["localCandidateId"] as? String,
                       let found = candidates[local], !found.isEmpty {
                        kinds["local_candidate_type"] = found
                    }
                    if let remote = entry["remoteCandidateId"] as? String,
                       let found = candidates[remote], !found.isEmpty {
                        kinds["remote_candidate_type"] = found
                    }
                default:
                    continue
                }
            }
        }

        /// A counter reaches the summary only as the largest value seen, and
        /// only as an integer: a report member of any other shape is dropped
        /// rather than guessed at.
        private func raise(_ name: String, _ value: Any?) {
            let number: Int
            switch value {
            case let found as Int: number = found
            case let found as Double where found.isFinite: number = Int(found)
            case let found as NSNumber: number = found.intValue
            default: return
            }
            peak[name] = max(peak[name] ?? 0, number)
        }

        // MARK: - The file

        private func write() {
            var payload: [String: Any] = ["state": state, "samples": samples]
            for (name, value) in peak { payload[name] = value }
            for (name, value) in kinds { payload[name] = value }
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload,
                                                         options: [.sortedKeys]) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
    #else
    /// A Release build samples nothing and writes nothing.
    static func sink(arguments: [String] = []) -> Sink? { nil }

    /// The type exists in both configurations so that nothing above this file
    /// needs a conditional; in a Release build nothing ever creates one.
    final class Sink: @unchecked Sendable {
        func record(state: String, statistics json: String) {}
        func record(state: String) {}
    }
    #endif
}
