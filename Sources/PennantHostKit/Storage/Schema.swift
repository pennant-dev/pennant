import Foundation

/// Versioned schema. Each migration runs once inside a transaction; the version is recorded in `schema_version`.
enum Schema {
    static let migrations: [(version: Int, sql: String)] = [
        (1, v1),
        (2, v2),
        (3, v3),
        (4, v4),
        (5, v5),
        (6, v6),
        (7, v7),
    ]

    /// v7: the health review's tools were renamed (crew_health → health_report, crew_failures → recent_failures,
    /// apply_crew_change → apply_proposed_change). Saved grants, job prompts and skills follow, and so do cards still
    /// waiting to be approved.
    static let v7 = """
    UPDATE agents SET json = replace(replace(json, 'crew_health', 'health_report'), 'crew_failures', 'recent_failures') WHERE json LIKE '%crew%';
    UPDATE schedules SET json = replace(replace(json, 'crew_health', 'health_report'), 'crew_failures', 'recent_failures') WHERE json LIKE '%crew%';
    UPDATE skills SET json = replace(replace(json, 'crew_health', 'health_report'), 'crew_failures', 'recent_failures') WHERE json LIKE '%crew%';
    UPDATE messages SET json = replace(json, '"apply_crew_change"', '"apply_proposed_change"') WHERE json LIKE '%apply_crew_change%';
    """

    /// v6: goals and their boards.
    static let v6 = """
    CREATE TABLE IF NOT EXISTS goals (
        id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        owner_agent_id TEXT NOT NULL,
        updated_at REAL NOT NULL,
        json TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS goal_items (
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL,
        state TEXT NOT NULL,
        rank INTEGER NOT NULL,
        updated_at REAL NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS goal_items_goal ON goal_items(goal_id, state, rank);
    """

    /// v5: memory evidence and corrections. Conversations and reports are indexed as ~140-word passages (keyword
    /// and meaning search), removed names are kept so agents don't remember them again, and renamed or merged
    /// facts keep their old names as aliases.
    static let v5 = """
    CREATE TABLE IF NOT EXISTS memory_sources (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        conversation_id TEXT,
        agent_id TEXT,
        title TEXT NOT NULL,
        updated_at REAL NOT NULL,
        signature TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS memory_chunks (
        id TEXT PRIMARY KEY,
        source_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS memory_chunks_source ON memory_chunks(source_id, ordinal);
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(chunk_id UNINDEXED, title, text, tokenize='unicode61 remove_diacritics 2');
    CREATE TABLE IF NOT EXISTS memory_aliases (
        normalized TEXT PRIMARY KEY,
        name TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS memory_ignored (
        normalized TEXT NOT NULL,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        ignored_at REAL NOT NULL,
        PRIMARY KEY (normalized, kind)
    );
    """

    /// v4: the usage ledger, one row per model call.
    static let v4 = """
    CREATE TABLE IF NOT EXISTS usage_events (
        id TEXT PRIMARY KEY,
        at REAL NOT NULL,
        agent_id TEXT NOT NULL,
        task_id TEXT NOT NULL,
        model_label TEXT NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS usage_at ON usage_events(at);
    CREATE INDEX IF NOT EXISTS usage_agent ON usage_events(agent_id, at);
    CREATE INDEX IF NOT EXISTS usage_task ON usage_events(task_id);
    """

    /// v3: scheduled jobs.
    static let v3 = """
    CREATE TABLE IF NOT EXISTS schedules (
        id TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        next_run_at REAL,
        json TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS schedules_due ON schedules(enabled, next_run_at);
    """

    /// v2: checkpoints apply to a whole conversation, so later tasks inherit them.
    static let v2 = """
    ALTER TABLE checkpoints ADD COLUMN conversation_id TEXT;
    CREATE INDEX IF NOT EXISTS checkpoints_conversation ON checkpoints(conversation_id, created_at DESC);
    """

