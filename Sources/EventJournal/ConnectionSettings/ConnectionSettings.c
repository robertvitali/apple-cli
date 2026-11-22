#include "Policy.h"
#include <sqlite3.h>
#include <stddef.h>

static int matches(const char *value, const char *expected) {
    return value != NULL && sqlite3_stricmp(value, expected) == 0;
}

/* Each fixed readback must produce exactly one value of the expected type. */
static int read_setting(sqlite3 *db, const char *sql, const char *text, int integer) {
    sqlite3_stmt *stmt = NULL;
    int rc = policy_prepare(db, sql, &stmt);
    if (rc == SQLITE_OK) {
        rc = policy_step(stmt);
        if (rc == SQLITE_ROW) {
            int ok = text ? sqlite3_column_type(stmt,0) == SQLITE_TEXT &&
                            matches((const char *)sqlite3_column_text(stmt,0),text)
                          : sqlite3_column_type(stmt,0) == SQLITE_INTEGER &&
                            sqlite3_column_int64(stmt,0) == integer;
            rc = ok ? policy_step(stmt) : SQLITE_MISMATCH;
            rc = rc == SQLITE_DONE ? SQLITE_OK : rc == SQLITE_ROW ? SQLITE_MISMATCH : rc;
        } else if (rc == SQLITE_DONE) rc = SQLITE_MISMATCH;
    }
    int finish = sqlite3_finalize(stmt);
    return rc == SQLITE_OK ? finish : rc;
}

int leased_configure(sqlite3 *db) {
    if (!db || sqlite3_compileoption_used("TEMP_STORE=0")) return SQLITE_ERROR;
    static const char *const setup[] = {
        "PRAGMA main.max_page_count=131072","PRAGMA journal_mode=TRUNCATE","PRAGMA synchronous=FULL",
        "PRAGMA temp_store=MEMORY","PRAGMA temp.page_size=4096","PRAGMA temp.max_page_count=4096"
    };
    int rc = SQLITE_OK;
    for (size_t i=0; i<sizeof(setup)/sizeof(setup[0]) && rc==SQLITE_OK; i++) rc=policy_exec(db,setup[i]);
    if (rc==SQLITE_OK) rc=read_setting(db,"PRAGMA main.journal_mode","truncate",0);
    if (rc==SQLITE_OK) rc=read_setting(db,"PRAGMA main.synchronous",NULL,2);
    if (rc==SQLITE_OK) rc=read_setting(db,"PRAGMA temp_store",NULL,2);
    if (rc==SQLITE_OK) rc=read_setting(db,"PRAGMA temp.page_size",NULL,4096);
    if (rc==SQLITE_OK) rc=read_setting(db,"PRAGMA temp.max_page_count",NULL,4096);
    return rc;
}
