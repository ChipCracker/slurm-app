import XCTest
@testable import SlurmApp

final class SlurmParserTests: XCTestCase {

    // MARK: – squeue

    func testParseSqueue_FixtureFromKiz0() throws {
        let text = try fixture("squeue.txt")
        let jobs = SlurmParser.parseSqueue(text)
        XCTAssertFalse(jobs.isEmpty, "Fixture should contain jobs")
        for job in jobs {
            XCTAssertFalse(job.jobId.isEmpty)
            XCTAssertFalse(job.partition.isEmpty)
        }
    }

    func testParseSqueue_ExtractsGpuCount() {
        let line = "12345|test|alice|R|p2|basic|gres:gpu:a100:4|16|64G|01:23:45|ml2|None"
        let jobs = SlurmParser.parseSqueue(line)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].gpus, 4)
        XCTAssertEqual(jobs[0].cpus, 16)
        XCTAssertEqual(jobs[0].partition, "p2")
        XCTAssertEqual(jobs[0].reason, "") // "None" → ""
    }

    func testParseSqueue_PreservesReasonWhenNotNone() {
        let line = "12345|test|alice|PD|p0|basic|gres:gpu:1|8|64G|0:00||QOSMaxGRESPerUser"
        let jobs = SlurmParser.parseSqueue(line)
        XCTAssertEqual(jobs[0].reason, "QOSMaxGRESPerUser")
        XCTAssertEqual(jobs[0].node, "—") // empty NodeList → fallback
    }

    func testParseSqueue_GpuWithoutType() {
        let line = "1|n|u|R|p|q|gpu:2|4|4G|00:01|ml1|"
        let jobs = SlurmParser.parseSqueue(line)
        XCTAssertEqual(jobs[0].gpus, 2)
    }

    // MARK: – sinfo

    func testParseSinfo_FixtureFromKiz0() throws {
        let text = try fixture("sinfo.txt")
        let parts = SlurmParser.parseSinfo(text)
        XCTAssertGreaterThan(parts.count, 1)
        let p0 = parts.first { $0.name == "p0" }
        XCTAssertNotNil(p0)
        XCTAssertGreaterThan(p0?.totalCpus ?? 0, 0)
    }

    func testParseSinfo_StripsDefaultMarker() {
        let parts = SlurmParser.parseSinfo("p0*|up|1|1/0|20/76/0/96")
        XCTAssertEqual(parts.first?.name, "p0")
    }

    // MARK: – Partition gres

    func testParsePartitionGres_WithTypeAndSockets() {
        let parts = SlurmParser.parsePartitionGres("p1|gpu:a100:8(S:0-1)\np2|gpu:a100:8(S:0-1)\nall|gpu:a100:8")
        XCTAssertEqual(parts.count, 2) // 'all' is filtered
        XCTAssertEqual(parts[0].gpuType, "a100")
        XCTAssertEqual(parts[0].totalGpus, 8)
    }

    func testParsePartitionGres_NoGpu() {
        let parts = SlurmParser.parsePartitionGres("pcpu|(null)")
        XCTAssertEqual(parts.first?.totalGpus, 0)
    }

    // MARK: – scontrol

    func testParseScontrol_JobFixture() throws {
        let text = try fixture("scontrol_job.txt")
        let dict = SlurmParser.parseScontrolKeyValue(text)
        XCTAssertNotNil(dict["JobId"])
        XCTAssertNotNil(dict["JobState"])
        XCTAssertNotNil(dict["Partition"])
    }

    func testParseScontrol_PartitionFixture() throws {
        let text = try fixture("scontrol_partition.txt")
        let dict = SlurmParser.parseScontrolKeyValue(text)
        XCTAssertEqual(dict["PartitionName"], "p2")
        XCTAssertNotNil(dict["TotalCPUs"])
    }

    // MARK: – nvidia-smi

    func testParseNvidiaSmi() {
        // Columns: index, name, util.gpu, memory.used, memory.total, temp.gpu, power.draw, power.limit
        let csv = """
        0, NVIDIA A100-SXM4-40GB, 87, 24566, 40960, 71, 250.30, 400.00
        1, NVIDIA A100-SXM4-40GB, 12, 1024, 40960, 35, 60.10, 400.00
        """
        let stats = SlurmParser.parseNvidiaSmi(csv)
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats[0].utilizationPercent, 87)
        XCTAssertEqual(stats[0].name, "NVIDIA A100-SXM4-40GB")
        XCTAssertEqual(stats[0].memoryUsedMiB, 24566)
        XCTAssertEqual(stats[0].temperatureC, 71)
        XCTAssertEqual(stats[0].powerLimitW, 400.0, accuracy: 0.001)
        XCTAssertEqual(stats[1].powerDrawW, 60.10, accuracy: 0.001)
    }

    func testParseNvidiaSmi_HandlesNA() {
        let csv = "0, GPU, 50, 100, 200, 60, [N/A], [N/A]"
        let stats = SlurmParser.parseNvidiaSmi(csv)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].powerDrawW, 0)
        XCTAssertEqual(stats[0].powerLimitW, 0)
    }

    func testParsePartitionNodes() {
        let text = "ml1|gpu:a100:8(S:0-1)|mixed|256|2003000|1200000\nml2|gpu:a100:8(S:0-1)|idle|128|1024000|800000"
        let nodes = SlurmParser.parsePartitionNodes(text)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].name, "ml1")
        XCTAssertEqual(nodes[0].state, "mixed")
        XCTAssertEqual(nodes[0].cpus, "256")
        XCTAssertEqual(nodes[0].memoryMB, 2_003_000)
        XCTAssertEqual(nodes[0].freeMemoryMB, 1_200_000)
        XCTAssertEqual(nodes[1].state, "idle")
    }

    // MARK: – Usage

    func testComputeUsage_PreemptibleAndOwnership() {
        // currentUser = "me". qos "preemptible" is the preempt marker.
        let jobs = [
            Job(jobId: "1", name: "mine-protected", user: "me", state: "R", partition: "p1", qos: "basic",       gpus: 2, cpus: 8, memory: "16G", runtime: "1:00", node: "ml1", reason: ""),
            Job(jobId: "2", name: "mine-preempt",   user: "me", state: "R", partition: "p1", qos: "preemptible", gpus: 1, cpus: 4, memory: "8G",  runtime: "0:30", node: "ml1", reason: ""),
            Job(jobId: "3", name: "other-protected",user: "you",state: "R", partition: "p1", qos: "basic",       gpus: 3, cpus: 4, memory: "8G",  runtime: "0:30", node: "ml1", reason: ""),
            Job(jobId: "4", name: "other-preempt",  user: "you",state: "R", partition: "p1", qos: "preemptible", gpus: 1, cpus: 4, memory: "8G",  runtime: "0:30", node: "ml1", reason: ""),
            Job(jobId: "5", name: "pending",        user: "x",  state: "PD",partition: "p1", qos: "basic",       gpus: 8, cpus: 8, memory: "16G", runtime: "0:00", node: "—",   reason: "Resources"),
        ]
        let parts = [PartitionGpu(partition: "p1", gpuType: "a100", totalGpus: 8)]
        let usage = SlurmParser.computeUsage(jobs: jobs, partitions: parts, currentUser: "me")
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage[0].ownNonPreemptible,   2)
        XCTAssertEqual(usage[0].ownPreemptible,      1)
        XCTAssertEqual(usage[0].otherNonPreemptible, 3)
        XCTAssertEqual(usage[0].otherPreemptible,    1)
        XCTAssertEqual(usage[0].allocatedGpus,       7) // pending excluded
        XCTAssertEqual(usage[0].availableGpus,       1)
        XCTAssertEqual(usage[0].ownAllocated,        3)
        XCTAssertEqual(usage[0].preemptible,         2)
    }

    func testComputeUsage_ClampsToTotal() {
        // 20 GPUs claimed on a 8-GPU partition: buckets should be scaled down
        // proportionally so allocatedGpus never exceeds total.
        let jobs = [
            Job(jobId: "1", name: "x", user: "a", state: "R", partition: "p", qos: "basic", gpus: 20, cpus: 1, memory: "1G", runtime: "1:00", node: "n", reason: ""),
        ]
        let parts = [PartitionGpu(partition: "p", gpuType: "x", totalGpus: 8)]
        let usage = SlurmParser.computeUsage(jobs: jobs, partitions: parts, currentUser: "")
        XCTAssertLessThanOrEqual(usage[0].allocatedGpus, 8)
        XCTAssertGreaterThan(usage[0].allocatedGpus, 0)
        XCTAssertEqual(usage[0].ratio, 1.0, accuracy: 0.001)
    }

    // MARK: – Array IDs

    func testNormalizeArrayJobId() {
        XCTAssertEqual(SlurmParser.normalizeArrayJobId("167756_[3]"), "167756")
        XCTAssertEqual(SlurmParser.normalizeArrayJobId("167756_[0-4]"), "167756")
        XCTAssertEqual(SlurmParser.normalizeArrayJobId("167756_2"), "167756_2")
        XCTAssertEqual(SlurmParser.normalizeArrayJobId("12345"), "12345")
    }

    // MARK: – Helper

    private func fixture(_ name: String) throws -> String {
        let bundle = Bundle(for: type(of: self))
        if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: nil) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        // Fallback: read from source tree (when running via swift test)
        let here = URL(fileURLWithPath: #filePath)
        let url = here.deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
