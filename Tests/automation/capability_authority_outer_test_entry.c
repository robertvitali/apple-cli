/* Outer test-only leaf declarations precede the unchanged retained handoff
   effect wrappers. No real clock/dispatch/diagnostic leaf is selected. */
#include <time.h>
#include <sys/types.h>
#define CA_AUTHORITY_OUTER_TEST 1
#define CA_OUTER_CLOCK_GETTIME ca_test_outer_clock
#define CA_OUTER_DISPATCH ca_test_outer_dispatch
#define CA_OUTER_DIAGNOSTIC_WRITE ca_test_outer_write
/* PRIVATE TEST BUILD ONLY. Include exactly the production translation unit below
   after defining narrowly scoped syscall substitutions. These wrappers cannot be
   selected by an ordinary production caller. No subprocess or native clock. */
#include "capability_authority_handoff_test_hooks.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>


/* All pipe descriptors are virtual. These functions never call pipe/fcntl/write
   or exec on the host. Real filesystem descriptions retain the older ledger. */
CAHandoffTestState ca_handoff_test;
typedef struct { int active, fd, access, status, descriptor; } VirtualFD;
static VirtualFD virtual_fds[3];
static int next_virtual;
static VirtualFD *virtual_lookup(int fd) {
    for(size_t i=0;i<3;i++) if(virtual_fds[i].active && virtual_fds[i].fd==fd) return &virtual_fds[i];
    return NULL;
}
static int virtual_add(int fd,int access,int status,int descriptor) {
    for(size_t i=0;i<3;i++) if(!virtual_fds[i].active) {
        virtual_fds[i]=(VirtualFD){1,fd,access,status,descriptor};
        ca_handoff_test.live++;
        if(ca_handoff_test.live>ca_handoff_test.peak_live) ca_handoff_test.peak_live=ca_handoff_test.live;
        return fd;
    }
    ca_handoff_test.invalid++; errno=EMFILE; return -1;
}
static int inject(int fault) {
    if(ca_handoff_test.fault!=fault) return 0;
    ca_handoff_test.fired++; errno=EIO; return 1;
}
static void expire(void) { if(ca_handoff_test.clock_value) *ca_handoff_test.clock_value=158; }
void ca_handoff_test_reset(void) {
    memset(&ca_handoff_test,0,sizeof(ca_handoff_test));
    for(size_t i=0;i<3;i++) if(virtual_fds[i].active) ca_handoff_test.invalid++;
    next_virtual=1000003;
}
int ca_handoff_test_finish(void) {
    int okay=ca_handoff_test.live==0 && ca_handoff_test.invalid==0;
    /* Virtual leak recovery touches no host FD. A leak still fails the case. */
    memset(virtual_fds,0,sizeof(virtual_fds)); ca_handoff_test.live=0;
    ca_handoff_test.active=0; return okay;
}
static int handoff_pipe(int output[2]) {
    ca_handoff_test.pipe_calls++;
    if(inject(HT_PIPE_ERROR)) return -1;
    if(ca_handoff_test.pipe_calls!=1) { ca_handoff_test.invalid++; errno=EMFILE; return -1; }
    int reader=ca_handoff_test.stdio_pipe ? 0 : 1000001;
    int writer=ca_handoff_test.stdio_pipe ? 1 : 1000002;
    output[0]=virtual_add(reader,O_RDONLY,0,0);
    output[1]=virtual_add(writer,O_WRONLY,0,0);
    if(output[0]<0 || output[1]<0) return -1;
    if(ca_handoff_test.at_pipe) ca_handoff_test.at_pipe(ca_handoff_test.at_pipe_context);
    if(inject(HT_PIPE_LATE)) expire();
    return 0;
}
static int handoff_fcntl(int fd,int command,...) {
    ca_handoff_test.fcntl_calls++;
    VirtualFD *v=virtual_lookup(fd);
    if(!v) { ca_handoff_test.invalid++; errno=EBADF; return -1; }
    if(command==F_GETFL) { if(inject(HT_GETFL_ERROR)) return -1; return v->access|v->status; }
    if(command==F_GETFD) { if(inject(HT_GETFD_ERROR)) return -1; return v->descriptor; }
    va_list args; va_start(args,command); int value=va_arg(args,int); va_end(args);
    if(command==F_SETFL) {
        if(inject(HT_SETFL_ERROR)) return -1;
        if(value & ~(O_NONBLOCK|O_ACCMODE)) { ca_handoff_test.invalid++; errno=EINVAL; return -1; }
        v->status=value&O_NONBLOCK; return 0;
    }
    if(command==F_SETFD) {
        if(value & ~FD_CLOEXEC) { ca_handoff_test.invalid++; errno=EINVAL; return -1; }
        if(value==0) {
            if(v->access!=O_RDONLY || !ca_handoff_test.writer_closed) ca_handoff_test.invalid++;
            if(inject(HT_CLEAR_ERROR)) return -1;
            if(inject(HT_CLEAR_LATE)) expire();
        } else if(inject(HT_SETFD_ERROR)) return -1;
        v->descriptor=value; return 0;
    }
    if(command==F_DUPFD_CLOEXEC) {
        ca_handoff_test.dup_calls++;
        if(value!=3) { ca_handoff_test.invalid++; errno=EINVAL; return -1; }
        if(inject(HT_DUP_ERROR)) return -1;
        int result=virtual_add(next_virtual++,v->access,v->status,FD_CLOEXEC);
        if(inject(HT_DUP_LATE)) expire();
        return result;
    }
    ca_handoff_test.invalid++; errno=EINVAL; return -1;
}
static ssize_t handoff_write(int fd,const void *bytes,size_t count) {
    ca_handoff_test.write_calls++;
    VirtualFD *v=virtual_lookup(fd); int reader=0;
    for(size_t i=0;i<3;i++) if(virtual_fds[i].active && virtual_fds[i].access==O_RDONLY) {
        reader=1;
        if(!(virtual_fds[i].status&O_NONBLOCK) || !(virtual_fds[i].descriptor&FD_CLOEXEC)) ca_handoff_test.invalid++;
    }
    if(!v || v->access!=O_WRONLY || !(v->status&O_NONBLOCK) || !(v->descriptor&FD_CLOEXEC)
        || !reader || count!=64 || ca_handoff_test.write_calls!=1) {
        ca_handoff_test.invalid++; errno=EINVAL; return -1;
    }
    if(inject(HT_WRITE_SHORT)) return 63;
    if(inject(HT_WRITE_ZERO)) return 0;
    if(inject(HT_WRITE_EINTR)) { errno=EINTR; return -1; }
    if(inject(HT_WRITE_EAGAIN)) { errno=EAGAIN; return -1; }
    if(inject(HT_WRITE_EPIPE)) { errno=EPIPE; return -1; }
    if(inject(HT_WRITE_ERROR)) return -1;
    memcpy(ca_handoff_test.record,bytes,64); ca_handoff_test.record_size=64;
    if(inject(HT_WRITE_LATE)) expire();
    return 64;
}
static int virtual_close(int fd) {
    VirtualFD *v=virtual_lookup(fd);
    if(!v) { ca_handoff_test.invalid++; errno=EBADF; return -1; }
    ca_handoff_test.close_calls++; int writer=v->access==O_WRONLY;
    int original=fd<=2; v->active=0; ca_handoff_test.live--;
    if(writer) {
        int other_writer=0;
        for(size_t i=0;i<3;i++) if(virtual_fds[i].active && virtual_fds[i].access==O_WRONLY) other_writer=1;
        if(!other_writer) ca_handoff_test.writer_closed++;
    }
    if(original && inject(HT_OLD_CLOSE_ERROR)) return -1;
    if(writer && !original && inject(HT_WRITER_CLOSE_ERROR)) return -1;
    if(writer && !original && inject(HT_WRITER_CLOSE_LATE)) expire();
    return 0;
}
static int handoff_execve(const char *path,char *const argv[],char *const env[]) {
    ca_handoff_test.exec_calls++;
    if(!path || strcmp(path,ca_handoff_test.expected_interpreter)!=0) ca_handoff_test.invalid++;
    size_t count=0;
    while(count<17 && argv[count]) {
        size_t length=strnlen(argv[count],4097);
        if(length>4096) { ca_handoff_test.invalid++; break; }
        memcpy(ca_handoff_test.arguments[count],argv[count],length+1); count++;
    }
    ca_handoff_test.argument_count=count;
    if(count!=7+ca_handoff_test.expected_count || count>=17 || argv[count]) ca_handoff_test.invalid++;
    if(count>=7) {
        const char *const fixed[]={ca_handoff_test.expected_interpreter,"-I","-S","-B",ca_handoff_test.expected_shim,"--capability-bootstrap-fd"};
        for(size_t i=0;i<6;i++) if(strcmp(argv[i],fixed[i])!=0) ca_handoff_test.invalid++;
        size_t length=strnlen(argv[6],11); uint64_t number=0;
        if(!length || length>10 || argv[6][0]=='0') ca_handoff_test.invalid++;
        else for(size_t i=0;i<length;i++) {
            if(argv[6][i]<'0' || argv[6][i]>'9') { ca_handoff_test.invalid++; break; }
            number=number*10+(unsigned)(argv[6][i]-'0');
        }
        VirtualFD *reader=number<=INT32_MAX ? virtual_lookup((int)number) : NULL;
        if(number<=2 || !reader || reader->access!=O_RDONLY || !(reader->status&O_NONBLOCK)
            || reader->descriptor!=0 || ca_handoff_test.live!=1) ca_handoff_test.invalid++;
        for(size_t i=0;i<ca_handoff_test.expected_count && i+7<count;i++)
            if(strcmp(argv[i+7],ca_handoff_test.expected_operands[i])!=0) ca_handoff_test.invalid++;
    }
    if(!env || !env[0] || !env[1] || env[2]
        || !((strcmp(env[0],"PATH=/usr/bin:/bin:/usr/sbin:/sbin")==0 && strcmp(env[1],"LC_ALL=C")==0)
        || (strcmp(env[1],"PATH=/usr/bin:/bin:/usr/sbin:/sbin")==0 && strcmp(env[0],"LC_ALL=C")==0))) ca_handoff_test.invalid++;
    if(!ca_handoff_test.writer_closed || ca_handoff_test.final_shim_reads==0
        || ca_handoff_test.final_package_scans==0 || ca_handoff_test.last_observation!=2) ca_handoff_test.invalid++;
    if(inject(HT_EXEC_LATE)) expire();
    (void)inject(HT_EXEC_ERROR); errno=ENOEXEC; return -1;
}

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
    if(ca_handoff_test.active && ca_handoff_test.writer_closed) ca_handoff_test.writer_closed_at_final++;
    if(ca_file_test.final_action) ca_file_test.final_action(ca_file_test.action_context);
}
static int checked_handoff_execve(const char *path,char *const argv[],char *const env[]) {
    for(size_t i=0;i<64;i++) if(tracked[i].active) ca_handoff_test.invalid++;
    return handoff_execve(path,argv,env);
}
static int test_open(const char *path,int flags,...) {
    ca_file_test.open_attempts++;
    if(flags&O_CREAT) { ca_file_test.invalid_close++; errno=EPERM; return -1; }
    (void)path; (void)retain; errno=EACCES; return -1; /* Outer controls never open host files. */
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
    (void)parent; (void)path; (void)flags; errno=EACCES; return -1;
}
static int test_fstat(int fd,struct stat *info) {
    if(virtual_lookup(fd)) { memset(info,0,sizeof(*info)); info->st_mode=S_IFIFO|0600; return 0; }
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
    struct stat observed;
    if(ca_handoff_test.active && fstat(fd,&observed)==0
        && (uint64_t)observed.st_dev==ca_handoff_test.shim_device
        && (uint64_t)observed.st_ino==ca_handoff_test.shim_inode) {
        ca_handoff_test.shim_reads++;
        if(ca_handoff_test.writer_closed) { ca_handoff_test.final_shim_reads++; ca_handoff_test.last_observation=1; }
    }
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
    if(virtual_lookup(fd)) return virtual_close(fd);
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
    if(!entry && errno==0 && ca_handoff_test.active && ca_handoff_test.writer_closed) {
        struct stat observed;
        if(fstat(dirfd(stream),&observed)==0
            && (uint64_t)observed.st_dev==ca_handoff_test.package_device
            && (uint64_t)observed.st_ino==ca_handoff_test.package_inode) {
            ca_handoff_test.final_package_scans++; ca_handoff_test.last_observation=2;
        }
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
static void handoff_leaf_references(void) __attribute__((unused));
static void handoff_leaf_references(void) {
    (void)handoff_pipe; (void)handoff_fcntl; (void)handoff_write; (void)checked_handoff_execve;
}
#define pipe handoff_pipe
#define fcntl handoff_fcntl
#define write handoff_write
#define execve checked_handoff_execve
#define popen(...) CA_FORBIDDEN_PROCESS_CALL()
#pragma GCC poison fork vfork posix_spawn posix_spawnp system execl execv execvp execle execlp kill killpg signal sigaction sigprocmask pthread_sigmask pipe2 dup dup2
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
/* The API includes CABudget: load it after the same read substitution that
   covers the included implementation, exactly as the retained wrapper does.
   System time/types headers were already loaded before syscall macros. */
#include "capability_authority_outer_test_api.h"
#pragma GCC poison clock_gettime gettimeofday mach_absolute_time
#include "capability_authority_entry.c"
