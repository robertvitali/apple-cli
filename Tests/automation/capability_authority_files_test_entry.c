/* PRIVATE TEST BUILD ONLY. Include exactly the production translation unit below
   after defining narrowly scoped syscall substitutions. These wrappers cannot be
   selected by an ordinary production caller. No subprocess or native clock. */
#include "capability_authority_files_test_hooks.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

CAFileTestState ca_file_test;
typedef struct { int active, fd; DIR *stream; } TrackedFD;
static TrackedFD tracked[64];
static TrackedFD *lookup(int fd) {
    for(size_t i=0;i<64;i++) if(tracked[i].active && tracked[i].fd==fd) return &tracked[i];
    return NULL;
}
static int matched(int fd) {
    struct stat info;
    return fstat(fd,&info)==0 && (uint64_t)info.st_dev==ca_file_test.device
        && (uint64_t)info.st_ino==ca_file_test.inode;
}
static int runtime_stat(const struct stat *info) {
    for(size_t i=0;i<ca_file_test.runtime_count && i<8;i++)
        if((uint64_t)info->st_dev==ca_file_test.runtime_devices[i]
            && (uint64_t)info->st_ino==ca_file_test.runtime_inodes[i]) return 1;
    return 0;
}
static void observe_runtime(int fd) {
    struct stat info;
    if(fstat(fd,&info)==0 && runtime_stat(&info)) ca_file_test.runtime_observations++;
}
static int retain(int fd) {
    if(fd<0) return fd;
    for(size_t i=0;i<64;i++) if(!tracked[i].active) {
        tracked[i]=(TrackedFD){1,fd,NULL};
        observe_runtime(fd);
        return fd;
    }
    (void)close(fd); ca_file_test.invalid_close++; errno=EMFILE; return -1;
}
void ca_files_test_reset(void) {
    memset(&ca_file_test,0,sizeof(ca_file_test));
    for(size_t i=0;i<64;i++) if(tracked[i].active) ca_file_test.invalid_close++;
}
int ca_files_test_finish(void) {
    unsigned leaked=0;
    for(size_t i=0;i<64;i++) if(tracked[i].active) {
        leaked++; tracked[i].active=0;
        int result=tracked[i].stream ? closedir(tracked[i].stream) : close(tracked[i].fd);
        if(result!=0) ca_file_test.invalid_close++;
    }
    ca_file_test.leaked=leaked;
    return leaked==0 && ca_file_test.invalid_close==0;
}
void ca_files_test_before_final(void) {
    ca_file_test.before_final++;
    if(ca_file_test.final_action) ca_file_test.final_action(ca_file_test.action_context);
}
static int test_open(const char *path,int flags,...) {
    ca_file_test.open_attempts++;
    if(flags&O_CREAT) { ca_file_test.invalid_close++; errno=EPERM; return -1; }
    return retain(open(path,flags));
}
static int denied(int parent,const char *path) {
    if(ca_file_test.fault==FT_ACCESS_ERROR && ca_file_test.denied_component
        && strcmp(path,ca_file_test.denied_component)==0 && matched(parent)) {
        ca_file_test.fired++; errno=EACCES; return 1;
    }
    return 0;
}
static int test_openat(int parent,const char *path,int flags,...) {
    ca_file_test.open_attempts++; observe_runtime(parent);
    if(denied(parent,path)) return -1;
    if(flags&O_CREAT) { ca_file_test.invalid_close++; errno=EPERM; return -1; }
    return retain(openat(parent,path,flags));
}
static int test_fstat(int fd,struct stat *info) {
    int result=fstat(fd,info);
    if(result==0 && runtime_stat(info)) ca_file_test.runtime_observations++;
    if(result==0 && ca_file_test.fault==FT_WRONG_UID
        && (uint64_t)info->st_dev==ca_file_test.device && (uint64_t)info->st_ino==ca_file_test.inode) {
        info->st_uid=(uid_t)(getuid()==0 ? 1 : 0); ca_file_test.fired++;
    }
    return result;
}
static int test_fstatat(int fd,const char *path,struct stat *info,int flags) {
    observe_runtime(fd);
    if(denied(fd,path)) return -1;
    int result=fstatat(fd,path,info,flags);
    if(result==0 && runtime_stat(info)) ca_file_test.runtime_observations++;
    if(result==0 && ca_file_test.fault==FT_WRONG_UID
        && (uint64_t)info->st_dev==ca_file_test.device && (uint64_t)info->st_ino==ca_file_test.inode) {
        info->st_uid=(uid_t)(getuid()==0 ? 1 : 0); ca_file_test.fired++;
    }
    return result;
}
static ssize_t test_read(int fd,void *buffer,size_t size) {
    if(matched(fd) && ca_file_test.fault==FT_READ_ERROR) {
        ca_file_test.fired++; errno=EIO; return -1;
    }
    ssize_t result=read(fd,buffer,size);
    if(matched(fd) && ca_file_test.fault==FT_READ_LATE && ca_file_test.clock_value) {
        ca_file_test.fired++; *ca_file_test.clock_value=158;
    }
    return result;
}
static int test_close(int fd) {
    TrackedFD *entry=lookup(fd);
    if(!entry || entry->stream) { ca_file_test.invalid_close++; errno=EBADF; return -1; }
    int target=matched(fd); entry->active=0;
    int result=close(fd);
    if(target && ca_file_test.fault==FT_CLOSE_LATE && ca_file_test.clock_value) {
        ca_file_test.fired++; *ca_file_test.clock_value=158;
    }
    if(target && ca_file_test.fault==FT_CLOSE_UNCERTAIN) {
        ca_file_test.fired++; errno=EIO; return -1;
    }
    return result;
}
static DIR *test_fdopendir(int fd) {
    TrackedFD *entry=lookup(fd);
    if(!entry || entry->stream) { ca_file_test.invalid_close++; errno=EBADF; return NULL; }
    if(ca_file_test.fault==FT_FDOPENDIR_ERROR) {
        ca_file_test.fired++; errno=EMFILE; return NULL;
    }
    DIR *stream=fdopendir(fd);
    if(stream) entry->stream=stream;
    return stream;
}
static struct dirent *test_readdir(DIR *stream) {
    struct dirent *entry=readdir(stream);
    if(!entry && ca_file_test.fault==FT_READDIR_ERROR) {
        ca_file_test.fired++; errno=EIO;
    }
    return entry;
}
static int test_closedir(DIR *stream) {
    TrackedFD *entry=NULL;
    for(size_t i=0;i<64;i++) if(tracked[i].active && tracked[i].stream==stream) entry=&tracked[i];
    if(!entry) { ca_file_test.invalid_close++; errno=EBADF; return -1; }
    entry->active=0; int result=closedir(stream);
    if(ca_file_test.fault==FT_CLOSEDIR_UNCERTAIN) { ca_file_test.fired++; errno=EIO; return -1; }
    return result;
}
/* Referencing future-directory wrappers avoids unused-function diagnostics in
   the current baseline, whose production source has no directory enumeration. */
static void directory_wrapper_references(void) __attribute__((unused));
static void directory_wrapper_references(void) {
    (void)test_fdopendir; (void)test_readdir; (void)test_closedir;
}
#define open test_open
#define openat test_openat
#define fstat test_fstat
#define fstatat test_fstatat
#define read test_read
#define close test_close
#define fdopendir test_fdopendir
#define readdir test_readdir
#define closedir test_closedir
#define CA_TEST_BEFORE_FINAL() ca_files_test_before_final()
#include "capability_authority_entry.c"
