import XCTest
@testable import SlurmApp

final class ReadOnlyGuardTests: XCTestCase {

    func testAllowsKnownReadOnly() {
        let safe = [
            "squeue -h -o \"%i|%j|%u|%t|%P|%q|%b|%C|%m|%M|%N|%r\"",
            "sinfo -h -o \"%P|%a|%D|%A|%C\"",
            "sinfo -h -o \"%P|%G\" | sort -u",
            "scontrol show job 12345",
            "scontrol show partition p2",
            "scontrol write batch_script 12345 -",
            "nvidia-smi --query-gpu=index,utilization.gpu --format=csv,noheader,nounits",
            "tail -n 200 /var/log/job.out",
            "cat /etc/os-release",
            "echo hello",
        ]
        for cmd in safe {
            XCTAssertTrue(ReadOnlyGuard.isSafe(cmd), "Expected safe: \(cmd)")
        }
    }

    func testRejectsMutatingCommands() {
        let unsafe = [
            "sbatch script.sh",
            "scancel 12345",
            "scontrol update job=12345 qos=interactive",
            "srun --pty bash",
            "rm -rf /tmp/foo",
            "mv a b",
            "echo test > /tmp/x",
            "scontrol reconfigure",
            "scontrol suspend 12345",
            "scontrol requeue 12345",
        ]
        for cmd in unsafe {
            XCTAssertFalse(ReadOnlyGuard.isSafe(cmd), "Expected unsafe: \(cmd)")
        }
    }

    func testPipelineRequiresAllSegmentsSafe() {
        XCTAssertTrue(ReadOnlyGuard.isSafe("sinfo -h -o \"%P|%G\" | sort -u"))
        // Even if one segment uses 'wc', it's whitelisted
        XCTAssertTrue(ReadOnlyGuard.isSafe("squeue -h | wc -l"))
        // Mutating segment in pipeline → reject
        XCTAssertFalse(ReadOnlyGuard.isSafe("squeue -h | sbatch x"))
    }

    func testAssertSafeThrowsForBlocked() {
        XCTAssertThrowsError(try ReadOnlyGuard.assertSafe("scancel 1"))
        XCTAssertNoThrow(try ReadOnlyGuard.assertSafe("squeue"))
    }
}
