#include "Ownership.h"
#include <pthread.h>
#include <stddef.h>

int inspect_open_limits(const char *, sqlite3 **, void *, int (*)(void *, int), sqlite3_int64, sqlite3_int64);
int leased_open_limits(const char *, sqlite3 **, void *, int (*)(void *, int), sqlite3_int64, sqlite3_int64);
int inspect_close(sqlite3 *);
int leased_close(sqlite3 *);
int begin_bootstrap(void);
void end_bootstrap(void);

typedef enum { VACANT, OPENING, OPENED, CLOSING, UNAVAILABLE } Phase;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct {
    Phase phase;
    EventConnection connection;
    EventRole role;
    EventWitness witness;
    pthread_t owner;
} active;
static uint64_t lastGeneration;

int event_open(EventConnection *out, EventRole role, const char *path,
               EventWitness witness, sqlite3_int64 mainLimit, sqlite3_int64 journalLimit) {
    if (!out || out->database || out->generation || !path || !witness.context ||
        !witness.check || !witness.retain || !witness.release ||
        (role != EVENT_INSPECT && role != EVENT_WRITE && role != EVENT_INITIALIZE)) return SQLITE_MISUSE;
    pthread_mutex_lock(&lock);
    if (active.phase != VACANT || lastGeneration == UINT64_MAX) {
        int rc = active.phase != VACANT ? SQLITE_BUSY : SQLITE_FULL;
        pthread_mutex_unlock(&lock);
        return rc;
    }
    active.phase = OPENING;
    active.owner = pthread_self();
    active.role = role;
    active.witness = witness;
    uint64_t generation = ++lastGeneration;
    pthread_mutex_unlock(&lock);

    // No mutex is held across SQLite calls or client witness callbacks.
    witness.retain(witness.context);
    sqlite3 *db = NULL;
    int rc = role == EVENT_INITIALIZE ? begin_bootstrap() : SQLITE_OK;
    if (rc == SQLITE_OK) {
        if (role == EVENT_INSPECT) {
            rc = inspect_open_limits(path, &db, witness.context, witness.check, mainLimit, journalLimit);
        } else {
            rc = leased_open_limits(path, &db, witness.context, witness.check, mainLimit, journalLimit);
        }
        if (role == EVENT_INITIALIZE) end_bootstrap();
    }
    if (rc != SQLITE_OK && !db) witness.release(witness.context);
    pthread_mutex_lock(&lock);
    if (rc == SQLITE_OK && db) {
        active.connection = (EventConnection){db, generation};
        active.phase = OPENED;
        *out = active.connection;
    } else if (db || rc == SQLITE_OK) {
        // An inconsistent lower-layer outcome leaves ownership reserved.
        active.phase = UNAVAILABLE;
        rc = SQLITE_INTERNAL;
    } else {
        active = (__typeof__(active)){0};
    }
    pthread_mutex_unlock(&lock);
    return rc;
}

int event_close(EventConnection *ticket) {
    if (!ticket || !ticket->database || !ticket->generation) return SQLITE_MISUSE;
    pthread_mutex_lock(&lock);
    if (active.phase != OPENED || active.connection.database != ticket->database ||
        active.connection.generation != ticket->generation || !pthread_equal(active.owner, pthread_self())) {
        pthread_mutex_unlock(&lock);
        return SQLITE_MISUSE;
    }
    active.phase = CLOSING;
    EventRole role = active.role;
    EventWitness witness = active.witness;
    pthread_mutex_unlock(&lock);

    int rc = role == EVENT_INSPECT ? inspect_close(ticket->database) : leased_close(ticket->database);
    if (rc == SQLITE_OK) witness.release(witness.context);
    pthread_mutex_lock(&lock);
    if (rc == SQLITE_OK) {
        active = (__typeof__(active)){0};
        *ticket = (EventConnection){0};
    } else {
        // SQLITE_BUSY leaves sqlite3_close's handle open for finalization and retry.
        // Other errors can arise after close, during unregister. Do not reuse the slot.
        active.phase = rc == SQLITE_BUSY ? OPENED : UNAVAILABLE;
    }
    pthread_mutex_unlock(&lock);
    return rc;
}

/* Scope the statement-policy entry points to the synchronous owner.
   A contender must return before touching the policy's mutable context. */
int event_sql_thread(void) {
    pthread_mutex_lock(&lock);
    int allowed = active.phase == OPENED && pthread_equal(active.owner,pthread_self());
    pthread_mutex_unlock(&lock);
    return allowed;
}
