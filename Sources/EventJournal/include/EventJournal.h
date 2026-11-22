#ifndef APPLE_EVENT_JOURNAL_H
#define APPLE_EVENT_JOURNAL_H
#include "Ownership.h"
#include "LeaseVFS.h"
int barrier_sync_main(sqlite3 *);
int begin_bootstrap(void);
void end_bootstrap(void);
int inspect_open(const char *, sqlite3 **, void *, LeaseCheck);
int inspect_close(sqlite3 *);
#endif
