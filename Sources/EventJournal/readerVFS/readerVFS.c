#define bounded_storage_size inspect_bounded_storage_size
#define bounded_native_storage inspect_bounded_native_storage
#define bounded_install inspect_bounded_install
#define leased_open inspect_open
#define leased_close inspect_close
#define leased_open_limits inspect_open_limits
#include "LeaseVFS.h"
#include "BoundedFile.h"
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* Dedicated journal connection. The system default VFS is preserved. */
typedef struct {
    sqlite3_vfs api;
    sqlite3_vfs *base;
    char main[PATH_MAX], journal[PATH_MAX], wal[PATH_MAX];
    sqlite3_int64 mainLimit, journalLimit;
    LeaseCheck check;
    void *ctx;
    int poisoned, opens, creates, deletes;
} Wrapper;
int writer_settings(void *, int, const char *, const char *, const char *, const char *);
static Wrapper state;
/* Publish each method table once. Only the selected opener thread can enter
   xFullPathname and the first main xOpen of an owned connection. */
enum { idle, expect_path, expect_main };
static _Thread_local int opening;
static _Thread_local int owning;
static void clear_owner(Wrapper *w) {
    owning = 0;
    w->main[0] = w->journal[0] = w->wal[0] = 0;
    w->ctx = NULL;
    w->check = NULL;
}