    static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL)")
        let current = try db.scalarInt("SELECT COALESCE(MAX(version), 0) FROM schema_version")
        for migration in migrations where Int64(migration.version) > current {
            try db.transaction {
                try db.execute(migration.sql)
                try db.execute("INSERT INTO schema_version(version, applied_at) VALUES (?, ?)", [.int(migration.version), .date(Date())])
            }
            log.info("Applied schema migration v\(migration.version)", category: "store")
        }
    }

    private static let fts = "tokenize='unicode61 remove_diacritics 2'"

    static let v1 = """
    CREATE TABLE events (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        at REAL NOT NULL,
        kind TEXT NOT NULL,
        payload TEXT NOT NULL
    );
    CREATE INDEX events_kind ON events(kind, seq);

    CREATE TABLE agents (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        status TEXT NOT NULL,
        name TEXT NOT NULL,
        parent_agent_id TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX agents_status ON agents(status, kind);

    CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX conversations_agent ON conversations(agent_id, updated_at DESC);

    CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        task_id TEXT,
        role TEXT NOT NULL,
        created_at REAL NOT NULL,
        text TEXT NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX messages_conversation ON messages(conversation_id, created_at);
    CREATE INDEX messages_task ON messages(task_id);
    CREATE INDEX messages_agent_time ON messages(agent_id, created_at);
    CREATE VIRTUAL TABLE messages_fts USING fts5(message_id UNINDEXED, text, \(fts));

    CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL,
        parent_task_id TEXT,
        state TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX tasks_agent ON tasks(agent_id, updated_at DESC);
    CREATE INDEX tasks_state ON tasks(state);
    CREATE INDEX tasks_parent ON tasks(parent_task_id);

    CREATE TABLE task_transitions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT NOT NULL,
        from_state TEXT NOT NULL,
        to_state TEXT NOT NULL,
        reason TEXT NOT NULL,
        at REAL NOT NULL
    );
    CREATE INDEX task_transitions_task ON task_transitions(task_id, id);

    CREATE TABLE tool_records (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        status TEXT NOT NULL,
        started_at REAL NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX tool_records_task ON tool_records(task_id, started_at);
    CREATE INDEX tool_records_status ON tool_records(status, started_at);

    CREATE TABLE checkpoints (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        created_at REAL NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX checkpoints_task ON checkpoints(task_id, created_at DESC);

    CREATE TABLE artifacts (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        byte_count INTEGER NOT NULL,
        task_id TEXT,
        agent_id TEXT,
        created_at REAL NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX artifacts_task ON artifacts(task_id);

    CREATE TABLE memory_entities (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        name TEXT NOT NULL,
        scope TEXT NOT NULL,
        status TEXT NOT NULL,
        observed_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        superseded_by TEXT,
        json TEXT NOT NULL
    );
    CREATE INDEX memory_entities_name ON memory_entities(name COLLATE NOCASE, kind);
    CREATE INDEX memory_entities_scope ON memory_entities(scope, status, updated_at DESC);
    CREATE VIRTUAL TABLE entities_fts USING fts5(entity_id UNINDEXED, name, summary, attributes, \(fts));

    CREATE TABLE memory_relations (
        id TEXT PRIMARY KEY,
        from_id TEXT NOT NULL,
        relation TEXT NOT NULL,
        to_id TEXT NOT NULL,
        scope TEXT NOT NULL,
        status TEXT NOT NULL,
        observed_at REAL NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX memory_relations_from ON memory_relations(from_id, status);
    CREATE INDEX memory_relations_to ON memory_relations(to_id, status);

    CREATE TABLE preferences (
        id TEXT PRIMARY KEY,
        scope TEXT NOT NULL,
        status TEXT NOT NULL,
        version INTEGER NOT NULL,
        updated_at REAL NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX preferences_scope ON preferences(scope, status, updated_at DESC);
    CREATE VIRTUAL TABLE preferences_fts USING fts5(preference_id UNINDEXED, text, \(fts));

    CREATE TABLE embeddings (
        kind TEXT NOT NULL,
        item_id TEXT NOT NULL,
        dims INTEGER NOT NULL,
        vector BLOB NOT NULL,
        PRIMARY KEY (kind, item_id)
    );

    CREATE TABLE skills (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        status TEXT NOT NULL,
        version INTEGER NOT NULL,
        updated_at REAL NOT NULL,
        json TEXT NOT NULL
    );
    CREATE INDEX skills_status ON skills(status, updated_at DESC);
    CREATE VIRTUAL TABLE skills_fts USING fts5(skill_id UNINDEXED, name, purpose, applicability, \(fts));

    CREATE TABLE mcp_servers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at REAL NOT NULL,
        json TEXT NOT NULL
    );

    CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    """
}
