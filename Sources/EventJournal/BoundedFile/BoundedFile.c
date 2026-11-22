#include "BoundedFile.h"
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

/* SQLite supplies aligned storage of szOsFile bytes. The delegate occupies
   a separate, aligned tail and never shares its method table with SQLite. */
typedef union {
    struct {
        sqlite3_file file;
        sqlite3_int64 limit;
        int lockLevel;
    } value;
    sqlite3_int64 align;
    void *pointerAlignment;
} BoundedFile;

int bounded_storage_size(int nativeSize) {
    if (nativeSize <= 0 || nativeSize > INT_MAX - (int)sizeof(BoundedFile)) return 0;
    return nativeSize + (int)sizeof(BoundedFile);
}

sqlite3_file *bounded_native_storage(sqlite3_file *outer) {
    return (sqlite3_file *)((BoundedFile *)outer + 1);
}

static int close_file(sqlite3_file *f) {
    sqlite3_file *n = bounded_native_storage(f);
    int rc = n->pMethods->xClose(n);
    f->pMethods = NULL;
    return rc;
}

static int in_range(sqlite3_file *f, sqlite3_int64 offset, int count) {
    sqlite3_int64 limit = ((BoundedFile *)f)->value.limit;
    return count >= 0 && offset >= 0 && offset <= limit && count <= limit - offset;
}

static int read_file(sqlite3_file *f, void *buffer, int count, sqlite3_int64 offset) {
    sqlite3_file *n = bounded_native_storage(f);
    /* Reads overlapping EOF use SQLite's standard zero-filled short read. */
    if (offset < 0 || count < 0 || offset > LLONG_MAX - count) return SQLITE_IOERR_READ;
    return n->pMethods->xRead(n, buffer, count, offset);
}

static int write_file(sqlite3_file *f, const void *bytes, int count, sqlite3_int64 offset) {
    sqlite3_file *n = bounded_native_storage(f);
    if (!in_range(f, offset, count)) return SQLITE_FULL;
    return n->pMethods->xWrite(n, bytes, count, offset);
}

static int truncate_file(sqlite3_file *f, sqlite3_int64 length) {
    sqlite3_file *n = bounded_native_storage(f);
    if (!in_range(f, length, 0)) return SQLITE_FULL;
    return n->pMethods->xTruncate(n,length);
}

static int sync_file(sqlite3_file *f, int flags) {
    sqlite3_file *n = bounded_native_storage(f);
    return n->pMethods->xSync(n, flags);
}

static int size_file(sqlite3_file *f, sqlite3_int64 *result) {
    sqlite3_file *n = bounded_native_storage(f);
    int rc = n->pMethods->xFileSize(n, result);
    if (rc != SQLITE_OK) return rc;
    return in_range(f, *result, 0) ? SQLITE_OK : SQLITE_FULL;
}

static int lock_file(sqlite3_file *f, int level) {
    sqlite3_file *n = bounded_native_storage(f);
    int rc=n->pMethods->xLock(n, level);
    int *state=&((BoundedFile *)f)->value.lockLevel;
    if(rc!=SQLITE_OK) *state=-1;
    else if(*state>=0 && level>*state) *state=level;
    return rc;
}

static int unlock_file(sqlite3_file *f, int level) {
    sqlite3_file *n = bounded_native_storage(f);
    int rc=n->pMethods->xUnlock(n, level);
    int *state=&((BoundedFile *)f)->value.lockLevel;
    if(rc!=SQLITE_OK) *state=-1;
    else if(level==SQLITE_LOCK_NONE || *state>=0) *state=level;
    return rc;
}

static int reserved_lock(sqlite3_file *f, int *result) {
    sqlite3_file *n = bounded_native_storage(f);
    return n->pMethods->xCheckReservedLock(n, result);
}

static int control_file(sqlite3_file *f, int op, void *arg) {
    sqlite3_file *n = bounded_native_storage(f);
    /* Skip optional preallocation, growth rounding and backend-specific
       PRAGMAs. Unknown controls must never reach the native file. */
    if (op == SQLITE_FCNTL_HAS_MOVED || op == SQLITE_FCNTL_LOCKSTATE)
        return n->pMethods->xFileControl(n, op, arg);
    return SQLITE_NOTFOUND;
}

static int sector_size(sqlite3_file *f) {
    sqlite3_file *n = bounded_native_storage(f);
    return n->pMethods->xSectorSize(n);
}

static int characteristics(sqlite3_file *f) {
    (void)f;
    return 0; /* Use the pager's conservative journal and sync paths. */
}

static const sqlite3_io_methods methods = {
    .iVersion = 1, .xClose = close_file, .xRead = read_file, .xWrite = write_file,
    .xTruncate = truncate_file, .xSync = sync_file, .xFileSize = size_file,
    .xLock = lock_file, .xUnlock = unlock_file, .xCheckReservedLock = reserved_lock,
    .xFileControl = control_file, .xSectorSize = sector_size,
    .xDeviceCharacteristics = characteristics
};

int bounded_install(sqlite3_file *outer, sqlite3_int64 limit) {
    sqlite3_int64 existing;
    ((BoundedFile *)outer)->value.lockLevel=SQLITE_LOCK_NONE;
    ((BoundedFile *)outer)->value.limit = limit;
    int rc = size_file(outer, &existing);
    if (rc == SQLITE_OK) outer->pMethods = &methods;
    return rc;
}

int barrier_sync_main(sqlite3 *db) {
    sqlite3_file *f=NULL;
    int rc=sqlite3_file_control(db,"main",SQLITE_FCNTL_FILE_POINTER,&f);
    if(rc!=SQLITE_OK) return rc;
    if(!f || f->pMethods!=&methods || sqlite3_txn_state(db,"main")!=SQLITE_TXN_WRITE ||
       ((BoundedFile *)f)->value.lockLevel!=SQLITE_LOCK_EXCLUSIVE) return SQLITE_PROTOCOL;
    return f->pMethods->xSync(f,SQLITE_SYNC_FULL);
}
