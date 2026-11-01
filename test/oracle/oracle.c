/* The reference oracle. See oracle.h for the interface and docs/research.md,
 * section 6, for why it works the way it does. Uses only SQLite's public API. */
#include <stdio.h>
#include <string.h>
#include <sqlite3.h>
#include "oracle.h"

/* Messages SQLite raises while parsing that depend only on the text. Everything
 * else (no such table, duplicate column name, ...) is semantic. */
static const char *const syntax_messages[] = {
    "syntax error",
    "incomplete input",
    "unrecognized token",
    "unknown table option",
    "unknown join type",
    "should come after",
    "qualified table names are not allowed",
    "the INDEXED BY clause is not allowed",
    "the NOT INDEXED clause is not allowed",
    "a JOIN clause is required before",
};

static int is_syntax_error(const char *msg) {
    for (size_t i = 0; i < sizeof(syntax_messages) / sizeof(syntax_messages[0]); i++) {
        if (strstr(msg, syntax_messages[i]) != 0) return 1;
    }
    return 0;
}

/* Length of the first statement in sql[0..len): the shortest prefix ending in
 * ';' that sqlite3_complete() calls complete, or len. buf has room for len+1. */
static int statement_length(const char *sql, int len, char *buf) {
    for (int i = 0; i < len; i++) {
        if (sql[i] != ';') continue;
        memcpy(buf, sql, (size_t)i + 1);
        buf[i + 1] = 0;
        if (sqlite3_complete(buf)) return i + 1;
    }
    return len;
}

static int collation_cmp(void *arg, int na, const void *a, int nb, const void *b) {
    (void)arg;
    int n = na < nb ? na : nb;
    int c = memcmp(a, b, (size_t)n);
    return c != 0 ? c : na - nb;
}

/* Appends name to sql as a quoted identifier, as "db"."table" when qualified. */
static void quote_name(sqlite3_str *sql, const char *name) {
    const char *dot = strchr(name, '.');
    if (dot != 0) {
        sqlite3_str_appendf(sql, "\"%.*w\".", (int)(dot - name), name);
        name = dot + 1;
    }
    sqlite3_str_appendf(sql, "\"%w\"", name);
}

static int has_prefix(const char *s, const char *prefix, const char **rest) {
    size_t n = strlen(prefix);
    if (strncmp(s, prefix, n) != 0) return 0;
    *rest = s + n;
    return 1;
}

/* Some statements fail mid-parse on a missing schema object, which hides the
 * rest of the statement from the parser: CREATE TRIGGER needs its table,
 * ALTER TABLE ADD COLUMN needs the table, CREATE TABLE x.t needs database x.
 * Creates a stand-in for the missing object so the parse can go further.
 * Returns 1 when something was created. */
static int synthesize_schema(sqlite3 *db, const char *msg) {
    const char *name;
    if (has_prefix(msg, "no such collation sequence: ", &name)) {
        return sqlite3_create_collation_v2(db, name, SQLITE_UTF8, 0, collation_cmp, 0) == SQLITE_OK;
    }
    sqlite3_str *sql = sqlite3_str_new(db);
    int known = 1;
    if (has_prefix(msg, "no such table: ", &name)) {
        sqlite3_str_appendall(sql, "CREATE TABLE ");
        quote_name(sql, name);
        sqlite3_str_appendall(sql, "(\"oracle stand-in\")");
    } else if (has_prefix(msg, "unknown database ", &name)) {
        sqlite3_str_appendf(sql, "ATTACH ':memory:' AS \"%w\"", name);
    } else if (has_prefix(msg, "cannot create INSTEAD OF trigger on table: ", &name)) {
        sqlite3_str_appendall(sql, "DROP TABLE ");
        quote_name(sql, name);
        sqlite3_str_appendall(sql, "; CREATE VIEW ");
        quote_name(sql, name);
        sqlite3_str_appendall(sql, " AS SELECT 1 AS \"oracle stand-in\"");
    } else {
        known = 0;
    }
    char *text = sqlite3_str_finish(sql);
    int ok = known && text != 0 && sqlite3_exec(db, text, 0, 0, 0) == SQLITE_OK;
    sqlite3_free(text);
    return ok;
}

static void copy_message(struct oracle_result *out, const char *msg) {
    size_t n = strlen(msg);
    if (n >= sizeof(out->message)) n = sizeof(out->message) - 1;
    memcpy(out->message, msg, n);
    out->message[n] = 0;
}

