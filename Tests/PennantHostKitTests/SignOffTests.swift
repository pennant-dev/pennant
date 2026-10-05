@testable import PennantHostKit
import PennantCore
import XCTest

/// The owner's three sign-offs, and only those: publishing or email, deleting, spending money.
final class SignOffTests: XCTestCase {
    func testShellCommands() {
        let deletes = ["rm -rf build", "rm notes.txt", "git branch -D old", "git push --force origin main", "git push origin :old", "git reset --hard HEAD~1",
                       "git clean -fd", "git checkout -- Sources", "kubectl delete pod x -n dev", "helm uninstall app", "docker rm web", "docker system prune -f",
                       "tofu destroy", "terraform apply -auto-approve", "tofu state rm module.x", "az group delete -n rg-x", "az keyvault secret delete --name x",
                       "aws s3 rm s3://b/k", "gcloud compute instances delete vm", "gh repo delete o/r --yes", "gh release delete v1", "gh api -X DELETE repos/o/r/git/refs/heads/x",
                       "curl -X DELETE https://api.example.com/items/5", "find . -name '*.log' -delete", "find . -exec rm {} +", "ls | xargs rm",
                       "sqlite3 db 'DELETE FROM users'", "psql -c 'DROP TABLE users'", "mongosh --eval 'db.users.deleteMany({})'", "cd x && rm -r y",
                       "git -C ../repo clean -fd", "git -c core.x=y reset --hard"]
        for c in deletes { XCTAssertEqual(SignOff.reason(command: c), .deletes, c) }
        XCTAssertEqual(SignOff.reason(command: "echo hi | mail -s x a@b.c"), .publishes)
        XCTAssertEqual(SignOff.reason(command: "curl -X POST https://graph.microsoft.com/v1.0/me/sendMail -d @m.json"), .publishes)
        XCTAssertEqual(SignOff.reason(command: "curl -X POST https://api.linkedin.com/rest/posts --json @p.json"), .publishes)
        XCTAssertEqual(SignOff.reason(command: "az reservations reservation-order purchase --reservation-order-id x"), .spends)
        XCTAssertEqual(SignOff.reason(command: "stripe payment_intents create --amount 500"), .spends)

        let free = ["git push origin feature", "gh pr merge 5 --squash", "gh pr create --fill", "git commit -m x", "npm install", "brew install jq",
                    "kubectl apply -f deploy.yaml", "kubectl rollout restart deploy/api", "tofu plan", "tofu import x y", "az webapp restart -n x",
                    "gh workflow run deploy.yml", "docker build -t x .", "curl https://api.linkedin.com/rest/posts", "rm -f /tmp/steward-msg.txt",
                    "rm \"$TMPDIR/x.patch\"", "mkdir -p out && cp a out/", "swift test", "python3 -m pytest", "git worktree add ../x -b x"]
        for c in free { XCTAssertNil(SignOff.reason(command: c), c) }
    }

    func testTools() {
        XCTAssertEqual(SignOff.reason(tool: "microsoft_365__mail_send", arguments: [:]), .publishes)
        XCTAssertEqual(SignOff.reason(tool: "microsoft_365__mail_reply", arguments: [:]), .publishes)
        XCTAssertEqual(SignOff.reason(tool: "linkedin__create_post", arguments: [:]), .publishes)
        XCTAssertEqual(SignOff.reason(tool: "reddit__submit_post", arguments: [:]), .publishes)
        XCTAssertEqual(SignOff.reason(tool: "linkedin__delete_post", arguments: [:]), .deletes)
        XCTAssertEqual(SignOff.reason(tool: "platform__delete_deployment", arguments: [:]), .deletes)
        XCTAssertEqual(SignOff.reason(tool: "shop__create_order", arguments: [:]), .spends)
        XCTAssertEqual(SignOff.reason(tool: "shell", arguments: ["command": "rm -rf x"]), .deletes)
        for name in ["microsoft_365__mail_draft", "microsoft_365__mail_search", "microsoft_365__teams_send_chat", "send_message", "linkedin__list_posts",
                     "platform__deploy_catalog_item", "calendar_create_event", "post_report", "memory_forget", "cancel_schedule", "get_billing_account",
                     "hubspot__get_invoice_list"] {
            XCTAssertNil(SignOff.reason(tool: name, arguments: [:]), name)
        }
        XCTAssertNil(SignOff.reason(tool: "linkedin__create_post", arguments: ["approval_id": "A1"]), "a publishing tool that checks its own approval")
    }

