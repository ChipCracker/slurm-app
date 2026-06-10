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

/// Best-effort GPU hardware facts. Slurm's GRES string only carries a type name
/// (e.g. "a100"), not the model or VRAM, so we map them. Two tiers (ported from
/// slurm-tui): a partition-specific table (lets two A100 partitions report 40 vs
/// 80 GB) wins over a generic gres-type fallback.
enum GpuSpecs {
    /// Partition → (full model name, VRAM incl. memory type). Cluster-specific.
    static let partitionInfo: [String: (model: String, vram: String)] = [
        "p0": ("RTX 2080 Ti PCIe", "11 GB GDDR6"),
        "p1": ("A100-SXM4",        "40 GB HBM"),
        "p2": ("A100-SXM4",        "80 GB HBM"),
        "p4": ("H200-SXM5",        "143 GB HBM"),
        "p6": ("L40S PCIe",        "46 GB GDDR6"),
    ]

    /// gres type → VRAM (with memory type). Fallback when the partition is unknown.
    static let typeVRAM: [String: String] = [
        "rtx": "11 GB GDDR6", "rtx2080ti": "11 GB GDDR6",
        "a100": "40 GB HBM", "h200": "143 GB HBM", "h100": "80 GB HBM",
        "l40s": "46 GB GDDR6", "l40": "46 GB GDDR6", "v100": "32 GB HBM",
        "a40": "48 GB GDDR6", "a6000": "48 GB GDDR6", "a5000": "24 GB GDDR6",
        "a30": "24 GB HBM", "rtx3090": "24 GB GDDR6", "rtx4090": "24 GB GDDR6",
        "t4": "16 GB GDDR6", "p100": "16 GB HBM",
    ]

    /// Best (model, vram) for a partition + gres type. Partition table wins;
    /// otherwise the model is the upper-cased gres type and VRAM the type lookup.
    static func info(partition: String?, gresType: String?) -> (model: String, vram: String?) {
        if let p = partition, let hit = partitionInfo[p] { return hit }
        let t = (gresType ?? "").lowercased()
        let model = (gresType?.isEmpty == false) ? gresType!.uppercased() : "GPU"
        return (model, typeVRAM[t])
    }

    static func vramGB(for rawType: String) -> Int? {
        let t = rawType.lowercased()
        if t.contains("h200") { return 143 }
        if t.contains("h100") { return 80 }
        if t.contains("a100") { return 40 }
        if t.contains("l40s") || t.contains("l40") { return 46 }
        if t.contains("a40") || t.contains("a6000") || t.contains("rtx6000") { return 48 }
        if t.contains("a5000") { return 24 }
        if t.contains("v100") { return 32 }
        if t.contains("a30") || t.contains("3090") || t.contains("4090") { return 24 }
        if t.contains("rtx") { return 11 }
        if t.contains("t4") { return 16 }
        if t.contains("p100") { return 16 }
        return nil
    }

    /// Short VRAM label for chips, e.g. "11 GB GDDR6" by type, else "40 GB".
    static func vramLabel(for rawType: String) -> String? {
        if let v = typeVRAM[rawType.lowercased()] { return v }
        return vramGB(for: rawType).map { "\($0) GB" }
    }
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

/// A cluster compute node as shown in the cross-partition node overview. Same
/// per-node fields as `PartitionNode`, plus the set of partitions it belongs to
/// (a node can appear in several). `gpuCount`/`gpuType` are parsed from `gres`.
struct ClusterNode: Identifiable, Hashable {
    let name: String
    let gres: String
    let state: String
    let cpus: String
    let memoryMB: Int
    let freeMemoryMB: Int
    let partitions: [String]

    var id: String { name }

    /// (count, type?) parsed from the GRES string ("gpu:a100:8(S:0-1)" → (8,"a100")).
    var gpu: (count: Int, type: String?) {
        guard !gres.isEmpty, gres != "(null)", gres.lowercased().contains("gpu") else {
            return (0, nil)
        }
        if let r = gres.range(of: #"gpu:([^:(]+):(\d+)"#, options: .regularExpression) {
            let seg = gres[r].split(separator: ":")
            if seg.count == 3, let n = Int(seg[2]) { return (n, String(seg[1])) }
        }
        if let r = gres.range(of: #"gpu:(\d+)"#, options: .regularExpression) {
            let seg = gres[r].split(separator: ":")
            if seg.count == 2, let n = Int(seg[1]) { return (n, nil) }
        }
        return (0, nil)
    }

    var gpuCount: Int { gpu.count }
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

struct DiskQuota: Identifiable, Hashable, Codable {
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

struct GpuHoursEntry: Identifiable, Hashable, Codable {
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