static int open_db(sqlite3 **db) {
    int rc = sqlite3_open_v2(":memory:", db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, 0);
    if (rc != SQLITE_OK) {
        sqlite3_close(*db);
        *db = 0;
    }
    return rc;
}

const char *oracle_sqlite_version(void) {
    return sqlite3_libversion();
}

int oracle_check(const char *sql, int len, struct oracle_result *out) {
    memset(out, 0, sizeof(*out));
    out->verdict = ORACLE_ACCEPT;
    out->error_offset = -1;

    char *buf = sqlite3_malloc(len + 1);
    if (buf == 0) return SQLITE_NOMEM;
    out->length = statement_length(sql, len, buf);
    sqlite3_free(buf);

    sqlite3 *db = 0;
    int rc = open_db(&db);
    if (rc != SQLITE_OK) return rc;
    for (int attempt = 0;; attempt++) {
        sqlite3_stmt *stmt = 0;
        const char *tail = 0;
        rc = sqlite3_prepare_v3(db, sql, out->length, 0, &stmt, &tail);
        sqlite3_finalize(stmt);
        if (rc == SQLITE_OK) break;
        if (rc == SQLITE_NOMEM) {
            sqlite3_close(db);
            return rc;
        }
        const char *msg = sqlite3_errmsg(db);
        copy_message(out, msg);
        if (is_syntax_error(msg)) {
            out->verdict = ORACLE_REJECT;
            out->error_offset = sqlite3_error_offset(db);
            break;
        }
        /* SQLite stops parsing at the token where an error is raised and sets
         * tail just past it. A semantic error raised at the end of the
         * statement means the parser accepted all of it. */
        if (tail - sql >= out->length) break;
        if (attempt == 8 || !synthesize_schema(db, msg)) {
            out->verdict = ORACLE_UNKNOWN;
            break;
        }
    }
    sqlite3_close(db);
    return SQLITE_OK;
}

static void append_value(sqlite3_str *s, sqlite3_stmt *stmt, int col) {
    switch (sqlite3_column_type(stmt, col)) {
        case SQLITE_INTEGER:
            sqlite3_str_appendf(s, "integer:%lld", sqlite3_column_int64(stmt, col));
            break;
        case SQLITE_FLOAT:
            sqlite3_str_appendf(s, "real:%!.17g", sqlite3_column_double(stmt, col));
            break;
        case SQLITE_TEXT:
            sqlite3_str_appendf(s, "text:%s", (const char *)sqlite3_column_text(stmt, col));
            break;
        case SQLITE_BLOB: {
            const unsigned char *p = sqlite3_column_blob(stmt, col);
            int n = sqlite3_column_bytes(stmt, col);
            sqlite3_str_appendall(s, "blob:");
            for (int i = 0; i < n; i++) sqlite3_str_appendf(s, "%02x", p[i]);
            break;
        }
        default:
            sqlite3_str_appendall(s, "null:");
            break;
    }
}

int oracle_eval(const char *sql, int len, char *buf, int cap) {
    sqlite3 *db = 0;
    if (cap <= 0) return 2;
    buf[0] = 0;
    if (open_db(&db) != SQLITE_OK) {
        snprintf(buf, (size_t)cap, "cannot open database");
        return 1;
    }
    sqlite3_stmt *stmt = 0;
    const char *tail = 0;
    int status = 0;
    if (sqlite3_prepare_v3(db, sql, len, 0, &stmt, &tail) != SQLITE_OK) {
        snprintf(buf, (size_t)cap, "%s", sqlite3_errmsg(db));
        sqlite3_close(db);
        return 1;
    }
    for (const char *p = tail; p < sql + len; p++) {
        if (*p != ' ' && *p != '\t' && *p != '\n' && *p != '\r' && *p != ';') status = 2;
    }
    if (stmt == 0 || !sqlite3_stmt_readonly(stmt)) status = 2;
    if (status == 2) {
        sqlite3_finalize(stmt);
        sqlite3_close(db);
        return 2;
    }
    sqlite3_str *s = sqlite3_str_new(db);
    int rc;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        for (int col = 0; col < sqlite3_column_count(stmt); col++) {
            if (col > 0) sqlite3_str_appendchar(s, 1, '|');
            append_value(s, stmt, col);
        }
        sqlite3_str_appendchar(s, 1, '\n');
    }
    char *text = sqlite3_str_finish(s);
    if (rc != SQLITE_DONE) {
        snprintf(buf, (size_t)cap, "%s", sqlite3_errmsg(db));
        status = 1;
    } else {
        snprintf(buf, (size_t)cap, "%s", text != 0 ? text : "");
    }
    sqlite3_free(text);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return status;
}
