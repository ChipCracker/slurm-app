import Foundation

enum SlurmParser {
    static let squeueFormat = "%i|%j|%u|%t|%P|%q|%b|%C|%m|%M|%N|%r"

    static func parseSqueue(_ text: String) -> [Job] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 11 else { return nil }

            let gres = parts[6]
            var gpus = 0
            if gres.lowercased().contains("gpu") {
                if let r = gres.range(of: #"gpu(?::[^:]+)?:(\d+)"#, options: .regularExpression) {
                    let match = String(gres[r])
                    if let digits = match.split(separator: ":").last, let n = Int(digits) {
                        gpus = n
                    }
                }
            }

            var reason = parts.count > 11 ? parts[11].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if reason.lowercased() == "none" { reason = "" }

            let cpus = Int(parts[7]) ?? 0
            let node = parts[10].isEmpty ? "—" : parts[10]

            return Job(
                jobId: parts[0],
                name: parts[1],
                user: parts[2],
                state: parts[3],
                partition: parts[4],
                qos: parts[5],
                gpus: gpus,
                cpus: cpus,
                memory: parts[8],
                runtime: parts[9],
                node: node,
                reason: reason
            )
        }
    }

    static func parseSinfo(_ text: String) -> [Partition] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { return nil }

            let name = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            let cpu = parts[4].split(separator: "/").map(String.init)
            let total = cpu.count >= 4 ? (Int(cpu[3]) ?? 0) : 0
            let avail = cpu.count >= 2 ? (Int(cpu[1]) ?? 0) : 0

            let node = parts[3].split(separator: "/").map(String.init)
            let totalNodes: Int
            let availNodes: Int
            if node.count >= 2 {
                let alloc = Int(node[0]) ?? 0
                let idle  = Int(node[1]) ?? 0
                totalNodes = alloc + idle
                availNodes = idle
            } else {
                totalNodes = 0
                availNodes = 0
            }

            return Partition(
                name: name,
                state: parts[1],
                totalNodes: totalNodes,
                availNodes: availNodes,
                totalCpus: total,
                availCpus: avail
            )
        }
    }

    /// Parses `sinfo -h -o "%P|%G"` output.
    /// Example: `p1|gpu:a100:8(S:0-1)` → ("p1", "a100", 8)
    static func parsePartitionGres(_ text: String) -> [PartitionGpu] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if name.lowercased() == "all" { return nil }

            let gres = parts[1]
            guard gres.lowercased().contains("gpu") else {
                return PartitionGpu(partition: name, gpuType: "—", totalGpus: 0)
            }
            // strip "(S:...)"
            let cleaned = gres.split(separator: "(").first.map(String.init) ?? gres
            // gpu:a100:8 or gpu:8
            let segments = cleaned.split(separator: ":").map(String.init)
            var gpuType = "gpu"
            var total = 0
            if segments.count >= 3 {
                gpuType = segments[1]
                total = Int(segments[2]) ?? 0
            } else if segments.count == 2 {
                total = Int(segments[1]) ?? 0
            }
            return PartitionGpu(partition: name, gpuType: gpuType, totalGpus: total)
        }
    }

    /// Parses scontrol show job/partition output.
    /// Tokens are space-separated `Key=Value` pairs, possibly multiline.
    /// Values can contain `=` but tokens themselves don't span spaces.
    static func parseScontrolKeyValue(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        let tokens = normalized.split(separator: " ", omittingEmptySubsequences: true)
        for token in tokens {
            guard let eqIdx = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<eqIdx])
            let value = String(token[token.index(after: eqIdx)...])
            if out[key] == nil { out[key] = value }
        }
        return out
    }

    /// Parses `nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits`.
    /// Matches slurm-tui's column order.
    static func parseNvidiaSmi(_ text: String) -> [GpuStat] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let cols = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 8,
                  let idx = Int(cols[0]),
                  let util = Double(cols[2]),
                  let used = Double(cols[3]),
                  let total = Double(cols[4]),
                  let temp = Double(cols[5]) else { return nil }
            let power = cols[6] == "[N/A]" ? 0 : (Double(cols[6]) ?? 0)
            let limit = cols[7] == "[N/A]" ? 0 : (Double(cols[7]) ?? 0)
            return GpuStat(
                index: idx,
                name: cols[1],
                utilizationPercent: Int(util),
                memoryUsedMiB: Int(used),
                memoryTotalMiB: Int(total),
                powerDrawW: power,
                powerLimitW: limit,
                temperatureC: Int(temp)
            )
        }
    }

    /// Compute per-partition GPU usage split into four buckets:
    /// own/other × non-preemptible/preemptible. `qos == "preemptible"` is the
    /// preemptible marker (matches slurm-tui's logic).
    static func computeUsage(
        jobs: [Job],
        partitions: [PartitionGpu],
        currentUser: String
    ) -> [PartitionUsage] {
        var ownNP: [String: Int] = [:]
        var ownP: [String: Int] = [:]
        var otherNP: [String: Int] = [:]
        var otherP: [String: Int] = [:]

        for job in jobs where job.isRunning && job.gpus > 0 {
            let isOwn = !currentUser.isEmpty && job.user == currentUser
            let isPreempt = job.qos.lowercased() == "preemptible"
            switch (isOwn, isPreempt) {
            case (true,  true):  ownP[job.partition, default: 0]   += job.gpus
            case (true,  false): ownNP[job.partition, default: 0]  += job.gpus
            case (false, true):  otherP[job.partition, default: 0] += job.gpus
            case (false, false): otherNP[job.partition, default: 0] += job.gpus
            }
        }

        return partitions.map { p in
            // Clamp the sum to total in case squeue/sinfo briefly disagree.
            let raw = (ownNP[p.partition] ?? 0)
                    + (ownP[p.partition] ?? 0)
                    + (otherNP[p.partition] ?? 0)
                    + (otherP[p.partition] ?? 0)
            let scale: Double = (raw > p.totalGpus && p.totalGpus > 0) ? Double(p.totalGpus) / Double(raw) : 1
            func clip(_ v: Int) -> Int { Int((Double(v) * scale).rounded()) }
            return PartitionUsage(
                partition: p.partition,
                gpuType: p.gpuType,
                totalGpus: p.totalGpus,
                ownNonPreemptible:   clip(ownNP[p.partition]   ?? 0),
                ownPreemptible:      clip(ownP[p.partition]    ?? 0),
                otherNonPreemptible: clip(otherNP[p.partition] ?? 0),
                otherPreemptible:    clip(otherP[p.partition]  ?? 0)
            )
        }
    }

    /// Parse `quota -s` output. Handles both single-line and split rows
    /// (filesystem on one line, indented values on the next), mirroring the
    /// slurm-tui parser.
    static func parseQuota(_ text: String) -> [DiskQuota] {
        var quotas: [DiskQuota] = []
        let allLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard allLines.count > 2 else { return [] }
        // First two lines are the table header.
        var pendingFs: String? = nil
        for line in allLines.dropFirst(2) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            var filesystem: String
            var values: [String]
            if parts.count == 1 {
                pendingFs = parts[0]
                continue
            }
            if let fs = pendingFs, line.first == " " {
                filesystem = fs
                pendingFs = nil
                values = parts
            } else if parts.count >= 4 {
                filesystem = parts[0]
                values = Array(parts.dropFirst())
                pendingFs = nil
            } else {
                pendingFs = nil
                continue
            }
            guard values.count >= 3 else { continue }
            let used  = values[0]
            let quota = values[1]
            let limit = values[2]
            quotas.append(DiskQuota(
                filesystem: filesystem,
                used: used.trimmingCharacters(in: CharacterSet(charactersIn: "*")),
                quota: quota,
                limit: limit,
                usedBytes:  parseHumanSize(used),
                quotaBytes: parseHumanSize(quota)
            ))
        }
        return quotas
    }

    /// Parse a quota-style human-readable size to bytes. Plain numbers (no
    /// suffix) are KB, matching `quota -s` behaviour.
    static func parseHumanSize(_ raw: String) -> Int64 {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "*").union(.whitespaces))
        if s.isEmpty || s.lowercased() == "none" || s == "0" { return 0 }
        guard let r = s.range(of: #"^([0-9]+(?:\.[0-9]+)?)\s*([KMGTPkmgtp]?)$"#, options: .regularExpression) else {
            return (Int64(s) ?? 0) * 1024
        }
        let match = String(s[r])
        let numEnd = match.firstIndex(where: { $0.isLetter }) ?? match.endIndex
        let numPart = String(match[..<numEnd]).trimmingCharacters(in: .whitespaces)
        let suffix = String(match[numEnd...]).trimmingCharacters(in: .whitespaces).uppercased()
        let value = Double(numPart) ?? 0
        let multiplier: Double
        switch suffix {
        case "K", "":  multiplier = 1024
        case "M":      multiplier = 1024 * 1024
        case "G":      multiplier = 1024 * 1024 * 1024
        case "T":      multiplier = 1024 * 1024 * 1024 * 1024
        case "P":      multiplier = 1024 * 1024 * 1024 * 1024 * 1024
        default:       multiplier = 1024
        }
        return Int64(value * multiplier)
    }

    /// Parse `sinfo -h -p P -N -o "%N|%G|%T|%c|%m|%e"` output into per-node rows.
    static func parsePartitionNodes(_ text: String) -> [PartitionNode] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6 else { return nil }
            return PartitionNode(
                name: parts[0],
                gres: parts[1],
                state: parts[2],
                cpus: parts[3],
                memoryMB: Int(parts[4]) ?? 0,
                freeMemoryMB: Int(parts[5]) ?? 0
            )
        }
    }

    /// Normalize array job IDs like '167756_[3]' → '167756' for scontrol queries.
    static func normalizeArrayJobId(_ jobId: String) -> String {
        guard let r = jobId.range(of: #"^(\d+)_\[.*\]$"#, options: .regularExpression) else {
            return jobId
        }
        let match = String(jobId[r])
        return String(match.split(separator: "_").first ?? "")
    }
}
