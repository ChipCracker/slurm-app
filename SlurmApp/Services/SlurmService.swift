import Foundation

/// High-level Slurm operations layered on top of SSHClient.
/// Read methods use the read-only guard; mutating methods are explicitly named
/// `submit…`, `cancel…`, `update…` and route through `executeWrite`.
actor SlurmService {
    private let client: SSHClient

    init(client: SSHClient) {
        self.client = client
    }

    // MARK: – Read operations

    func ping() async throws -> String {
        try await client.ping()
    }

    func fetchJobs(allUsers: Bool, currentUser: String) async throws -> [Job] {
        let userFilter = allUsers ? "" : " -u \(shellEscape(currentUser))"
        let cmd = "squeue -h -o \"\(SlurmParser.squeueFormat)\"\(userFilter)"
        let out = try await client.execute(cmd)
        return SlurmParser.parseSqueue(out)
    }

    func fetchPartitions() async throws -> [Partition] {
        let out = try await client.execute("sinfo -h -o \"%P|%a|%D|%A|%C\"")
        return SlurmParser.parseSinfo(out)
    }

    func fetchPartitionGpus() async throws -> [PartitionGpu] {
        let out = try await client.execute("sinfo -h -o \"%P|%G\" | sort -u")
        return SlurmParser.parsePartitionGres(out)
    }

    func fetchJobDetails(_ jobId: String) async throws -> JobDetails {
        let normalized = SlurmParser.normalizeArrayJobId(jobId)
        let out = try await client.execute("scontrol show job \(shellEscape(normalized))")
        return JobDetails(raw: SlurmParser.parseScontrolKeyValue(out))
    }

    func fetchBatchScript(_ jobId: String) async throws -> String {
        let normalized = SlurmParser.normalizeArrayJobId(jobId)
        return try await client.execute("scontrol write batch_script \(shellEscape(normalized)) -")
    }

    func fetchPartitionDetails(_ partition: String) async throws -> [String: String] {
        let out = try await client.execute("scontrol show partition \(shellEscape(partition))")
        return SlurmParser.parseScontrolKeyValue(out)
    }

    /// Disk quotas via `quota -s`. Best-effort: some sites disable the
    /// `quota` binary, in which case we return an empty list silently.
    /// NOTE: cannot redirect stderr (`2>/dev/null`) — that would trip the
    /// ReadOnlyGuard's redirection check. Shout's `capture` swallows stderr
    /// natively, and `quota` returns rc != 0 (still with a valid stdout
    /// table) when any FS is over its soft limit, which `rawExecute`
    /// surfaces gracefully.
    func fetchDiskQuotas() async throws -> [DiskQuota] {
        do {
            let out = try await client.execute("quota -s")
            return SlurmParser.parseQuota(out)
        } catch SSHError.commandFailed(_, let code) where code != 0 {
            // `quota` is chatty about over-soft-limit — but the data we got
            // from stdout (if any) is still valid. Caller has no way to
            // recover here, so swallow and return nothing.
            return []
        }
    }

    /// Available QoS names (read-only, from `sacctmgr show qos`).
    func fetchAvailableQos() async throws -> [String] {
        let out = try await client.execute("sacctmgr show qos format=Name -n -P")
        return out.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Available partition names (read-only, from `sinfo`).
    func fetchAvailablePartitions() async throws -> [String] {
        let out = try await client.execute("sinfo -h -o \"%P\"")
        return out.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*")) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { acc, p in if !acc.contains(p) { acc.append(p) } }
    }

    /// Per-node listing of a partition, mirroring slurm-tui's `get_partition_details`.
    /// Output of `sinfo -p P -N -o "%N|%G|%T|%c|%m|%e"`.
    func fetchPartitionNodes(_ partition: String) async throws -> [PartitionNode] {
        let out = try await client.execute(
            "sinfo -h -p \(shellEscape(partition)) -N -o \"%N|%G|%T|%c|%m|%e\""
        )
        return SlurmParser.parsePartitionNodes(out)
    }

    /// Tail the last N lines of a log file. Read-only.
    func tailLog(path: String, lines: Int = 200) async throws -> String {
        let n = max(1, min(lines, 2000))
        return try await client.execute("tail -n \(n) \(shellEscape(path))")
    }

    /// Per-GPU stats for a running job — runs `nvidia-smi` on the job's
    /// compute node via `srun --overlap --jobid=<id>`. `srun --overlap` joins
    /// an existing allocation without claiming new resources, so it does NOT
    /// modify cluster state (matches slurm-tui's `get_job_gpu_stats`).
    func liveGpuStats(jobId: String) async throws -> [GpuStat] {
        let baseId = SlurmParser.normalizeArrayJobId(jobId)
        let cmd =
            "srun --overlap --jobid=\(shellEscape(baseId)) " +
            "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit " +
            "--format=csv,noheader,nounits"
        let out = try await client.executeWrite(cmd) // srun isn't on the read-only allow-list
        return SlurmParser.parseNvidiaSmi(out)
    }

    /// MaxRSS of a running job via sstat. Returns memory in MB, or nil.
    func fetchJobMemoryMB(_ jobId: String) async throws -> Double? {
        for suffix in [".batch", ""] {
            let cmd = "sstat -j \(shellEscape(jobId + suffix)) --format=MaxRSS -n -P"
            if let out = try? await client.execute(cmd) {
                var maxMB: Double = 0
                for line in out.split(separator: "\n") {
                    let mb = parseSlurmMem(String(line).trimmingCharacters(in: .whitespaces))
                    if mb > maxMB { maxMB = mb }
                }
                if maxMB > 0 { return maxMB }
            }
        }
        return nil
    }

    private func parseSlurmMem(_ value: String) -> Double {
        guard let last = value.last else { return 0 }
        let num = String(value.dropLast())
        switch last {
        case "K", "k": return Double(num).map { $0 / 1024 } ?? 0
        case "M", "m": return Double(num) ?? 0
        case "G", "g": return (Double(num) ?? 0) * 1024
        case "T", "t": return (Double(num) ?? 0) * 1024 * 1024
        default:       return Double(value) ?? 0
        }
    }

    /// GPU hours via sreport for a given period. `topN == 0` returns every
    /// user with > 0 h. Default period is the current year.
    /// Matches `slurm-tui/utils/gpu.py:get_gpu_hours` column layout.
    func fetchGpuHours(
        start: Date? = nil,
        end: Date? = nil,
        topN: Int = 10
    ) async throws -> [GpuHoursEntry] {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"

        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: now)
        let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? now
        let yearEnd   = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? now

        let startStr = df.string(from: start ?? yearStart)
        let endStr   = df.string(from: end ?? yearEnd)

        let cmd =
            "sreport -n -P -t Hours -T gres/gpu cluster AccountUtilizationByUser " +
            "start=\(startStr) end=\(endStr)"
        let out = try await client.execute(cmd)
        var entries: [GpuHoursEntry] = []
        let skipUsers: Set<String> = ["root", "thn", "cs", ""]
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6 else { continue }
            let user = parts[2].trimmingCharacters(in: .whitespaces)
            if skipUsers.contains(user) { continue }
            guard let hours = Double(parts[5]), hours > 0 else { continue }
            entries.append(GpuHoursEntry(user: user, hours: hours))
        }
        entries.sort { $0.hours > $1.hours }
        return topN > 0 ? Array(entries.prefix(topN)) : entries
    }

    // MARK: – Mutating operations (App-Feature, NICHT während dev getestet)

    func submitScript(at remotePath: String) async throws -> String {
        let out = try await client.executeWrite("sbatch \(shellEscape(remotePath))")
        if let r = out.range(of: #"Submitted batch job (\d+)"#, options: .regularExpression) {
            return String(out[r]).components(separatedBy: " ").last ?? out
        }
        return out
    }

    func cancelJob(_ jobId: String) async throws -> String {
        try await client.executeWrite("scancel \(shellEscape(jobId))")
    }

    func updateJobQos(_ jobId: String, qos: String) async throws -> String {
        try await client.executeWrite(
            "scontrol update job=\(shellEscape(jobId)) qos=\(shellEscape(qos))"
        )
    }

    func updateJobPartition(_ jobId: String, partition: String) async throws -> String {
        try await client.executeWrite(
            "scontrol update job=\(shellEscape(jobId)) partition=\(shellEscape(partition))"
        )
    }

    /// Hält einen (pending) Job zurück, sodass er nicht gestartet wird.
    func holdJob(_ jobId: String) async throws -> String {
        try await client.executeWrite("scontrol hold \(shellEscape(jobId))")
    }

    /// Gibt einen zurückgehaltenen Job wieder frei.
    func releaseJob(_ jobId: String) async throws -> String {
        try await client.executeWrite("scontrol release \(shellEscape(jobId))")
    }

    /// Stellt einen Job zurück in die Warteschlange (requeue).
    func requeueJob(_ jobId: String) async throws -> String {
        try await client.executeWrite("scontrol requeue \(shellEscape(jobId))")
    }

    func shutdown() async {
        await client.close()
    }

    // MARK: – Helpers

    private func shellEscape(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "/" || $0 == "." || $0 == "=" }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
