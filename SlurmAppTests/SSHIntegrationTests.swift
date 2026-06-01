import XCTest
@testable import SlurmApp

/// Integration tests against a real kiz0 SSH endpoint.
/// Gated by env vars so CI / unit tests can opt out.
///
/// To run locally:
///   SLURMIOS_SSH_HOST=kiz0.in.ohmportal.de \
///   SLURMIOS_SSH_USER=<user> \
///   SLURMIOS_SSH_PASSWORD=<pw>            (or)
///   SLURMIOS_SSH_KEY="$(cat ~/.ssh/id_ed25519)" \
///   xcodebuild test ...
///
/// IMPORTANT: this test ONLY runs read-only commands and never mutates server state.
final class SSHIntegrationTests: XCTestCase {

    private var credentials: Credentials? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["SLURMIOS_SSH_HOST"], !host.isEmpty,
              let user = env["SLURMIOS_SSH_USER"], !user.isEmpty
        else { return nil }
        let port = env["SLURMIOS_SSH_PORT"].flatMap(Int.init) ?? 22
        let pw = env["SLURMIOS_SSH_PASSWORD"]
        let key = env["SLURMIOS_SSH_KEY"]
        let pass = env["SLURMIOS_SSH_PASSPHRASE"]
        if let k = key, !k.isEmpty {
            return Credentials(host: host, port: port, username: user,
                               authMethod: .privateKey,
                               password: nil, privateKey: k, passphrase: pass)
        }
        return Credentials(host: host, port: port, username: user,
                           authMethod: .password,
                           password: pw, privateKey: nil, passphrase: nil)
    }

    func testPingKiz0() async throws {
        guard let creds = credentials else {
            throw XCTSkip("Set SLURMIOS_SSH_HOST/USER/PASSWORD or SLURMIOS_SSH_KEY to enable.")
        }
        let client = try await SSHClient.connect(credentials: creds)
        defer { Task { await client.close() } }
        let out = try await client.ping()
        XCTAssertTrue(out.contains("slurm-ios-ok"))
    }

    func testFetchJobsReadOnly() async throws {
        guard let creds = credentials else {
            throw XCTSkip("SSH env vars not set; skipping.")
        }
        let client = try await SSHClient.connect(credentials: creds)
        let svc = SlurmService(client: client)
        defer { Task { await svc.shutdown() } }

        let jobs = try await svc.fetchJobs(allUsers: true, currentUser: creds.username)
        // We don't assert >0 because the cluster could be idle, but we assert
        // the command at least returned without throwing.
        XCTAssertNotNil(jobs)
    }

    func testReadOnlyGuardBlocksMutatingCommand() async throws {
        guard let creds = credentials else {
            throw XCTSkip("SSH env vars not set; skipping.")
        }
        let client = try await SSHClient.connect(credentials: creds)
        defer { Task { await client.close() } }
        do {
            _ = try await client.execute("scancel 0")
            XCTFail("Mutating command should have been rejected by guard")
        } catch {
            // expected
        }
    }
}
