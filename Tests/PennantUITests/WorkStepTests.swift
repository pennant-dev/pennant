import PennantCore
@testable import PennantUI
import XCTest

final class WorkStepTests: XCTestCase {
    func testToolsReadAsPlainWords() {
        XCTAssertEqual(WorkStep.phrase(for: "web_open"), "Browsing the web")
        XCTAssertEqual(WorkStep.phrase(for: "browser_read_page"), "Browsing the web")
        XCTAssertEqual(WorkStep.phrase(for: "shell"), "Running a few commands")
        XCTAssertEqual(WorkStep.phrase(for: "app_click"), "Working on your Mac")
        XCTAssertEqual(WorkStep.phrase(for: "code"), "Writing code")
        XCTAssertEqual(WorkStep.phrase(for: "microsoft_365__mail_search"), "Checking mail")
        var naming = ToolNaming()
        naming.mcpServerNames["harbor_crm"] = "Harbor CRM"
        XCTAssertEqual(WorkStep.phrase(for: "harbor_crm__find_contact", naming: naming), "Working in Harbor CRM")
        XCTAssertEqual(WorkStep.phrase(for: "something_new"), "Working on it")
    }

    func testTheStepIsTheRunningToolElseThinking() {
        let started = Date(timeIntervalSinceNow: -30)
        var task = TaskRecord(agentID: AgentID(), conversationID: ConversationID(), title: "Harbor newsletter", objective: "Draft it", state: .waitingForTool)
        task.usage.startedAt = started
        let done = ToolRecord(taskID: task.id, agentID: task.agentID, call: ToolCall(id: ToolCallID("a"), name: "memory_search", arguments: [:]),
                              status: .succeeded, startedAt: started, finishedAt: Date(timeIntervalSinceNow: -20))
        let running = ToolRecord(taskID: task.id, agentID: task.agentID, call: ToolCall(id: ToolCallID("b"), name: "web_open", arguments: [:]),
                                 status: .running, startedAt: Date(timeIntervalSinceNow: -5))
        XCTAssertEqual(WorkStep.current(task, records: [done, running], naming: ToolNaming())?.phrase, "Browsing the web")
        task.state = .running
        let thinking = WorkStep.current(task, records: [done], naming: ToolNaming())
        XCTAssertEqual(thinking?.phrase, "Thinking it through")
        XCTAssertEqual(thinking?.since, done.finishedAt)
        task.state = .waitingForUser
        XCTAssertNil(WorkStep.current(task, records: [done], naming: ToolNaming()))
        XCTAssertEqual(WorkStep.clock(75), "1:15")
        XCTAssertEqual(WorkStep.clock(3725), "1:02:05")
    }
}
