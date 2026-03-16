#!/usr/bin/env bash
set -euo pipefail

# Extract copilot_lv.db into a session-state directory structure
# Usage: ./extract_sessions.sh [db_path] [target_dir]

DB="${1:-copilot_lv.db}"
TARGET="${2:-./extracted-session-state}"

if [[ ! -f "$DB" ]]; then
  echo "Error: database not found: $DB" >&2
  exit 1
fi

echo "Extracting from $DB → $TARGET"
mkdir -p "$TARGET"

count=0
total=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sessions WHERE copilot_session_id IS NOT NULL;")

sqlite3 "$DB" "SELECT copilot_session_id FROM sessions WHERE copilot_session_id IS NOT NULL ORDER BY copilot_session_id;" | while IFS= read -r session_uuid; do
  count=$((count + 1))
  dir="$TARGET/$session_uuid"
  mkdir -p "$dir"

  session_id=$(sqlite3 "$DB" "SELECT id FROM sessions WHERE copilot_session_id = '$session_uuid';")

  # ── events.jsonl ──
  sqlite3 -json "$DB" "
    SELECT event_type as type, event_id as id, parent_event_id as parentId,
           data, timestamp, sequence
    FROM events WHERE session_id = '$session_id' ORDER BY sequence;
  " 2>/dev/null | python3 -c "
import sys, json
rows = json.load(sys.stdin)
for row in rows:
    row['data'] = json.loads(row['data']) if isinstance(row['data'], str) else row['data']
    del row['sequence']
    print(json.dumps(row))
" > "$dir/events.jsonl" 2>/dev/null || true

  # Remove empty events files
  [[ ! -s "$dir/events.jsonl" ]] && rm -f "$dir/events.jsonl"

  # ── workspace.yaml (from artifact) ──
  sqlite3 "$DB" "
    SELECT content FROM session_artifacts
    WHERE session_id = '$session_id' AND path = 'workspace.yaml';
  " > "$dir/workspace.yaml" 2>/dev/null || true
  [[ ! -s "$dir/workspace.yaml" ]] && rm -f "$dir/workspace.yaml"

  # ── plan.md (from artifact) ──
  sqlite3 "$DB" "
    SELECT content FROM session_artifacts
    WHERE session_id = '$session_id' AND path = 'plan.md';
  " > "$dir/plan.md" 2>/dev/null || true
  [[ ! -s "$dir/plan.md" ]] && rm -f "$dir/plan.md"

  # ── files/* (from artifacts) ──
  sqlite3 -json "$DB" "
    SELECT path, content FROM session_artifacts
    WHERE session_id = '$session_id' AND artifact_type = 'file';
  " 2>/dev/null | python3 -c "
import sys, json, os
rows = json.load(sys.stdin)
base = sys.argv[1]
for row in rows:
    fpath = os.path.join(base, row['path'])
    os.makedirs(os.path.dirname(fpath), exist_ok=True)
    with open(fpath, 'w') as f:
        f.write(row['content'] or '')
" "$dir" 2>/dev/null || true

  # ── checkpoints/*.md ──
  has_checkpoints=$(sqlite3 "$DB" "SELECT COUNT(*) FROM checkpoints WHERE session_id = '$session_id';")
  if [[ "$has_checkpoints" -gt 0 ]]; then
    mkdir -p "$dir/checkpoints"
    sqlite3 -json "$DB" "
      SELECT filename, content FROM checkpoints
      WHERE session_id = '$session_id' ORDER BY number;
    " 2>/dev/null | python3 -c "
import sys, json, os
rows = json.load(sys.stdin)
cp_dir = sys.argv[1]
for row in rows:
    # Sanitize filename: keep only safe chars
    safe = ''.join(c if c.isalnum() or c in '-_.' else '-' for c in row['filename'])
    if not safe.endswith('.md'):
        safe += '.md'
    with open(os.path.join(cp_dir, safe), 'w') as f:
        f.write(row['content'] or '')
