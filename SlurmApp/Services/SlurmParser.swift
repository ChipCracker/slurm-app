import Foundation

enum SlurmParser {
    static let squeueFormat = "%i|%j|%u|%t|%P|%q|%b|%C|%m|%M|%N|%r"

    // Einmal kompiliert statt pro Aufruf: gpuCount läuft pro squeue-/sinfo-Zeile
    // im 10-s-Poll (clusterweit), das Neu-Kompilieren des Patterns war reiner
    // CPU-Overhead im SlurmService-Actor.
    private static let gpuRegex = try! NSRegularExpression(
        pattern: #"gpu(?::[^:,()\s]+)?:(\d+)"#, options: [.caseInsensitive]
    )

    /// Sum of GPU counts in a GRES/TRES string ("gpu:a100:4", "gpu:2",
    /// "gpu:a100:2,gpu:mig:1" → 4/2/3). All `gpu[:type]:N` occurrences are summed
    /// so heterogeneous requests count fully, not just the first.
    /// NOTE: squeue's %b is tres-PER-NODE, so a job submitted with a global
    /// `--gpus=N` and no per-node spec can legitimately report 0 here — that is a
    /// Slurm display limitation, not a parsing miss.
    static func gpuCount(inGres gres: String) -> Int {
        guard gres.range(of: "gpu", options: .caseInsensitive) != nil else { return 0 }
        let ns = gres as NSString
        var total = 0
        for m in gpuRegex.matches(in: gres, range: NSRange(location: 0, length: ns.length)) {
            total += Int(ns.substring(with: m.range(at: 1))) ?? 0
        }
        return total
    }

    static func parseSqueue(_ text: String) -> [Job] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 11 else { return nil }

            let gpus = gpuCount(inGres: parts[6])

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

