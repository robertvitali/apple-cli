#define JOURNAL_READ_POLICY 1
#define policy_install reader_install
#define policy_protect reader_protect
#define policy_closed reader_closed
#define policy_exec reader_exec
#define policy_prepare reader_prepare
#define policy_step reader_step
#include <stdio.h>
#include "Policy.h"
#include "SchemaSettings.h"
#include <stddef.h>
#include <string.h>
#ifdef JOURNAL_READ_POLICY
#include "ReaderStatements.h"
#else
#include "Statements.h"
#endif
typedef struct {int action; const char *first,*second,*database;} Rule;
typedef struct {unsigned first,count;} Range;
#ifdef JOURNAL_READ_POLICY
#include "ReaderCatalog.h"
#else
#include "Catalog.h"
#endif

#define COUNT(a) (sizeof(a)/sizeof((a)[0]))
_Static_assert(COUNT(statements)==COUNT(ranges),"inventory length mismatch");

/* The event journal has one dedicated connection on a single thread.
   The VFS already rejects a second writer connection in the same process. */
static sqlite3 *owner;
static const Range *preparing;
static sqlite3_stmt *stepping;
static int verifying_protection;
static int inside_call(void) {return preparing!=NULL || stepping!=NULL || verifying_protection;}

static const Range *find_range(const char *sql) {
    if(!sql) return NULL;
    size_t lo=0,hi=COUNT(statements);
    while(lo<hi){
        size_t mid=lo+(hi-lo)/2;
        int cmp=strcmp(sql,statements[mid]);
        if(cmp==0) return &ranges[mid];
        if(cmp<0) hi=mid; else lo=mid+1;
    }
    return NULL;
}

static int equal(const char *a,const char *b) {return a&&b ? strcmp(a,b)==0 : a==b;}

static int authorize(void *context,int op,const char *a,const char *b,const char *db,const char *source){
    if(context!=owner || source) return SQLITE_DENY;
    if(verifying_protection) return op==SQLITE_SELECT && !a && !b && !db ? SQLITE_OK : SQLITE_DENY;
    const Range *range=preparing;
    if(!range && stepping) {
        /* v2 may recompile at step time. Check the original SQL again. */
        range=find_range(sqlite3_sql(stepping));
    }
    if(!range) return SQLITE_DENY;
    for(unsigned i=range->first;i<range->first+range->count;i++){
        const Rule *r=&rules[i];
        if(op==r->action && equal(r->first,a) && equal(r->second,b) && equal(r->database,db))
            return SQLITE_OK;
    }
    return SQLITE_DENY;
}

int policy_install(sqlite3 *db){
    if(!db || owner || sqlite3_next_stmt(db,NULL)) return SQLITE_MISUSE;
    #ifdef JOURNAL_READ_POLICY
    if(sqlite3_db_readonly(db,"main")!=1) return SQLITE_READONLY;
    #endif
    owner=db;
    int rc=sqlite3_set_authorizer(db,authorize,db);
    if(rc!=SQLITE_OK) owner=NULL;
    return rc;
}

int policy_protect(sqlite3 *db) {
    if(!db || owner!=db || inside_call()) return SQLITE_MISUSE;
    verifying_protection=1;
    int rc=protect_schema_connection(db);
    verifying_protection=0;
    return rc;
}

void policy_closed(void) { owner=NULL; preparing=NULL; stepping=NULL; }

static int compile(sqlite3 *db,const char *sql,const Range *r,sqlite3_stmt **stmt) {
    if(!stmt) return SQLITE_MISUSE;
    *stmt=NULL;
    if(!db || db!=owner || inside_call()) return SQLITE_MISUSE;
    if(!r) return SQLITE_AUTH;
    const char *tail=NULL;
    preparing=r;
    int rc=sqlite3_prepare_v3(db,sql,-1,SQLITE_PREPARE_NO_VTAB,stmt,&tail);
    preparing=NULL;
    if(rc==SQLITE_OK && (!*stmt || !tail || *tail)){
        sqlite3_finalize(*stmt);
        *stmt=NULL;
        return SQLITE_AUTH;
    }
    return rc;
}

int policy_prepare(sqlite3 *db,const char *sql,sqlite3_stmt **stmt){
    return compile(db,sql,find_range(sql),stmt);
}


int policy_step(sqlite3_stmt *stmt){
    if(!stmt || !owner || sqlite3_db_handle(stmt)!=owner || inside_call()) return SQLITE_MISUSE;
    stepping=stmt;
    int rc=sqlite3_step(stmt);
    stepping=NULL;
    return rc;
}

int policy_exec(sqlite3 *db,const char *sql){
    sqlite3_stmt *stmt=NULL;
    int rc=policy_prepare(db,sql,&stmt);
    if(rc!=SQLITE_OK) return rc;
    do {rc=policy_step(stmt);} while(rc==SQLITE_ROW);
    int finish=sqlite3_finalize(stmt);
    return rc==SQLITE_DONE ? finish : rc;
}