" "$dir/checkpoints" 2>/dev/null || true
  fi

  # ── session.db (reconstruct todos + custom tables) ──
  has_todos=$(sqlite3 "$DB" "SELECT COUNT(*) FROM session_todos WHERE session_id = '$session_id';")
  has_dump=$(sqlite3 "$DB" "SELECT COUNT(*) FROM session_artifacts WHERE session_id = '$session_id' AND artifact_type = 'session_db_dump';")

  if [[ "$has_todos" -gt 0 ]] || [[ "$has_dump" -gt 0 ]]; then
    sdb="$dir/session.db"
    rm -f "$sdb"

    # Create todos tables
    sqlite3 "$sdb" "
      CREATE TABLE todos (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT,
        status TEXT DEFAULT 'pending' CHECK(status IN ('pending', 'in_progress', 'done', 'blocked')),
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
      );
      CREATE TABLE todo_deps (
        todo_id TEXT NOT NULL,
        depends_on TEXT NOT NULL,
        PRIMARY KEY (todo_id, depends_on),
        FOREIGN KEY (todo_id) REFERENCES todos(id),
        FOREIGN KEY (depends_on) REFERENCES todos(id)
      );
    "

    # Insert todos
    sqlite3 -json "$DB" "
      SELECT todo_id, title, description, status, depends_on
      FROM session_todos WHERE session_id = '$session_id';
    " 2>/dev/null | python3 -c "
import sys, json, sqlite3, os
rows = json.load(sys.stdin)
sdb = sys.argv[1]
conn = sqlite3.connect(sdb)
for row in rows:
    conn.execute('INSERT OR REPLACE INTO todos (id, title, description, status) VALUES (?, ?, ?, ?)',
                 (row['todo_id'], row['title'], row['description'], row['status']))
    deps = json.loads(row['depends_on']) if isinstance(row['depends_on'], str) else (row['depends_on'] or [])
    for dep in deps:
        conn.execute('INSERT OR IGNORE INTO todo_deps (todo_id, depends_on) VALUES (?, ?)',
                     (row['todo_id'], dep))
conn.commit()
conn.close()
" "$sdb" 2>/dev/null || true

    # Reconstruct custom tables from session_db_dump artifact
    if [[ "$has_dump" -gt 0 ]]; then
      sqlite3 "$DB" "
        SELECT content FROM session_artifacts
        WHERE session_id = '$session_id' AND artifact_type = 'session_db_dump';
      " 2>/dev/null | python3 -c "
import sys, json, sqlite3
data = json.loads(sys.stdin.read())
conn = sqlite3.connect(sys.argv[1])
for table in data:
    conn.execute(table['ddl'])
    if table['data']:
        cols = list(table['data'][0].keys())
        placeholders = ', '.join(['?'] * len(cols))
        col_names = ', '.join(['\"' + c + '\"' for c in cols])
        for row in table['data']:
            vals = [row[c] for c in cols]
            conn.execute(f'INSERT INTO {table[\"table\"]} ({col_names}) VALUES ({placeholders})', vals)
conn.commit()
conn.close()
" "$sdb" 2>/dev/null || true
    fi
  fi

  # Progress
  printf "\r  [%d/%d] %s" "$count" "$total" "$session_uuid"
done

echo ""
echo ""

# Summary
sessions=$(find "$TARGET" -maxdepth 1 -type d | tail -n+2 | wc -l)
events=$(find "$TARGET" -name "events.jsonl" | wc -l)
plans=$(find "$TARGET" -name "plan.md" | wc -l)
workspaces=$(find "$TARGET" -name "workspace.yaml" | wc -l)
checkpoints=$(find "$TARGET" -path "*/checkpoints/*.md" | wc -l)
session_dbs=$(find "$TARGET" -name "session.db" | wc -l)
files_artifacts=$(find "$TARGET" -path "*/files/*" -type f | wc -l)

echo "=== Extraction Complete ==="
echo "  Sessions:    $sessions"
echo "  events.jsonl: $events"
echo "  workspace.yaml: $workspaces"
echo "  plan.md:     $plans"
echo "  checkpoints: $checkpoints"
echo "  session.db:  $session_dbs"
echo "  files/*:     $files_artifacts"
echo ""
echo "Total size: $(du -sh "$TARGET" | cut -f1)"
