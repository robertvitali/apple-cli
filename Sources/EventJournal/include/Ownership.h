#ifndef EVENT_JOURNAL_OWNERSHIP_H
#define EVENT_JOURNAL_OWNERSHIP_H
#include <sqlite3.h>
#include <stdint.h>

typedef enum { EVENT_INSPECT, EVENT_WRITE, EVENT_INITIALIZE } EventRole;
typedef struct {
    sqlite3 *database;
    uint64_t generation;
} EventConnection;
typedef struct {
    void *context;
    int (*check)(void *, int);
    void (*retain)(void *);
    void (*release)(void *);
} EventWitness;

int event_open(EventConnection *, EventRole, const char *, EventWitness, sqlite3_int64, sqlite3_int64);
int event_close(EventConnection *);
#endif
