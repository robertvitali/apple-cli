int event_sql_thread(void);
// The replay worker holds one connection at a time under its retained lease.
// Writer registration is invoked only by the leased VFS, reader registration by replay.
#include <sqlite3.h>
#include <stddef.h>
#define DECL(prefix) \
    int prefix##install(sqlite3 *); int prefix##protect(sqlite3 *); \
    void prefix##closed(void); int prefix##prepare(sqlite3 *, const char *, sqlite3_stmt **); \
    int prefix##exec(sqlite3 *,const char *); int prefix##step(sqlite3_stmt *);
DECL(reader_)
DECL(writer_)
DECL(creator_)
static int bootstrap;
static sqlite3 *owner;
static int write_access;
static int install(sqlite3 *db,int write) {
    if (!db || owner || sqlite3_db_readonly(db,"main") != !write) return SQLITE_MISUSE;
    int rc=write ? (bootstrap ? creator_install(db) : writer_install(db)) : reader_install(db);
    if(rc==SQLITE_OK) { owner=db; write_access=write ? (bootstrap ? 2 : 1) : 0; }
    return rc;
}
int install_writer(sqlite3 *db) {return install(db,1);}
int policy_install(sqlite3 *db) {return install(db,0);}
int policy_protect(sqlite3 *db) {
    if(!event_sql_thread() || !owner || db!=owner) return SQLITE_MISUSE;
    return write_access==2 ? creator_protect(db) : write_access ? writer_protect(db) : reader_protect(db);
}
int policy_prepare(sqlite3 *db,const char *sql,sqlite3_stmt **s) {
    if(!s) return SQLITE_MISUSE;
    *s=NULL;
    if(!event_sql_thread() || !owner || db!=owner) return SQLITE_MISUSE;
    return write_access==2 ? creator_prepare(db,sql,s) : write_access ? writer_prepare(db,sql,s) : reader_prepare(db,sql,s);
}
int policy_exec(sqlite3 *db,const char *sql) {
    if(!event_sql_thread() || !owner || db!=owner) return SQLITE_MISUSE;
    return write_access==2 ? creator_exec(db,sql) : write_access ? writer_exec(db,sql) : reader_exec(db,sql);
}
int policy_step(sqlite3_stmt *s) {
    if(!event_sql_thread() || !owner || !s || sqlite3_db_handle(s)!=owner) return SQLITE_MISUSE;
    return write_access==2 ? creator_step(s) : write_access ? writer_step(s) : reader_step(s);
}
void policy_closed(void) {
    if(owner) {
        if(write_access==2) creator_closed(); else if(write_access) writer_closed(); else reader_closed();
        owner=NULL; write_access=0;
    }
}

int begin_bootstrap(void){if(bootstrap||owner)return SQLITE_MISUSE;bootstrap=1;return SQLITE_OK;}
void end_bootstrap(void){bootstrap=0;}