static Wrapper *owner(sqlite3_vfs *v) { return v->pAppData; }
static int failed(Wrapper *w) { w->poisoned=1; return SQLITE_IOERR; }
static int observed(Wrapper *w,int op) {
    if(!owning || !w->check || w->poisoned) return -1;
    int rc=w->check(w->ctx,op);
    if(rc<0) w->poisoned=1;
    return rc;
}
static int exact(const char *a,const char *b) {return a && !strcmp(a,b);}
static int open_file(sqlite3_vfs *v,const char *name,sqlite3_file *file,int flags,int *out) {
    Wrapper *w=owner(v);
    file->pMethods=NULL;
    if(!owning || !name || !(flags & (SQLITE_OPEN_MAIN_DB | SQLITE_OPEN_MAIN_JOURNAL)) ||
       (flags & (SQLITE_OPEN_DELETEONCLOSE | SQLITE_OPEN_TEMP_DB | SQLITE_OPEN_TEMP_JOURNAL |
                 SQLITE_OPEN_TRANSIENT_DB | SQLITE_OPEN_SUBJOURNAL | SQLITE_OPEN_SUPER_JOURNAL)))
        return SQLITE_CANTOPEN;
    if(flags & SQLITE_OPEN_MAIN_DB) {
        if(opening != expect_main) return SQLITE_CANTOPEN;
        opening = idle;
    }
    int present=observed(w,L_CHECK);
    if(present<0) return SQLITE_IOERR;
    int journal=exact(name,w->journal);
    int main=exact(name,w->main);
    int extras=flags & ~(SQLITE_OPEN_READWRITE|SQLITE_OPEN_READONLY|SQLITE_OPEN_MAIN_DB|
                         SQLITE_OPEN_MAIN_JOURNAL|SQLITE_OPEN_NOFOLLOW|SQLITE_OPEN_CREATE|SQLITE_OPEN_EXCLUSIVE);
    if(journal && extras==SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION) extras=0;
    if(extras || !(main || journal) || !(flags & (SQLITE_OPEN_READWRITE|SQLITE_OPEN_READONLY))) return failed(w);
    if(main && (!(flags & SQLITE_OPEN_MAIN_DB) || flags & (SQLITE_OPEN_MAIN_JOURNAL|SQLITE_OPEN_CREATE|SQLITE_OPEN_EXCLUSIVE)))return failed(w);
    if(journal && (!(flags & SQLITE_OPEN_MAIN_JOURNAL) || flags & SQLITE_OPEN_MAIN_DB))return failed(w);
    if(!(flags&SQLITE_OPEN_READONLY) || flags&(SQLITE_OPEN_CREATE|SQLITE_OPEN_READWRITE|SQLITE_OPEN_EXCLUSIVE) ||
       (journal && !present))return SQLITE_READONLY;
    sqlite3_file *native=bounded_native_storage(file);
    native->pMethods=NULL;
    int rc=w->base->xOpen(w->base,name,native,flags|SQLITE_OPEN_NOFOLLOW,out);
    if(rc!=SQLITE_OK) {
        if(native->pMethods) native->pMethods->xClose(native);
        w->poisoned=1; return rc;
    }
    if((out && ((*out & SQLITE_OPEN_READONLY)==0 || (*out & SQLITE_OPEN_READWRITE)!=0)) || observed(w,L_CHECK)<0) {
        native->pMethods->xClose(native); return SQLITE_IOERR;
    }
    rc=bounded_install(file,journal?w->journalLimit:w->mainLimit);
    if(rc!=SQLITE_OK) { native->pMethods->xClose(native); w->poisoned=1; return rc; }
    w->opens++;
    return SQLITE_OK;
}
static int remove_file(sqlite3_vfs *v,const char *name,int syncDir){
    (void)v;(void)name;(void)syncDir;return SQLITE_READONLY;
}
static int access_file(sqlite3_vfs *v,const char *name,int mode,int *out){
    Wrapper *w=owner(v);*out=0;
    if(observed(w,L_CHECK)<0)return SQLITE_IOERR;
    if(exact(name,w->wal))return mode==SQLITE_ACCESS_EXISTS ? SQLITE_OK : SQLITE_IOERR; /* lease inventory already proved absent */
    if(!exact(name,w->main)&&!exact(name,w->journal))return failed(w);
    return w->base->xAccess(w->base,name,mode,out);
}
static int full_name(sqlite3_vfs *v,const char *name,int n,char *out){
    Wrapper *w=owner(v);
    if(opening != expect_path) return SQLITE_CANTOPEN;
    opening = idle;
    if(!exact(name,w->main)||observed(w,L_CHECK)<0)return failed(w);
    int rc=w->base->xFullPathname(w->base,name,n,out);
    if(rc==SQLITE_OK&&!exact(out,w->main))return failed(w);
    if(rc==SQLITE_OK) opening = expect_main;
    return rc;
}
static int random_bytes(sqlite3_vfs *v,int n,char *out){Wrapper *w=owner(v);return w->base->xRandomness(w->base,n,out);}
static int sleep_us(sqlite3_vfs *v,int us){Wrapper *w=owner(v);return w->base->xSleep(w->base,us);}
static int now(sqlite3_vfs *v,double *out){Wrapper *w=owner(v);return w->base->xCurrentTime(w->base,out);}
static int last_error(sqlite3_vfs *v,int n,char *out){Wrapper *w=owner(v);return w->base->xGetLastError?w->base->xGetLastError(w->base,n,out):0;}
int leased_open_limits(const char *path,sqlite3 **db,void *ctx,LeaseCheck check,sqlite3_int64 mainLimit,sqlite3_int64 journalLimit){
    if(!db || !check) return SQLITE_MISUSE;
    *db=NULL;
    if(mainLimit<1 || mainLimit>MAIN_FILE_LIMIT || journalLimit<1 || journalLimit>JOURNAL_FILE_LIMIT) return SQLITE_MISUSE;
    Wrapper *w=&state;
    if(w->check || !path || strlen(path)>sizeof(w->main)-9)return SQLITE_MISUSE;
    if(!w->base) {
        sqlite3_vfs *base=sqlite3_vfs_find(NULL);
        if(!base || sqlite3_vfs_find("apple-cli-event-inspection"))return SQLITE_MISUSE;
        int storage=bounded_storage_size(base->szOsFile); if(!storage)return SQLITE_MISUSE;
        w->base=base;
    w->api=(sqlite3_vfs){.iVersion=1,.szOsFile=storage,.mxPathname=base->mxPathname,.zName="apple-cli-event-inspection",.pAppData=w,
        .xOpen=open_file,.xDelete=remove_file,.xAccess=access_file,.xFullPathname=full_name,.xRandomness=random_bytes,.xSleep=sleep_us,.xCurrentTime=now,.xGetLastError=last_error};
        int registered=sqlite3_vfs_register(&w->api,0);
        if(registered!=SQLITE_OK){w->base=NULL;return registered;}
    } else if(sqlite3_vfs_find("apple-cli-event-inspection")!=&w->api) { return SQLITE_MISUSE; }
    w->mainLimit=mainLimit;w->journalLimit=journalLimit;w->ctx=ctx;w->check=check;
    w->poisoned=w->opens=w->creates=w->deletes=0;
    snprintf(w->main,sizeof(w->main),"%s",path);
    snprintf(w->journal,sizeof(w->journal),"%s-journal",path);
    snprintf(w->wal,sizeof(w->wal),"%s-wal",path);
    owning=1;opening=expect_path;
    int rc=sqlite3_open_v2(path,db,SQLITE_OPEN_READONLY|SQLITE_OPEN_NOFOLLOW,w->api.zName);
    opening=idle;
    if(rc==SQLITE_OK) rc=policy_install(*db);
    if(rc!=SQLITE_OK){if(sqlite3_close(*db)!=SQLITE_OK) return SQLITE_INTERNAL;
        *db=NULL;clear_owner(w);}
    return rc;
}
int leased_open(const char *path,sqlite3 **db,void *ctx,LeaseCheck check){
    return leased_open_limits(path,db,ctx,check,MAIN_FILE_LIMIT,JOURNAL_FILE_LIMIT);
}
int leased_close(sqlite3 *db){
    Wrapper *w=&state;
    int rc=sqlite3_close(db);
    if(rc==SQLITE_OK) policy_closed();
    if(rc!=SQLITE_OK)return rc;
    clear_owner(w);
    return SQLITE_OK;
}
