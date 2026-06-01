import Foundation

struct Job: Identifiable, Hashable {
    let jobId: String
    let name: String
    let user: String
    let state: String
    let partition: String
    let qos: String
    let gpus: Int
    let cpus: Int
    let memory: String
    let runtime: String
    let node: String
    let reason: String

    var id: String { jobId }

    var isRunning: Bool { state.uppercased() == "R" || state.uppercased() == "RUNNING" }
    var isPending: Bool { state.uppercased() == "PD" || state.uppercased() == "PENDING" }
}

struct Partition: Identifiable, Hashable {
    let name: String
    let state: String
    let totalNodes: Int
    let availNodes: Int
    let totalCpus: Int
    let availCpus: Int

    var id: String { name }
}

struct PartitionGpu: Identifiable, Hashable {
    let partition: String
    let gpuType: String
    let totalGpus: Int

    var id: String { partition }
}

struct PartitionUsage: Identifiable, Hashable {
    let partition: String
    let gpuType: String
    let totalGpus: Int
    let ownNonPreemptible: Int
    let ownPreemptible: Int
    let otherNonPreemptible: Int
    let otherPreemptible: Int

    var id: String { partition }

    var allocatedGpus: Int {
        ownNonPreemptible + ownPreemptible + otherNonPreemptible + otherPreemptible
    }
    var ratio: Double {
        totalGpus == 0 ? 0 : Double(allocatedGpus) / Double(totalGpus)
    }
    var availableGpus: Int { max(0, totalGpus - allocatedGpus) }

    var ownAllocated: Int   { ownNonPreemptible + ownPreemptible }
    var otherAllocated: Int { otherNonPreemptible + otherPreemptible }
    var preemptible: Int    { ownPreemptible + otherPreemptible }
    var nonPreemptible: Int { ownNonPreemptible + otherNonPreemptible }
}

struct JobDetails: Hashable {
    let raw: [String: String]

    func value(_ key: String) -> String? { raw[key] }

    var jobId: String       { raw["JobId"] ?? "—" }
    var jobName: String     { raw["JobName"] ?? "—" }
    var userId: String      { raw["UserId"] ?? "—" }
    var state: String       { raw["JobState"] ?? "—" }
    var reason: String      { raw["Reason"] ?? "" }
    var partition: String   { raw["Partition"] ?? "—" }
    var qos: String         { raw["QOS"] ?? "—" }
    var account: String     { raw["Account"] ?? "—" }
    var runtime: String     { raw["RunTime"] ?? "—" }
    var timeLimit: String   { raw["TimeLimit"] ?? "—" }
    var submitTime: String  { raw["SubmitTime"] ?? "—" }
    var startTime: String   { raw["StartTime"] ?? "—" }
    var nodeList: String    { raw["NodeList"] ?? "—" }
    var numCpus: String     { raw["NumCPUs"] ?? "—" }
    var tres: String        { raw["TRES"] ?? "—" }
    var command: String     { raw["Command"] ?? "—" }
    var workDir: String     { raw["WorkDir"] ?? "—" }
    var stdOut: String?     { raw["StdOut"] }
    var stdErr: String?     { raw["StdErr"] }
}

struct PartitionNode: Identifiable, Hashable {
    let name: String
    let gres: String       // e.g. "gpu:a100:8(S:0-1)" or "(null)"
    let state: String      // e.g. "mixed", "idle", "alloc", "down"
    let cpus: String       // e.g. "256"
    let memoryMB: Int      // total memory in MB
    let freeMemoryMB: Int  // currently free memory in MB

    var id: String { name }
}

struct GpuStat: Identifiable, Hashable {
    let index: Int
    let name: String
    let utilizationPercent: Int
    let memoryUsedMiB: Int
    let memoryTotalMiB: Int
    let powerDrawW: Double
    let powerLimitW: Double
    let temperatureC: Int

    var id: Int { index }
    var memoryRatio: Double {
        memoryTotalMiB == 0 ? 0 : Double(memoryUsedMiB) / Double(memoryTotalMiB)
    }
    var powerRatio: Double {
        powerLimitW == 0 ? 0 : powerDrawW / powerLimitW
    }
}

struct DiskQuota: Identifiable, Hashable {
    let filesystem: String
    let used: String       // human readable, e.g. "9847M"
    let quota: String      // soft limit, e.g. "20480M"
    let limit: String      // hard limit, e.g. "22528M"
    let usedBytes: Int64
    let quotaBytes: Int64

    var id: String { filesystem }
    var usageRatio: Double {
        quotaBytes == 0 ? 0 : min(Double(usedBytes) / Double(quotaBytes), 1.0)
    }
}

struct GpuHoursEntry: Identifiable, Hashable {
    let user: String
    let hours: Double
    var id: String { user }
}

struct Bookmark: Identifiable, Codable, Hashable {
    let id: UUID
    var jobId: String?
    var scriptPath: String?
    var label: String
    var createdAt: Date

    init(id: UUID = UUID(), jobId: String? = nil, scriptPath: String? = nil, label: String, createdAt: Date = Date()) {
        self.id = id
        self.jobId = jobId
        self.scriptPath = scriptPath
        self.label = label
        self.createdAt = createdAt
    }
}
