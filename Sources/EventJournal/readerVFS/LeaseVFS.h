#include <sqlite3.h>
enum { L_CHECK, L_CREATED, L_DELETED };
/* CHECK returns the verified rollback-file presence, or -1 on drift. */
typedef int (*LeaseCheck)(void *, int);
int leased_open(const char *, sqlite3 **, void *, LeaseCheck);
int leased_close(sqlite3 *);
int leased_open_limits(const char *, sqlite3 **, void *, LeaseCheck, sqlite3_int64, sqlite3_int64);
int leased_configure(sqlite3 *);
#include "SchemaSettings.h"
#include "Policy.h"
