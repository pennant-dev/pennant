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
                       "sqlite3 db 'DELETE FROM users'", "psql -c 'DROP TABLE users'", "mongosh --eval 'db.users.deleteMany({})'", "cd x && rm -r y"]
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
}
