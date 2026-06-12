import fs from "node:fs";
import path from "node:path";
import Database from "better-sqlite3";
import { nanoid } from "nanoid";
import type {
  MemoryAuditRecord,
  MemoryForgetInput,
  MemoryRecord,
  MemorySaveInput,
  MemorySearchInput
} from "../../../shared/types";

type MemoryRow = {
  id: string;
  kind: MemoryRecord["kind"];
  subject: string;
  content: string;
  confidence: number;
  source: string;
  tags: string;
  created_at: string;
  updated_at: string;
};

function rowToRecord(row: MemoryRow): MemoryRecord {
  return {
    id: row.id,
    kind: row.kind,
    subject: row.subject,
    content: row.content,
    confidence: row.confidence,
    source: row.source,
    tags: JSON.parse(row.tags) as string[],
    createdAt: row.created_at,
    updatedAt: row.updated_at
  };
}

export class MemoryStore {
  private readonly db: Database.Database;

  constructor(dbPath: string) {
    fs.mkdirSync(path.dirname(dbPath), { recursive: true });
    this.db = new Database(dbPath);
    this.db.pragma("journal_mode = WAL");
    this.migrate();
  }

  private migrate(): void {
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS memories (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        subject TEXT NOT NULL,
        content TEXT NOT NULL,
        confidence REAL NOT NULL,
        source TEXT NOT NULL,
        tags TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
        memory_id UNINDEXED,
        subject,
        content,
        tags
      );

      CREATE TABLE IF NOT EXISTS memory_audit (
        id TEXT PRIMARY KEY,
        memory_id TEXT NOT NULL,
        action TEXT NOT NULL,
        reason TEXT NOT NULL,
        snapshot TEXT,
        created_at TEXT NOT NULL
      );
    `);
  }

  save(input: MemorySaveInput, reason = "tool_save"): MemoryRecord {
    const now = new Date().toISOString();
    const id = nanoid();
    const tags = JSON.stringify(input.tags ?? []);
    const insert = this.db.prepare(`
      INSERT INTO memories (
        id, kind, subject, content, confidence, source, tags, created_at, updated_at
      ) VALUES (
        @id, @kind, @subject, @content, @confidence, @source, @tags, @created_at, @updated_at
      )
    `);

    insert.run({
      id,
      kind: input.kind,
      subject: input.subject.trim(),
      content: input.content.trim(),
      confidence: input.confidence,
      source: input.source.trim(),
      tags,
      created_at: now,
      updated_at: now
    });

    this.reindexRecord(id);
    this.audit({
      memoryId: id,
      action: "save",
      reason,
      snapshot: JSON.stringify(input)
    });

    return this.getById(id)!;
  }

  listRecent(limit = 12): MemoryRecord[] {
    const rows = this.db
      .prepare(
        `
          SELECT *
          FROM memories
          ORDER BY updated_at DESC
          LIMIT ?
        `
      )
      .all(limit) as MemoryRow[];
    return rows.map(rowToRecord);
  }

  getById(id: string): MemoryRecord | undefined {
    const row = this.db
      .prepare(`SELECT * FROM memories WHERE id = ?`)
      .get(id) as MemoryRow | undefined;
    return row ? rowToRecord(row) : undefined;
  }

  search(input: MemorySearchInput): MemoryRecord[] {
    const limit = Math.max(1, Math.min(input.limit ?? 8, 25));
    const kinds = input.kinds?.length ? input.kinds : undefined;
    const query = input.query.trim();

    if (!query) {
      return this.listRecent(limit);
    }

    const params: Array<string | number> = [query];
    let kindClause = "";
    if (kinds?.length) {
      const placeholders = kinds.map(() => "?").join(", ");
      kindClause = `AND m.kind IN (${placeholders})`;
      params.push(...kinds);
    }
    params.push(limit);

    const rows = this.db
      .prepare(
        `
          SELECT m.*
          FROM memories_fts f
          JOIN memories m ON m.id = f.memory_id
          WHERE memories_fts MATCH ?
          ${kindClause}
          ORDER BY bm25(memories_fts), m.updated_at DESC
          LIMIT ?
        `
      )
      .all(...params) as MemoryRow[];

    return rows.map(rowToRecord);
  }

  forget(input: MemoryForgetInput, reason = "tool_forget"): MemoryRecord[] {
    const deleted: MemoryRecord[] = [];

    if (input.id) {
      const existing = this.getById(input.id);
      if (existing) {
        this.deleteById(existing.id, reason);
        deleted.push(existing);
      }
      return deleted;
    }

    if (!input.query?.trim()) {
      return deleted;
    }

    const matches = this.search({ query: input.query, limit: 6 });
    for (const match of matches) {
      this.deleteById(match.id, reason);
      deleted.push(match);
    }
    return deleted;
  }

  private deleteById(id: string, reason: string): void {
    const existing = this.getById(id);
    if (!existing) {
      return;
    }

    this.db.prepare(`DELETE FROM memories WHERE id = ?`).run(id);
    this.db.prepare(`DELETE FROM memories_fts WHERE memory_id = ?`).run(id);
    this.audit({
      memoryId: id,
      action: "delete",
      reason,
      snapshot: JSON.stringify(existing)
    });
  }

  private reindexRecord(id: string): void {
    const record = this.getById(id);
    if (!record) {
      return;
    }

    this.db.prepare(`DELETE FROM memories_fts WHERE memory_id = ?`).run(id);
    this.db
      .prepare(
        `
          INSERT INTO memories_fts (memory_id, subject, content, tags)
          VALUES (?, ?, ?, ?)
        `
      )
      .run(id, record.subject, record.content, record.tags.join(" "));
  }

  private audit(args: {
    memoryId: string;
    action: MemoryAuditRecord["action"];
    reason: string;
    snapshot?: string;
  }): void {
    this.db
      .prepare(
        `
          INSERT INTO memory_audit (
            id, memory_id, action, reason, snapshot, created_at
          ) VALUES (?, ?, ?, ?, ?, ?)
        `
      )
      .run(
        nanoid(),
        args.memoryId,
        args.action,
        args.reason,
        args.snapshot ?? null,
        new Date().toISOString()
      );
  }
}