    /// Parses **per-node** `sinfo -h -N -o "%P|%G"` output and aggregates the
    /// partition-wide GPU total. `%G` is a per-NODE GRES count, so a partition is
    /// the SUM over its nodes — the previous per-line parse mistook the per-node
    /// count (e.g. 8) for the partition total. Each node appears once per
    /// partition membership, which is exactly what we want to sum here.
    /// One aggregated `PartitionGpu` per partition (no duplicate Identifiable ids).
    static func parsePartitionGres(_ text: String) -> [PartitionGpu] {
        var order: [String] = []
        var totals: [String: Int] = [:]
        var types: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            let name = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "*").union(.whitespaces))
            if name.isEmpty || name.lowercased() == "all" { continue }

            if totals[name] == nil { order.append(name); totals[name] = 0 }
            totals[name]! += gpuCount(inGres: parts[1])

            // Type from "gpu:a100:8(S:0-1)" → "a100"; keep the first concrete one.
            if types[name] == nil {
                let cleaned = parts[1].split(separator: "(").first.map(String.init) ?? parts[1]
                let segs = cleaned.split(separator: ":").map(String.init)
                if segs.count >= 3, segs[0].lowercased() == "gpu" { types[name] = segs[1] }
            }
        }
        return order.map { PartitionGpu(partition: $0, gpuType: types[$0] ?? "—", totalGpus: totals[$0] ?? 0) }
    }

    /// Key-Start-Pattern für scontrol-Ausgaben — einmal kompiliert (s. gpuRegex).
    private static let scontrolKeyStartRegex = try! NSRegularExpression(
        pattern: #"(?:^|\s)([A-Za-z][A-Za-z0-9_/:.\-]*)="#
    )

    /// Parses scontrol show job/partition output.
    /// Tokens are space-separated `Key=Value` pairs, possibly multiline.
    /// Values can contain `=` but tokens themselves don't span spaces.
    static func parseScontrolKeyValue(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        // scontrol prints space-separated Key=Value pairs, but some values
        // contain spaces (Command with arguments, Reason, *Features, Comment).
        // Splitting on spaces truncated those at the first space. Instead, per
        // physical line, locate every `Key=` start (a key token preceded by line
        // start or whitespace) and take the value up to the NEXT key start.
        // Values never span a newline. `cpu=4,mem=16G` inside a value is safe:
        // those `=` aren't preceded by whitespace, so they aren't key starts.
        let keyStart = scontrolKeyStartRegex
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            let ns = line as NSString
            let matches = keyStart.matches(in: line, range: NSRange(location: 0, length: ns.length))
            for (idx, m) in matches.enumerated() {
                let key = ns.substring(with: m.range(at: 1))
                let valueStart = m.range.location + m.range.length          // char after '='
                let valueEnd = idx + 1 < matches.count ? matches[idx + 1].range.location : ns.length
                let value = ns.substring(with: NSRange(location: valueStart, length: max(0, valueEnd - valueStart)))
                if out[key] == nil { out[key] = value.trimmingCharacters(in: .whitespaces) }
            }
        }
        return out
    }

    /// Parses `nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits`.
    /// Matches slurm-tui's column order.
    static func parseNvidiaSmi(_ text: String) -> [GpuStat] {
        // nvidia-smi emits "[N/A]" (or "N/A") for any unsupported field — common
        // for utilization/power on MIG slices or older cards. Only the GPU index
        // is truly required; every other field degrades to 0 instead of dropping
        // the whole GPU row. `slot` makes multi-node rows (repeated indices)
        // uniquely Identifiable.
        func num(_ s: String) -> Double? {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t == "[N/A]" || t.caseInsensitiveCompare("N/A") == .orderedSame { return 0 }
            return Double(t)
        }
        var stats: [GpuStat] = []
        var slot = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 8, let idx = Int(cols[0]) else { continue }
            let util: Int   = Int(num(cols[2]) ?? 0)
            let used: Int   = Int(num(cols[3]) ?? 0)
            let total: Int  = Int(num(cols[4]) ?? 0)
            let temp: Int   = Int(num(cols[5]) ?? 0)
            let power: Double = num(cols[6]) ?? 0
            let limit: Double = num(cols[7]) ?? 0
            stats.append(GpuStat(
                slot: slot,
                index: idx,
                name: cols[1],
                utilizationPercent: util,
                memoryUsedMiB: used,
                memoryTotalMiB: total,
                powerDrawW: power,
                powerLimitW: limit,
                temperatureC: temp
            ))
            slot += 1
        }
        return stats
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

        // Include COMPLETING/SUSPENDED jobs, not just running ones — they still
        // hold their GPUs, so excluding them under-counts usage.
        for job in jobs where job.holdsGpuAllocation && job.gpus > 0 {
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
            // Clamp the four buckets to the partition total (squeue/sinfo can
            // briefly disagree) using largest-remainder rounding so the rendered
            // segments sum to EXACTLY min(raw, total) — independent per-bucket
            // rounding could otherwise push the sum past 100%.
            let buckets = clampBuckets(
                [ownNP[p.partition] ?? 0, ownP[p.partition] ?? 0,
                 otherNP[p.partition] ?? 0, otherP[p.partition] ?? 0],
                cap: p.totalGpus)
            return PartitionUsage(
                partition: p.partition,
                gpuType: p.gpuType,
                totalGpus: p.totalGpus,
                ownNonPreemptible:   buckets[0],
                ownPreemptible:      buckets[1],
                otherNonPreemptible: buckets[2],
                otherPreemptible:    buckets[3]
            )
        }
    }

    /// Scale `vals` down to sum to at most `cap`, preserving the total via
    /// largest-remainder rounding (Hamilton's method). Returns `vals` unchanged
    /// when the sum already fits or `cap <= 0`.
    static func clampBuckets(_ vals: [Int], cap: Int) -> [Int] {
        let rawSum = vals.reduce(0, +)
        guard cap > 0, rawSum > cap else { return vals }
        let scale = Double(cap) / Double(rawSum)
        let scaled = vals.map { Double($0) * scale }
        var floored = scaled.map { Int($0) }   // values are non-negative → floor
        var remainder = cap - floored.reduce(0, +)
        let byFraction = scaled.enumerated()
            .sorted { ($0.element - Double(Int($0.element))) > ($1.element - Double(Int($1.element))) }
            .map { $0.offset }
        var k = 0
        while remainder > 0 && k < byFraction.count {
            floored[byFraction[k]] += 1
            remainder -= 1
            k += 1
        }
        return floored
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

    /// Parse `sinfo -h -N -o "%N|%G|%T|%c|%m|%e|%P"` into one row per node,
    /// merging the partition column across the (per-partition) duplicate rows.
    static func parseAllNodes(_ text: String) -> [ClusterNode] {
        var order: [String] = []
        var byName: [String: ClusterNode] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6 else { continue }
            let name = parts[0]
            let partition = parts.count > 6
                ? parts[6].trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                : ""
            if let existing = byName[name] {
                if !partition.isEmpty, !existing.partitions.contains(partition) {
                    byName[name] = ClusterNode(
                        name: existing.name, gres: existing.gres, state: existing.state,
                        cpus: existing.cpus, memoryMB: existing.memoryMB,
                        freeMemoryMB: existing.freeMemoryMB,
                        partitions: existing.partitions + [partition]
                    )
                }
            } else {
                order.append(name)
                byName[name] = ClusterNode(
                    name: name,
                    gres: parts[1],
                    state: parts[2],
                    cpus: parts[3],
                    memoryMB: Int(parts[4]) ?? 0,
                    freeMemoryMB: Int(parts[5]) ?? 0,
                    partitions: partition.isEmpty ? [] : [partition]
                )
            }
        }
        return order.compactMap { byName[$0] }
    }

    /// Normalize array job IDs like '167756_[3]' → '167756' for scontrol queries.
    /// scontrol still accepts a concrete element like '167756_2', so those are
    /// left as-is (only the bracketed pending range is collapsed to the base).
    static func normalizeArrayJobId(_ jobId: String) -> String {
        guard let r = jobId.range(of: #"^(\d+)_\[.*\]$"#, options: .regularExpression) else {
            return jobId
        }
        let match = String(jobId[r])
        return String(match.split(separator: "_").first ?? "")
    }

    /// The base **numeric** job id for `srun --jobid`, which rejects every array-
    /// element notation ("172172_0", "172172_[3]") with "Invalid numeric value".
    /// Strips anything from the first '_'; a plain id is returned unchanged.
    static func baseNumericJobId(_ jobId: String) -> String {
        if let underscore = jobId.firstIndex(of: "_") {
            return String(jobId[..<underscore])
        }
        return jobId
    }
}
