import Testing
@testable import cgate
import Shared

@Suite struct CLITests {
    @Test func run() throws {
        #expect(try CLI.parse(["run", "--max", "20m", "--session", "abc", "--", "make", "-j8"]) ==
            .run(RunOptions(maxRuntime: 1200, session: "abc", ticket: nil, command: ["make", "-j8"])))
        #expect(try CLI.parse(["run", "--ticket=t1", "--", "pytest", "--", "x"]) ==
            .run(RunOptions(maxRuntime: nil, session: nil, ticket: "t1", command: ["pytest", "--", "x"])))
        #expect(try CLI.parse(["run", "--wait", "--max", "5m", "--", "make"]) ==
            .run(RunOptions(maxRuntime: 300, session: nil, ticket: nil, command: ["make"], wait: true)))
    }

    @Test func gitLabel() {
        #expect(GitLabel.format(toplevel: "/x/computemanager-wt/settings", branch: "main--settings")
                == "settings (main--settings)")
        #expect(GitLabel.format(toplevel: "/x/computemanager", branch: "main") == "computemanager")
        #expect(GitLabel.format(toplevel: "/x/repo", branch: "HEAD") == "repo")  // detached
        #expect(GitLabel.compute(cwd: "/") == nil)  // not a repo
    }

    @Test func others() throws {
        #expect(try CLI.parse(["wait", "--ticket", "t2"]) == .wait(ticket: "t2"))
        #expect(try CLI.parse(["hook"]) == .hook)
        #expect(try CLI.parse(["status"]) == .status)
    }

    @Test func usageErrors() {
        for args in [[], ["run", "make"], ["run", "--"], ["run", "--max", "x", "--", "a"],
                     ["run", "--bogus", "1", "--", "a"], ["wait"], ["status", "x"], ["frob"],
                     ["run", "--max"]] {
            #expect(throws: UsageError.self, "\(args)") { try CLI.parse(args) }
        }
    }
}
