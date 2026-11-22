#include "SchemaSettings.h"
#include <string.h>
#include <stddef.h>

static int set_and_read(sqlite3 *db, int option, int value) {
    int actual = -1;
    int rc = sqlite3_db_config(db, option, value, &actual);
    if (rc != SQLITE_OK || actual != value) return rc != SQLITE_OK ? rc : SQLITE_ERROR;
    actual = -1;
    rc = sqlite3_db_config(db, option, -1, &actual);
    return rc != SQLITE_OK ? rc : actual == value ? SQLITE_OK : SQLITE_ERROR;
}
int protect_schema_connection(sqlite3 *db) {
    if (!db) return SQLITE_MISUSE;
    int rc = set_and_read(db, SQLITE_DBCONFIG_DEFENSIVE, 1);
    if (rc == SQLITE_OK) rc = set_and_read(db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0);
    if (rc == SQLITE_OK) rc = set_and_read(db, SQLITE_DBCONFIG_ENABLE_TRIGGER, 0);
    if (rc == SQLITE_OK) rc = set_and_read(db, SQLITE_DBCONFIG_ENABLE_VIEW, 0);
    if (rc != SQLITE_OK) return rc;
    if (!sqlite3_compileoption_used("OMIT_LOAD_EXTENSION"))
        return set_and_read(db, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 0);
    sqlite3_stmt *stmt = NULL;
    rc = sqlite3_prepare_v2(db,"SELECT load_extension('')",-1,&stmt,NULL);
    int absent = rc == SQLITE_ERROR && stmt == NULL &&
                 strcmp(sqlite3_errmsg(db), "no such function: load_extension") == 0;
    sqlite3_finalize(stmt);
    return absent ? SQLITE_OK : rc == SQLITE_OK ? SQLITE_ERROR : (rc == SQLITE_ERROR ? SQLITE_MISMATCH : rc);
}