    /// Real commands from threads (2026-10-04, paths changed) that asked only because the temporary folder came from a
    /// variable, mktemp or cd. They don't any more; the ones that delete real files still ask.
    func testTemporaryFoldersReachedThroughVariablesAndCd() {
        let free = [
            "set -e; DEST=/tmp/live-reg-persist; cd \"$DEST\"; unset GIT_INDEX_FILE\ngit checkout origin/main -- tests/README.md\npython3 - <<'PY'\nprint('x')\nPY\ngit diff -- tests/README.md",
            "set -e; WT=/Users/x/work/repo; DEST=/tmp/live-reg-persist; SNAP=$(cat /tmp/snapdir.txt); cd \"$DEST\"; git checkout -- . 2>/dev/null || true; git clean -fdq tests/live .github 2>/dev/null || true; cd \"$WT\"; git add -A tests",
            "GA=\"/Users/x/scripts/ghapp.sh\"; DEST=/tmp/live-reg-persist; rm -rf \"$DEST\"; \"$GA\" git clone --quiet https://github.com/o/r.git \"$DEST\" && cd \"$DEST\" && git log --oneline -1",
            "set -e\nD=$(mktemp -d)\ncd \"$D\"\ngit clone --depth 1 --quiet https://github.com/o/skills.git cs 2>&1 | tail -2\ncd cs\nls\nrm -rf \"$D\"",
            "rm -rf \"${TMPDIR}/build\"", "T=$(mktemp); echo hi > \"$T\"; rm -f \"$T\"", "cd /tmp/work && rm -rf out && git clean -fd",
        ]
        for c in free { XCTAssertNil(SignOff.reason(command: c), c) }
        let asks = [
            "cd ~/Documents/Social/runs/directions\nrm -f B-plate.png poster-B-plate.html\nfor d in B-tree C-diff; do node render.mjs \"$PWD/poster-${d}.html\"; done",
            "cd \"/Users/x/work/tests/live\"\npkill -f auth-mcp.ts 2>/dev/null; sleep 1\nrm -f .auth/mcp.json /tmp/authmcp.log",
            "DEST=/tmp/x; DEST=~/Documents/y; rm -rf \"$DEST\"", "rm -rf \"$UNKNOWN\"", "cd /tmp/../Users/x && rm -rf y", "rm -rf /tmp",
        ]
        for c in asks { XCTAssertEqual(SignOff.reason(command: c), .deletes, c) }
    }

    /// Approving a delete in a thread lets later ones there go ahead: other files in the same folder, anything inside a
    /// folder it removed, the same checkout. Elsewhere, and anything that isn't a path, still asks.
    func testWhatASignedOffDeleteCovers() throws {
        let files = try XCTUnwrap(SignOff.deletions(command: "cd /work/out && rm -f a.png b.html"))
        XCTAssertEqual(files, [.file("/work/out/a.png"), .file("/work/out/b.html")])
        func covered(_ command: String, by approved: [SignOff.Deletion]) -> Bool {
            guard let deletions = SignOff.deletions(command: command), !deletions.isEmpty else { return false }
            return deletions.allSatisfy { $0.isCovered(by: approved) }
        }
        XCTAssertTrue(covered("rm -f /work/out/c.png", by: files))
        XCTAssertTrue(covered("cd /work/out; rm c.png d.png", by: files))
        XCTAssertFalse(covered("rm -f /work/other/c.png", by: files))
        XCTAssertFalse(covered("rm -f /work/out/sub/c.png", by: files))
        XCTAssertFalse(covered("rm -rf /work/out", by: files), "removing the folder is more than its files")

        let tree = try XCTUnwrap(SignOff.deletions(command: "rm -rf /work/build"))
        XCTAssertTrue(covered("rm -f /work/build/x/y.o", by: tree))
        XCTAssertTrue(covered("rm -rf /work/build/cache", by: tree))
        XCTAssertFalse(covered("rm -rf /work/buildx", by: tree))

        let checkout = try XCTUnwrap(SignOff.deletions(command: "cd /repo && git checkout -- ."))
        XCTAssertEqual(checkout, [.discard("/repo")])
        XCTAssertTrue(covered("git -C /repo clean -fd", by: checkout))
        XCTAssertFalse(covered("git -C /other clean -fd", by: checkout))

        for unknown in ["git branch -D x", "kubectl delete pod x", "for f in *; do rm \"$f\"; done", "rm -rf y", "curl -X DELETE https://x.example/1"] {
            XCTAssertNil(SignOff.deletions(command: unknown), unknown)
        }
        XCTAssertEqual(SignOff.deletions(command: "ls && echo hi"), [], "nothing deleted")
    }
}
