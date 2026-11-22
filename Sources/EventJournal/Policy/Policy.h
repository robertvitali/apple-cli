#ifndef JOURNAL_SQL_POLICY_H
#define JOURNAL_SQL_POLICY_H
#include <sqlite3.h>
int policy_protect(sqlite3 *);
int policy_install(sqlite3 *);
void policy_closed(void);
int policy_prepare(sqlite3 *, const char *, sqlite3_stmt **);
int policy_exec(sqlite3 *, const char *);
int policy_step(sqlite3_stmt *);
#endif
