/* The reference oracle: asks the real SQLite library whether SQL parses.
 * Test-only. Never linked into the library or the CLI. */
#ifndef ORACLE_H
#define ORACLE_H

enum oracle_verdict {
    /* SQLite's parser accepted the statement. */
    ORACLE_ACCEPT = 0,
    /* SQLite's parser rejected the statement with a syntax-class error. */
    ORACLE_REJECT = 1,
    /* A semantic error stopped SQLite before its parser saw the whole statement,
     * so the oracle cannot tell. */
    ORACLE_UNKNOWN = 2,
};

struct oracle_result {
    int verdict;
    /* Byte length of the checked statement: through its terminating ';' as
     * sqlite3_complete() finds it, or to the end of the input. */
    int length;
    /* For ORACLE_REJECT: the byte offset (from the start of the input) of the
     * token SQLite blames, or -1 when SQLite reports none ("incomplete input"). */
    int error_offset;
    /* SQLite's error message, or "" when there was none. */
    char message[256];
};

/* SQLite's version string, for example "3.45.1". */
const char *oracle_sqlite_version(void);

/* Checks the first statement in sql[0..len). Each call uses a fresh in-memory
 * database and only prepares statements, so nothing is executed and nothing
 * touches the filesystem. Returns 0, or an SQLite error code when the oracle
 * itself could not run (out of memory). */
int oracle_check(const char *sql, int len, struct oracle_result *out);

/* Prepares and runs the single read-only statement sql[0..len) on a fresh
 * in-memory database and writes its result rows to buf (NUL-terminated,
 * truncated to cap bytes). Each value is written as "<type>:<value>", values
 * are separated by '|' and rows end with '\n'. Returns 0 on success, 1 when
 * SQLite reported an error (buf holds the message), 2 when the statement is
 * not read-only or is not exactly one statement (nothing was run). */
int oracle_eval(const char *sql, int len, char *buf, int cap);

#endif
